# Copyright (c) 2009-2013 VMware, Inc.
require 'helper/spec_helper'

module VCAP::Services::ServicesControllerClient
  module ScCatalogManagerV1Helper
    def load_config
      config = {
          :cloud_controller_uri => 'api.vcap.me',
          :token => 'token',
          :gateway_name => 'test_gw',
          :logger => make_logger,
          :auth_key => "a@b.c:abc"
      }
    end

    def make_logger(level=Logger::INFO)
      logger = Logger.new STDOUT
      logger.level = level
      logger
    end
  end
end

