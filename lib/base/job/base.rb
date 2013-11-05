require_relative "../service_error"
require_relative "./package"
require "eventmachine"
require 'vcap_services_messages/service_message'

module VCAP::Services::Base::AsyncJob
  class BaseJob
    attr_reader :name
    include Resque::Plugins::Status
    include VCAP::Services::Base::Error
    include VCAP::Services::Internal
    extend  JobPatch

    class << self
      def queue_lookup_key
        :node_id
      end

      def select_queue(*args)
        result = nil
        args.each do |arg|
          result = arg[queue_lookup_key] if arg.is_a?(Hash) && arg.has_key?(queue_lookup_key)
        end
        @logger = Config.logger
        @logger.info("Select queue #{result} for job #{self.class} with args:#{args.inspect}") if @logger
        result
      end
    end

    def initialize(*args)
      super(*args)
      parse_config
      init_worker_logger
    end

    def fmt_error(e)
      "#{e}: [#{e.backtrace.join(" | ")}]"
    end

    def init_worker_logger
      @logger = Config.logger
    end

    def required_options(*args)
      missing_opts = args.select{|arg| !options.has_key? arg.to_s}
      raise ArgumentError, "Missing #{missing_opts.join(', ')} in options: #{options.inspect}" unless missing_opts.empty?
    end

    def create_lock
      lock_name = lock_key || "lock:job:#{name}"
      ttl = @config['job_ttl'] || 600
      lock = Lock.new(lock_name, :logger => @logger, :ttl => ttl)
      lock
    end

    def lock_key
      nil
    end

    def parse_config
      @config = Yajl::Parser.parse(ENV['WORKER_CONFIG'])
      raise "Need environment variable: WORKER_CONFIG" unless @config
    end

    def handle_error(e)
      @logger.error("Error in #{self.class} uuid:#{@uuid}: #{fmt_error(e)}")
      err = (e.instance_of?(ServiceError)? e : ServiceError.new(ServiceError::INTERNAL_ERROR)).to_hash
      err_msg = Yajl::Encoder.encode(err["msg"])
      failed(err_msg)
      err_msg
    end

    def success_response(bid, properties)
      response = BackupJobResponse.new
      response.success = true
      response.backup_id = bid
      response.status = "completed"
      response.properties = properties
      response.encode
    end

    def failed_response(bid, error_msg)
      response = BackupJobResponse.new
      response.success = false
      response.backup_id = bid
      response.status = "failed"
      response.encode
    end

    def send_msg(channel, message, &blk)
      if @config["mbus"]
        EM.run do
          subscription = nil
          NATS.on_error { |e| @logger.error("NATS error: #{e}") }
          NATS.connect(:uri => @config["mbus"]) do |worker_nats|
            timer = EM.add_timer(3) do
              worker_nats.unsubscribe(subscription)
              @logger.error("Acknowledgement timeout for request #{message}")
              # TODO cleanup work for the backup job
              EM.stop
            end
            subscription = worker_nats.request(channel, message) do |msg|
              worker_nats.unsubscribe(subscription)
              EM.cancel_timer(timer)
              res = SimpleResponse.decode(msg)
              if res.success
                @logger.info("Acknowledgement for request #{message} successfully received")
              else
                @logger.error("Backup Job for #{message} failed between Gateway & Controller. Error: #{res.error}")
                # TODO cleanup work for the backup job
              end
              EM.stop
            end
          end
        end
      else
        @logger.error("Send message error. Can not connect to nats")
      end
    end
  end
end
