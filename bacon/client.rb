# this is the bacon spec for AMQP client
# you can find other specs inline in frame.rb, buffer.rb and protocol.rb
# this one couldn't be written in line because:
# due to the load order 'AMQP' isn't completely defined yet when Client is loaded
require 'mocha'

describe Client do
  after do
    Mocha::Mockery.instance.teardown
    Mocha::Mockery.reset_instance
    #TODO: these clean ups here should not be necessary!
    Thread.current[:mq] = nil
    AMQP.instance_eval{ @conn = nil }
    AMQP.instance_eval{ @closing = false }
    Client.class_eval{ @retry_count = 0 }
    Client.class_eval{ @server_to_select = 0 }
  end
  
  should 'reconnect on disconnect after connection_completed (use reconnect_timer)' do
    @times_connected = 0
    @connect_args = []
      
    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @connect_args << [arg1, arg2]
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        @client.connection_completed
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }
  
    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1)
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 5
    @connect_args.each do |(arg1, arg2)|
      arg1.should == "nonexistanthost"
      arg2.should == 5672
    end
  end
  
  should 'reconnect on disconnect before connection_completed (use reconnect_timer)' do
    @times_connected = 0
    @connect_args = []

    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @connect_args << [arg1, arg2]
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }

    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1)
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 5
    @connect_args.each do |(arg1, arg2)|
      arg1.should == "nonexistanthost"
      arg2.should == 5672
    end
  end
  
  should "use fallback servers on reconnect" do
    @times_connected = 0
    @connect_args = []

    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @connect_args << [arg1, arg2]
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }

    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1,
      :fallback_servers => [
        {:host => 'alsononexistant'},
        {:host => 'alsoalsononexistant', :port => 1234},
      ])
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 5
    # puts "@connect_args: " + @connect_args.inspect
    @connect_args.should == [
      ["nonexistanthost", 5672], ["alsononexistant", 5672], ["alsoalsononexistant", 1234], 
      ["nonexistanthost", 5672], ["alsononexistant", 5672]]
  end

  should "use fallback servers on reconnect when connection_completed" do
    @times_connected = 0
    @connect_args = []

    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @connect_args << [arg1, arg2]
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        @client.connection_completed
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }

    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1,
      :fallback_servers => [
        {:host => 'alsononexistant'},
        {:host => 'alsoalsononexistant', :port => 1234},
      ])
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 5
    # puts "@connect_args: " + @connect_args.inspect
    @connect_args.should == [
      ["nonexistanthost", 5672], ["alsononexistant", 5672], ["alsoalsononexistant", 1234], 
      ["nonexistanthost", 5672], ["alsononexistant", 5672]]
  end
  
  should "retry when 'no connection' runtime error on initial connect up to 3 times per server" do
    @times_connected = 0
    @connect_args = []

    EventMachine.stubs(:connect).raises(RuntimeError, "no connection").with do |arg1, arg2| 
      @connect_args << [arg1, arg2]
      @times_connected += 1    
    end
    
    EM.next_tick{ EM.stop_event_loop }

    #connect
    lambda{
      AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1,
        :fallback_servers => [
          {:host => 'alsononexistant'},
          {:host => 'alsoalsononexistant', :port => 1234},
        ])
    }.should.raise(RuntimeError)
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 9
    # puts "@connect_args: " + @connect_args.inspect
    @connect_args.should == [
      ["nonexistanthost", 5672], ["alsononexistant", 5672], ["alsoalsononexistant", 1234], 
      ["nonexistanthost", 5672], ["alsononexistant", 5672], ["alsoalsononexistant", 1234], 
      ["nonexistanthost", 5672], ["alsononexistant", 5672], ["alsoalsononexistant", 1234]]
  end
  
  should "retry when 'no connection' runtime error on reconnect" do
    @times_re_connected = 0
    @re_connect_args = []

    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        @client.connection_completed
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end

    EventMachine.stubs(:reconnect).raises(RuntimeError, "no connection").with do |arg1, arg2| 
      @re_connect_args << [arg1, arg2]
      @times_re_connected += 1    
    end

    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }

    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1,
      :fallback_servers => [
        {:host => 'alsononexistant'},
        {:host => 'alsoalsononexistant', :port => 1234},
      ])
    # puts "\nreconnected #{@times_connected} times"
    @times_re_connected.should == 4
    # puts "@connect_args: " + @connect_args.inspect
    @re_connect_args.should == [
      ["alsononexistant", 5672], ["alsoalsononexistant", 1234], 
      ["nonexistanthost", 5672], ["alsononexistant", 5672]]
  end
  
  should "handle redirect requests" do
    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        @client.connection_completed
        payload = AMQP::Protocol::Connection::Redirect.new(
                        :known_hosts => "nonexistanthost:5672,otherhost:5672",
                        :host => 'otherhost:5672')
        meth = AMQP::Frame::Method.new
        meth.payload = payload
        @client.process_frame meth
        EM.next_tick do
          EM.class_eval{ @conns.delete(99) }
          @client.unbind
        end
      end
      true
    end
    
    @re_connect_args = []
    EventMachine.stubs(:reconnect).returns(true).with do |arg1, arg2| 
      @re_connect_args << [arg1, arg2]
    end
    
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }
    
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.1)
    
    @re_connect_args.should == [["otherhost", 5672]]
  end
  
  should "respect max_retry if the disconnect happens before connection completes" do
    @times_connected = 0
  
    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }
    
    #connect
    lambda{
      AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.01, :max_retry => 6)
    }.should.raise(RuntimeError)
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should == 7
  end
  
  should "reset connection count if the disconnect happens after connection completes" do
    @times_connected = 0
  
    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      @times_connected += 1
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @client.stubs(:send_data).returns(true)
        @client.connection_completed
        EM.class_eval{ @conns.delete(99) }
        @client.unbind
      end
      true
    end
    
    EM.next_tick{ EM.add_timer(0.5){ EM.stop_event_loop } }
    
    #connect
    AMQP.start(:host => 'nonexistanthost', :reconnect_timer => 0.01, :max_retry => 6)      
    # puts "\nreconnected #{@times_connected} times"
    @times_connected.should > 7
  end

  should "give EM return value to AMQP reference @conn" do
    EventMachine.stubs(:connect_server).returns(99).with do |arg1, arg2| 
      EM.next_tick do
        @client = EM.class_eval{ @conns }[99]
        @amqp_conn = AMQP.class_eval{ @conn }
        @client.stubs(:send_data).returns(true)
      end
      true
    end    
    EM.next_tick{ EM.add_timer(0.1){ EM.stop_event_loop } }
    AMQP.start(:host => 'nonexistanthost')    
    @amqp_conn.should == @client
  end
  
  
end
