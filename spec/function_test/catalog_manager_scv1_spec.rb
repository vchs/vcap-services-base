require 'helper/spec_helper'
require 'base/services_controller_client/catalog_manager_sc_v1'
require 'helper/catalog_manager_scv1_spec_helper'

module VCAP::Services::ServicesControllerClient
  describe SCCatalogManagerV1 do
    include VCAP::Services::ServicesControllerClient::ScCatalogManagerV1Helper

    before do
      WebMock.disable_net_connect!
    end

    let(:catalog_manager) do
      config = load_config
      config[:logger].level = Logger::DEBUG
      config[:cloud_controller_uri] = "http://api.vcap.me"
      SCCatalogManagerV1.new(config)
    end

    it 'advertises with unique_id' do
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      catalog =
        {"id_provider" =>
          {
              "description" => 'description',
              "provider" => 'provider',
              "version" => '1.0',
              "url" => 'url',
              "plans" => {
                  'free' => {
                      description: 'description',
                      free: true,
                      extra: nil,
                      unique_id: unique_plan_id,
                  },
              },
              "unique_id" => unique_service_id,
              "label" => 'id-1',
              "active" => true,
              "acls" => 'acls',
              "timeout_secs" => 30,
              "extra" => 'extra'
          }
      }
      stub_request(:get, "http://api.vcap.me/api/v1/services").
          to_return(:status => 200, :body => Yajl::Encoder.encode({
                                                                      "total_results" => 0,
                                                                      "total_pages" => 0,
                                                                      "prev_url" => nil,
                                                                      "next_url" => nil,
                                                                      "resources" => []
                                                                  }))
      stub_request(:post, "http://api.vcap.me/api/v1/services").
          to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => 'service_guid'}))

      stub_request(:post, "http://api.vcap.me/api/v1/service_plans").
          to_return(:status => 200, :body => Yajl::Encoder.encode({
                                                                      "total_results" => 0,
                                                                      "total_pages" => 0,
                                                                      "prev_url" => nil,
                                                                      "next_url" => nil,
                                                                      "resources" => []
                                                                  }))

      EM.run do
        catalog_manager.update_catalog(
            true,
            lambda { return catalog },
            nil)
        EM.add_timer(1) { EM.stop }
      end

      a_request(:post, "http://api.vcap.me/api/v1/services").with do |req|
        JSON.parse(req.body).fetch('id').should == unique_service_id
      end.should have_been_made

      a_request(:post, "http://api.vcap.me/api/v1/service_plans").with do |req|
        JSON.parse(req.body).fetch('id').should == unique_plan_id
      end.should have_been_made
    end

    it "updates existing plans and services without sending unique_id" do
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      cc_service_guid = 'service-guid'
      cc_service_plan_guid = 'plan-guid'
      service_label = 'id-1.0'
      service_provider = 'provider'
      old_description = 'old description'
      new_description = 'a totally different description'
      old_plan_description = 'old plan description'
      new_plan_description = 'new plan description'

      updated_catalog = {
          "#{service_label}_#{service_provider}" =>
               {
                   "description" => new_description,
                   "provider" => service_provider,
                   "version" => '1.0',
                   "url" => 'url',
                   "plans" => {
                       'free' => {
                           description: new_plan_description,
                           free: true,
                           extra: nil,
                           unique_id: unique_plan_id,
                       },
                   },
                   "unique_id" => unique_service_id,
                   "label" => service_label,
                   "active" => true,
                   "acls" => 'acls',
                   "timeout_secs" => 30,
                   "extra" => 'extra'
               }
      }

      stub_request(:get, "http://api.vcap.me/api/v1/services").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
            "total_results" => 1,
            "total_pages" => 1,
            "prev_url" => nil,
            "next_url" => nil,
            "resources" => [
              {
                'metadata' => {
                    'guid' => cc_service_guid,
                    "url" => "http://api.vcap.me/api/v1/services/92a06847-9446-407f-8aaa-a6f20c1d2cdc",
                    "created_at" => "2013-10-16 18:20:54 UTC",
                    "updated_at" => "2013-10-16 18:25:33 UTC"
                },
                'entity' => {
                    'id' => unique_service_id,
                    'label' => service_label,
                    'version' => '1.0',
                    'active' => true,
                    "url" => 'url',
                    'timeout_secs' => 30,
                    'provider' => service_provider,
                    'description' => old_description,
                    'properties' => nil,
                }
              },
            ]
          }))

      stub_request(:get, "http://api.vcap.me/api/v1/service_plans?service_id=#{cc_service_guid}").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 1,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_plan_guid,
                          "url" => "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_plan_id,
                          'service_id' => unique_service_id,
                          'name' => 'free',
                          'version' => "1",
                          'description' => old_plan_description,
                          'properties' => "{\"free\":true,\"extra\":null,\"public\":true}"
                      }
                  },
              ]
          }))

      stub_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").
          to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

      stub_request(:put, "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}").
          to_return(status: 200)

      EM.run do
        catalog_manager.update_catalog(true, -> { updated_catalog })
        EM.add_timer(1) { EM.stop }
      end

      a_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").with do |req|
        true
      end.should have_been_made

      a_request(:put, "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}").with do |req|
        true
      end.should have_been_made
    end

    it 'updates the service and service_plan with new field values' do
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      cc_service_guid = 'service-guid'
      cc_service_plan_guid = 'cc_service_plan_guid'
      service_label = 'id-1.0'
      service_provider = 'provider'
      old_timeout_secs = 30
      updated_timeout_secs = 60
      free_plan_extra_new = "new_props"

      updated_catalog =
          {"id_provider" =>
               {
                   "description" => 'description',
                   "provider" => 'provider',
                   "version" => '1.0',
                   "url" => 'url',
                   "plans" => {
                       'free' => {
                           description: 'description',
                           free: true,
                           extra: free_plan_extra_new,
                           unique_id: unique_plan_id,
                       },
                   },
                   "unique_id" => unique_service_id,
                   "label" => 'id-1',
                   "active" => true,
                   "acls" => 'acls',
                   "timeout" => updated_timeout_secs,
                   "extra" => 'extra'
               }
          }
      stub_request(:get, "http://api.vcap.me/api/v1/services").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 1,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_guid,
                          "url" => "http://api.vcap.me/api/v1/services/92a06847-9446-407f-8aaa-a6f20c1d2cdc",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_service_id,
                          'label' => service_label,
                          'version' => '1.0',
                          'active' => true,
                          "url" => 'url',
                          'timeout_secs' => old_timeout_secs,
                          'provider' => service_provider,
                          'description' => 'description',
                          'properties' => nil,
                      }
                  },
              ]
          }))

      stub_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").
          to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

      stub_request(:get, "http://api.vcap.me/api/v1/service_plans?service_id=#{cc_service_guid}").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 1,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_plan_guid,
                          "url" => "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_plan_id,
                          'service_id' => unique_service_id,
                          'name' => 'free',
                          'version' => "1",
                          'description' => "description",
                          'properties' => "{\"free\":true,\"extra\":null,\"public\":true}"
                      }
                  },
              ]
          }))

      stub_request(:put, "http://api.vcap.me/api/v1/service_plans/cc_service_plan_guid").
          to_return(:status => 200, :body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_plan_guid}))

      EM.run do
        catalog_manager.update_catalog(true, -> { updated_catalog })
        EM.add_timer(1) { EM.stop }
      end

      a_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").with do |req|
        JSON.parse(req.body).fetch('timeout_secs').should == updated_timeout_secs
        true
      end.should have_been_made

      a_request(:put, "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}").with do |req|
        JSON.parse(JSON.parse(req.body).fetch('properties')).fetch('extra').should == free_plan_extra_new
        true
      end.should have_been_made

    end

    it 'filters out and updates only the services offered by this gateway' do
      unique_service_id = 'unique_service_id'
      unique_plan_id = 'unique_plan_id'
      cc_service_guid = 'service-guid'
      cc_service_plan_guid = 'cc_service_plan_guid'
      service_label = 'id-1.0'
      service_provider = 'provider'
      timeout_secs = 30
      free_plan_extra_new = "new_props"

      updated_catalog =
          {
              "id_provider" =>
               {
                   "description" => 'description',
                   "provider" => 'provider',
                   "version" => '1.0',
                   "url" => 'url',
                   "plans" => {
                       'free' => {
                           description: 'description',
                           free: true,
                           extra: free_plan_extra_new,
                           unique_id: unique_plan_id,
                       },
                   },
                   "unique_id" => unique_service_id,
                   "label" => 'id-1',
                   "active" => true,
                   "acls" => 'acls',
                   "timeout" => timeout_secs,
                   "extra" => 'extra'
               }
          }
      stub_request(:get, "http://api.vcap.me/api/v1/services").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 2,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_guid,
                          "url" => "http://api.vcap.me/api/v1/services/92a06847-9446-407f-8aaa-a6f20c1d2cdc",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_service_id,
                          'label' => service_label,
                          'version' => '1.0',
                          'active' => true,
                          "url" => 'url',
                          'timeout_secs' => timeout_secs,
                          'provider' => service_provider,
                          'description' => 'description',
                          'properties' => nil,
                      }
                  },
                  {
                      'metadata' => {
                          'guid' => "some_other_cc_service_guid",
                          "url" => "http://api.vcap.me/api/v1/services/92a06847-9446-407f-8aaa-a6f20c1d2abc",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => "some_other_unique_service_id",
                          'label' => "some_other_service_label",
                          'version' => '1.0',
                          'active' => true,
                          "url" => 'url',
                          'timeout_secs' => timeout_secs,
                          'provider' => service_provider,
                          'description' => 'description',
                          'properties' => nil,
                      }
                  },
              ]
          }))

      stub_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").
          to_return(:body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_guid}))

      stub_request(:get, "http://api.vcap.me/api/v1/service_plans?service_id=#{cc_service_guid}").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 1,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_plan_guid,
                          "url" => "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_plan_id,
                          'service_id' => unique_service_id,
                          'name' => 'free',
                          'version' => "1",
                          'description' => "description",
                          'properties' => "{\"free\":true,\"extra\":null,\"public\":true}"
                      }
                  },
              ]
          }))
      stub_request(:get, "http://api.vcap.me/api/v1/service_plans?service_id=some_other_cc_service_guid").
          to_return(:status => 200, :body => Yajl::Encoder.encode(
          {
              "total_results" => 1,
              "total_pages" => 1,
              "prev_url" => nil,
              "next_url" => nil,
              "resources" => [
                  {
                      'metadata' => {
                          'guid' => cc_service_plan_guid,
                          "url" => "http://api.vcap.me/api/v1/service_plans/#{cc_service_plan_guid}",
                          "created_at" => "2013-10-16 18:20:54 UTC",
                          "updated_at" => "2013-10-16 18:25:33 UTC"
                      },
                      'entity' => {
                          'id' => unique_plan_id,
                          'service_id' => unique_service_id,
                          'name' => 'free',
                          'version' => "1",
                          'description' => "description",
                          'properties' => "{\"free\":true,\"extra\":null,\"public\":true}"
                      }
                  },
              ]
          }))

      stub_request(:put, "http://api.vcap.me/api/v1/service_plans/cc_service_plan_guid").
          to_return(:status => 200, :body => Yajl::Encoder.encode('metadata' => {'guid' => cc_service_plan_guid}))

      EM.run do
        catalog_manager.update_catalog(true, -> { updated_catalog })
        EM.add_timer(1) { EM.stop }
      end

      update_requests_count = 0
      a_request(:put, "http://api.vcap.me/api/v1/services/#{cc_service_guid}").with do |req|
        JSON.parse(req.body).fetch('id').should == unique_service_id
        update_requests_count = update_requests_count + 1
        true
      end.should have_been_made

      update_requests_count.should == 1

    end
  end
end
