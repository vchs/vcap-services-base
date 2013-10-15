# Copyright (c) 2009-2011 VMware, Inc.
require 'helper/job_spec_helper'
require 'mock_redis'

module VCAP::Services::Base::AsyncJob::Backup
  describe DBClient do

    before(:all) do
      DBClient.instance_variable_set(:@redis, MockRedis.new)
    end

    it "should set, get & delete backup instance info" do
      service_id = "1"
      msg = {:test => 1}
      DBClient.set_instance_backup_info(service_id, msg)
      DBClient.get_instance_backup_info(service_id).should == msg
      DBClient.delete_instance_backup_info(service_id)
      DBClient.get_instance_backup_info(service_id).should == nil
    end

    it "should set, get & delete single backup info" do
      service_id = "1"
      backup_id = "1"
      msg = {:test => 1}
      DBClient.set_single_backup_info(service_id, backup_id, msg)
      DBClient.get_single_backup_info(service_id, backup_id).should == msg
      DBClient.delete_single_backup_info(service_id, backup_id)
      DBClient.get_single_backup_info(service_id, backup_id).should == nil
    end

    it "should be able to handle nil or invalid value" do
      expect { DBClient.set_instance_backup_info(nil, {}) }.not_to raise_error
      DBClient.get_instance_backup_info(nil).should == nil
      expect { DBClient.delete_instance_backup_info(nil) }.not_to raise_error


      expect { DBClient.set_single_backup_info(nil, nil, {}) }.not_to raise_error
      DBClient.get_single_backup_info(nil, nil).should == nil
      expect { DBClient.delete_single_backup_info(nil, nil) }.not_to raise_error

      service_id = "1"
      invalid_msg = "1"
      DBClient.set_instance_backup_info(service_id, invalid_msg)
      DBClient.get_instance_backup_info(service_id).should == nil

      backup_id = "2"
      DBClient.set_single_backup_info(service_id,  backup_id, invalid_msg)
      DBClient.get_single_backup_info(service_id, backup_id).should == nil
    end
  end

  describe StorageClient do
    before(:all) do
      Fog.mock!
      @connection = Fog::Storage.new({
        :aws_access_key_id      => 'fake_access_key_id',
        :aws_secret_access_key  => 'fake_secret_access_key',
        :provider               => 'AWS'
      })
      StorageClient.instance_variable_set(:@storage_connection, @connection)

      @tmp_files = []
    end

    it "should be able to store, get & delete file" do
      local_path = "/tmp/test"
      content = "test content"
      File.open(local_path, "w") { |f| f.write(content) }
      @tmp_files << local_path

      service_name = "mysql"
      service_id = "1"
      file_name = "file_in_storage_server"
      StorageClient.store_file(service_name, service_id, file_name, local_path)
      save_to_path = "/tmp/test1"
      file = StorageClient.get_file(service_name, service_id, file_name, save_to_path)
      @tmp_files << save_to_path
      file.body.should == content
      File.read(save_to_path).should == content

      StorageClient.store_file(service_name, service_id, file_name + "_dup", local_path)

      StorageClient.delete_file(service_name, service_id, file_name)
      file = StorageClient.get_file(service_name, service_id, file_name, save_to_path)
      file.should == nil

      dir = @connection.directories.get(StorageClient.backup_dir(service_name, service_id))
      dir.should_not == nil
      StorageClient.delete_file(service_name, service_id, file_name + "_dup")
      dir = @connection.directories.get(StorageClient.backup_dir(service_name, service_id))
      dir.should == nil
    end

    after(:all) do
      @tmp_files.each { |f| FileUtils.rm_rf(f, :secure => true) }
    end
  end
end
