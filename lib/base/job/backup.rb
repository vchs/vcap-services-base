require "resque-status"
require "fileutils"
require "vcap/logging"
require "fog"

require_relative "./base"

module VCAP::Services::Base::AsyncJob
  module Backup

    LOCAL_BACKUP_PATH = "/tmp".freeze
    FILTER_KEYS = %w(backup_id size date).freeze

    def fmt_time()
      # UTC time in ISO 8601 format.
      Time.now.utc.strftime("%FT%TZ")
    end

    def filter_keys(backup)
      return unless backup.is_a? Hash
      backup.select {|k,v| FILTER_KEYS.include? k.to_s}
    end

    class DBClient
      class << self
        INSTANCE_INFO_KEY_PREFIX = "vcap:backups:instance".freeze
        SINGLE_BACKUP_KEY_PREFIX = "vcap:backup".freeze
        attr_accessor :logger

        def connection
          @redis ||= ::Redis.new(Config.redis_config)
        end

        def get_content(key)
          value = connection.get(key)
          return nil unless value
          VCAP.symbolize_keys(Yajl::Parser.parse(value))
        end

        def set_content(key, msg)
          value = Yajl::Encoder.encode(msg)
          connection.set(key, value)
        end

        def delete(key)
          connection.del(key)
        end

        def execute_as_transaction
          connection.multi do
            yield
          end
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

        def get_single_backup_info(service_id, backup_id)
          return unless service_id && backup_id
          get_content("#{SINGLE_BACKUP_KEY_PREFIX}:#{service_id}:#{backup_id}")
        end

        def set_single_backup_info(service_id, backup_id, msg)
          return unless service_id && backup_id && msg.is_a?(Hash)
          set_content("#{SINGLE_BACKUP_KEY_PREFIX}:#{service_id}:#{backup_id}", msg)
        end

        def delete_single_backup_info(service_id, backup_id)
          return unless service_id && backup_id
          delete("#{SINGLE_BACKUP_KEY_PREFIX}:#{service_id}:#{backup_id}")
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

        def delete_file(service_name, service_id, file_name)
          file = get_file(service_name, service_id, file_name)
          result = file.nil? ? false : file.destroy
          if result
            dir = connection.directories.get(backup_dir(service_name, service_id))
            result = dir.destroy if dir.files.empty?
          end
          @logger.info("Remove backup from blobstore dir: #{backup_dir(service_name, service_id)} file name #{file_name}, success #{result}") if @logger
        end
      end
    end

    # common utils for backup job
    class BackupJob < BaseJob
      attr_reader :backup_id

      include Backup

      def initialize(*args)
        super(*args)
        DBClient.logger = Config.logger
        StorageClient.logger = Config.logger
      end

      def lock_key
        "lock:backup:#{name}"
      end

      def get_dump_path
        LOCAL_BACKUP_PATH
      end

      def success_response(bid, properties)
        response = BackupJobResponse.new
        response.success = true
        response.properties = properties.merge({:status => "completed"})
        response.encode
      end

      def failed_response(bid, properties, error_msg)
        response = BackupJobResponse.new
        response.success = false
        response.properties = properties.merge({:status => "failed"})
        response.error = error_msg
        response.encode
      end

    end
  end
end
