require 'helper/spec_helper'
require 'base/services_controller_client/catalog_manager_sc_v1'

describe VCAP::Services::ServicesControllerClient::SCCatalogManagerV1 do
  let(:logger) { Logger.new('/tmp/vcap_services_base.log') }
  let(:http_handler) { double('http_handler', cc_http_request: nil, cc_req_hdrs: {}) }

  let(:config) do
    {
        :cloud_controller_uri => 'api.vcap.me',
        :token => 'token',
        :gateway_name => 'test_gw',
        :logger => logger,
        :auth_key => "a@b.c:abc"
    }
  end
  let(:catalog_manager) { described_class.new(config) }

  before(:each) do
    HTTPHandler.stub(new: http_handler)
  end

  it 'creates a http handler with correct params' do
    HTTPHandler.should_receive(:new).with do | *args |
      args.size.should == 2
      args[0].should == config
      args[1].is_a? Proc
    end
    catalog_manager
  end

  describe "#update_catalog" do
    let(:manager) { described_class.new(config) }
    let(:catalog_loader) { -> {} }
    let(:registered_services) { double('registered service', load_registered_services: {}) }

    before do
      VCAP::Services::ServicesControllerClient::MultiplePageGetter.stub(:new => registered_services)
    end

    it "loads the services from the gateway" do
      catalog_loader.should_receive(:call)
      manager.update_catalog(true, catalog_loader)
    end

    it "get the registered services from Services Controller" do
      registered_services.should_receive(:load_registered_services).
          with("/api/v1/services")
      manager.update_catalog(true, catalog_loader)
    end

    it 'logs error if getting catalog fails' do
      catalog_loader.stub(:call).and_raise('Failed')
      logger.should_receive(:error).twice
      manager.update_catalog(true, catalog_loader)
    end

    it "updates the stats" do
      manager.update_catalog(true, catalog_loader)
      manager.instance_variable_get(:@gateway_stats)[:refresh_catalog_requests].should == 1
    end
  end
end
