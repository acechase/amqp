require 'amqp/frame'

module AMQP
  class Error < StandardError; end

  module BasicClient
    def process_frame frame
      if mq = channels[frame.channel]
        mq.process_frame(frame)
        return
      end

      case frame
      when Frame::Method
        case method = frame.payload
        when Protocol::Connection::Start
          send Protocol::Connection::StartOk.new({:platform => 'Ruby/EventMachine',
                                                  :product => 'AMQP',
                                                  :information => 'http://github.com/tmm1/amqp',
                                                  :version => VERSION},
                                                 'AMQPLAIN',
                                                 {:LOGIN => @settings[:user],
                                                  :PASSWORD => @settings[:pass]},
                                                 'en_US')

        when Protocol::Connection::Tune
          send Protocol::Connection::TuneOk.new(:channel_max => 0,
                                                :frame_max => 131072,
                                                :heartbeat => 0)

          send Protocol::Connection::Open.new(:virtual_host => @settings[:vhost],
                                              :capabilities => '',
                                              :insist => @settings[:insist])

        when Protocol::Connection::OpenOk
          succeed(self)

        when Protocol::Connection::Redirect
          (redir_host, redir_port) = method.host.split(":")
          redir_port = redir_port.to_i #important!
          STDERR.puts "Redirecting to #{redir_host}:#{redir_port}"
          old_on_disconnect = @on_disconnect
          @on_disconnect = Proc.new do
            @on_disconnect = old_on_disconnect
            reconnect true, redir_host, redir_port
          end
          
        when Protocol::Connection::Close
          # raise Error, "#{method.reply_text} in #{Protocol.classes[method.class_id].methods[method.method_id]}"
          STDERR.puts "#{method.reply_text} in #{Protocol.classes[method.class_id].methods[method.method_id]}"

        when Protocol::Connection::CloseOk
          @on_disconnect.call if @on_disconnect
        end
      end
    end
  end

  def self.client
    @client ||= BasicClient
  end

  def self.client= mod
    mod.__send__ :include, AMQP
    @client = mod
  end

  module Client
    include EM::Deferrable

    def initialize opts = {}
      @settings = opts
      extend AMQP.client

      @on_disconnect ||= method(:disconnected)

      timeout @settings[:timeout] if @settings[:timeout]
      errback{ @on_disconnect.call } unless @reconnecting

      @connected = false
    end

    def connection_completed
      start_tls if @settings[:ssl]
      log 'connected'
      # @on_disconnect = proc{ raise Error, 'Disconnected from server' }
      unless @closing
        Client.connection_succeeded!
        @on_disconnect = method(:disconnected)
      end

      @connected = true
      @connection_status.call(:connected) if @connection_status

      @buf = Buffer.new
      send_data HEADER
      send_data [1, 1, VERSION_MAJOR, VERSION_MINOR].pack('C4')
      
      if @settings[:keepalive]
        EM.add_periodic_timer(@settings[:keepalive]) do
          send Frame::Heartbeat.new
        end
      end
    end

    def connected?
      @connected
    end

    def unbind
      log 'disconnected'
      @connected = false
      EM.next_tick{ @on_disconnect.call }
    end

    def add_channel mq
      (@_channel_mutex ||= Mutex.new).synchronize do
        channels[ key = (channels.keys.max || 0) + 1 ] = mq
        key
      end
    end

    def channels
      @channels ||= {}
    end

    def receive_data data
      # log 'receive_data', data
      @buf << data

      while frame = Frame.parse(@buf)
        log 'receive', frame
        process_frame frame
      end
    end

    def process_frame frame
      # this is a stub meant to be
      # replaced by the module passed into initialize
    end

    def send data, opts = {}
      channel = opts[:channel] ||= 0
      data = data.to_frame(channel) unless data.is_a? Frame
      data.channel = channel

      log 'send', data
      send_data data.to_s
    end

    #:stopdoc:
    # def send_data data
    #   log 'send_data', data
    #   super
    # end
    #:startdoc:

    def close &on_disconnect
      if on_disconnect
        @closing = true
        @on_disconnect = proc{
          on_disconnect.call
          @closing = false
        }
      end

      callback{ |c|
        if c.channels.any?
          c.channels.each do |ch, mq|
            mq.close
          end
        else
          send Protocol::Connection::Close.new(:reply_code => 200,
                                               :reply_text => 'Goodbye',
                                               :class_id => 0,
                                               :method_id => 0)
        end
      }
    end

    def reconnect force = false, use_host = nil, use_port = nil
      if @reconnecting and not force
        # wait 1 second after first reconnect attempt, in between each subsequent attempt
        EM.add_timer(@settings[:reconnect_timer] || 1){ reconnect(true) }
        return
      end

      unless @reconnecting
        @reconnecting = true

        @deferred_status = nil
        initialize(@settings)

        mqs = @channels
        @channels = {}
        mqs.each{ |_,mq| mq.reset } if mqs
      end

      log 'reconnecting'
      begin
        if use_host && use_port
          (try_host, try_port) = [use_host, use_port]
        else
          (try_host, try_port) = Client.determine_reconnect_server(@settings)
          STDERR.puts "Reconnecting to #{try_host}:#{try_port}"          
        end
        EM.reconnect try_host, try_port, self
      rescue RuntimeError => e
        STDERR.puts "'#{e.message}' on reconnect to #{try_host}:#{try_port}"
        return reconnect if e.message == "no connection"
        raise e
      end
    end
    
    def self.determine_reconnect_server(opts)
      try_host = opts[:host]
      try_port = opts[:port]
      @retry_count ||= 0
      if opts[:max_retry] && @retry_count >= opts[:max_retry]
        raise "max_retry (#{@retry_count}) reached, disconnecting"
      end
      if srv_list = opts[:fallback_servers]
        @server_to_select ||= 0
        idex = @server_to_select % (srv_list.size + 1)
        if idex != 0
          try = srv_list[idex - 1]
          try_host = try[:host] || AMQP.settings[:host]
          try_port = try[:port] || AMQP.settings[:port]
        end
        @server_to_select += 1
      end      
      @retry_count += 1
      [try_host, try_port]
    end
    
    def self.connection_succeeded!
      @retry_count = 0
    end

    def self.connect opts = {}
      opts = AMQP.settings.merge(opts)
      max_retry = ((opts[:fallback_servers] || []).size + 1) * 3
      begin
        (try_host, try_port) = determine_reconnect_server(opts)
        result = EM.connect try_host, try_port, self, opts
        connection_succeeded!
        return result
      rescue RuntimeError => e
        STDERR.puts "'#{e.message}' on connect to #{try_host}:#{try_port}"
        retry if e.message == "no connection" && @retry_count < max_retry
        raise e
      end
    end

    def connection_status &blk
      @connection_status = blk
    end

    private

    def disconnected
      @connection_status.call(:disconnected) if @connection_status
      reconnect
    end

    def log *args
      return unless @settings[:logging] or AMQP.logging
      require 'pp'
      pp args
      puts
    end
  end
end
