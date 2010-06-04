# Generally this kind of guard is a sign of a bad require, and that is
# arguably true here as well. amqp.gemspec requires this file, but later
# we want people to be able to require 'amqp/version' without getting a warning.
# On the other hand, we aren't in the load path when the gemspec is evaluated,
# so we can't use a relative require there.
unless defined?(::AMQP::VERSION)
  module AMQP
    VERSION = '0.6.7.1'
  end
end
