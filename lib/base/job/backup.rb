require "resque-status"
require "fileutils"
require "vcap/logging"
require "fog"

require_relative "../service_error"
require_relative "./package.rb"

module VCAP::Services::Base::AsyncJob
  module Backup
    include VCAP::Services::Base::Error

    LOCAL_BACKUP_PATH = "/tmp".freeze

    def fmt_time()
      # UTC time in ISO 8601 format.
      Time.now.utc.strftime("%FT%TZ")
    end

    class DBClient
      class << self
        INSTANCE_INFO_KEY_PREFIX = "vcap:backups:info".freeze
        SINGLE_BACKUP_KEY_PREFIX = "vcap:backup".freeze
        attr_accessor :logger

        def connection
          @redis ||= ::Redis.new(Config.redis_config)
        end

        def get_content(key)
          value = connection.get(key)
          return nil unless value
          Yajl::Parser.parse(value)
        end

        def set_content(key, msg)
          value = Yajl::Encoder.encode(msg)
          connection.set(key, value)
        end

        def delete(key)
          connection.del(key)
        end

        def get_instance_backup_info(service_id)
          return unless service_id
          get_content("#{INSTANCE_INFO_KEY_PREFIX}:#{service_id}")
        end

        def set_instance_backup_info(service_id, msg)
          return unless service_id && msg.is_a?(Hash)
          set_content("#{INSTANCE_INFO_KEY_PREFIX}:#{service_id}", msg)
        end

        def delete_instance_backup_info(service_id)
          return unless service_id
          delete("#{INSTANCE_INFO_KEY_PREFIX}:#{service_id}")
          @logger.info("Delete instance backup info for #{service_id}") if @logger
        end

        def get_single_backup_info(backup_id)
          return unless backup_id
          get_content("#{SINGLE_BACKUP_KEY_PREFIX}:#{backup_id}")
        end

        def set_single_backup_info(backup_id, msg)
          return unless backup_id && msg.is_a?(Hash)
          set_content("#{SINGLE_BACKUP_KEY_PREFIX}:#{backup_id}", msg)
        end

        def delete_single_backup_info(backup_id)
          return unless backup_id
          delete("#{SINGLE_BACKUP_KEY_PREFIX}:#{backup_id}")
          @logger.info("Delete single backup info for #{backup_id}") if @logger
        end
      end
    end

    class StorageClient
      class << self
        attr_accessor :logger

        def connection
          @storage_connection ||= Fog::Storage.new(Config.fog_config)
        end

        def backup_dir(service_name, service_id)
          "backup_#{service_name}_#{service_id}"
        end

        def store_file(service_name, service_id, file_name, local_path)
          dir_name = backup_dir(service_name, service_id)
          dir = connection.directories.get(dir_name)
          dir = connection.directories.create({
            :key    => dir_name,
            :public => false
          }) unless dir
          dir.files.create(
            :key    => file_name,
            :body   => File.open(local_path),
            :public => false
          ) if dir
          @logger.info("Store backup into blobstore dir: #{dir_name} file name #{file_name}") if @logger
        end

        def get_file(serivce_name, service_id, file_name, local_path = nil)
          dir_name = backup_dir(serivce_name, service_id)
          dir = connection.directories.get(dir_name)
          file = dir.nil? ? nil : dir.files.get(file_name)
          File.open(local_path, "w") { |f| f.write(file.body) } if file && local_path
          @logger.info("Get backup from blobstore dir: #{dir_name} file name #{file_name} and save it to #{local_path}") if @logger
          file
        end

        def delete_file(serivce_name, service_id, file_name)
          file = get_file(serivce_name, service_id, file_name)
          result = file.nil? ? false : file.destroy
          @logger.info("Remove backup from blobstore dir: #{backup_dir(serivce_name, service_id)} file name #{file_name}, success #{result}") if @logger
        end
      end
    end

    # common utils for backup job
    class BackupJob
      attr_reader :name, :backup_id

      include Backup
      include Resque::Plugins::Status

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
        Backup.DBClient.logger = Config.logger
        Backup.StorageClient.logger = Config.logger
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
        lock_name = "lock:backup:#{name}"
        ttl = @config['job_ttl'] || 600
        lock = Lock.new(lock_name, :logger => @logger, :ttl => ttl)
        lock
      end

      def get_dump_path
        LOCAL_BACKUP_PATH
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
      end
    end
  end
end
