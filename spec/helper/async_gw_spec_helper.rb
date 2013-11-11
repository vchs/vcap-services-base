require 'base/asynchronous_service_gateway'
require 'base/custom_resource_manager'
require 'base/service_error'

class AsyncGatewayTests
  CC_PORT = 34512
  GW_PORT = 34513
  NODE_TIMEOUT = 5

  def self.create_nice_gateway
    MockGateway.new(true)
  end

  def self.create_nice_gateway_with_custom_resource_manager
    MockGateway.new(true, nil, -1, 3, false, true)
  end

  def self.create_nice_gateway_with_invalid_cc
    MockGateway.new(true, nil, -1, 3, true)
  end

  def self.create_nasty_gateway
    MockGateway.new(false)
  end

  def self.create_check_orphan_gateway(nice, check_interval, double_check_interval)
    MockGateway.new(nice, nil, check_interval, double_check_interval)
  end

  def self.create_timeout_gateway(nice, timeout)
    MockGateway.new(nice, timeout)
  end

  def self.create_cloudcontroller
    MockCloudController.new
  end

  class MockCustomResourceManager < VCAP::Services::CustomResourceManager

    RESOURCE_NAME = "foo"

    include VCAP::Services::Base::Error

    attr_accessor :last_request_args

    def initialize(opts)
      super(opts)
    end

    def create_foo(resource_id, args = {}, blk)
      @last_request_args = args
      @last_request_args[:resource_id] = resource_id

      blk.call(success(args))
    end
  end

  class MockGateway
    attr_accessor :create_resource_http_code
    attr_accessor :update_resource_http_code

    attr_accessor :response

    attr_accessor :provision_http_code
    attr_accessor :unprovision_http_code
    attr_accessor :bind_http_code
    attr_accessor :unbind_http_code
    attr_accessor :restore_http_code
    attr_accessor :recover_http_code
    attr_reader   :migrate_http_code
    attr_reader   :instances_http_code
    attr_reader   :purge_orphan_http_code
    attr_reader   :check_orphan_http_code
    attr_reader   :snapshots_http_code
    attr_accessor :last_snapshot

    attr_reader :service_unique_id, :plan_unique_id, :label

    def initialize(nice, timeout=nil, check_interval=-1, double_check_interval=3, cc_invalid=false, create_custom_resource_manager=false)
      @token = '0xdeadbeef'
      @cc_head = {
        'Content-Type'         => 'application/json',
        'X-VCAP-Service-Token' => @token,
      }
      logger = Logger.new(STDOUT)
      logger.level = Logger::ERROR
      @label = "service-1.0"
      @service_unique_id = 'service_unique_id'
      @plan_unique_id = 'plan_unique_id'
      if timeout
        # Nice timeout provisioner will finish the job in timeout,
        # while un-nice timeout provisioner won't.
        @sp = nice ?
          TimeoutProvisioner.new(timeout - 1) :
          TimeoutProvisioner.new(timeout + 1)
      else
        @sp = nice ? NiceProvisioner.new : NastyProvisioner.new
      end
      @service_timeout = timeout ? timeout + 1 : 10
      options = {
        :service => { :unique_id => service_unique_id,
                      :label => label,
                      :name => 'service',
                      :version => '1.0',
                      :description => 'sample desc',
                      :plans => {
                        'free' => {
                          :unique_id => plan_unique_id,
                          :free => true,
                        }
                      },
                      :tags => ['nosql'],
                      :supported_versions => ["1.0"],
                      :version_aliases => {},
                      :url => 'http://localhost',
                      :timeout => @service_timeout,
                      :plan_options => [],
                      :default_plan => 'free',
                    },
        :token   => @token,
        :provisioner => @sp,
        :node_timeout => timeout || NODE_TIMEOUT,
        :cloud_controller_uri => "http://localhost:#{CC_PORT}",
        :check_orphan_interval => check_interval,
        :double_check_orphan_interval => double_check_interval,
        :logger => logger,

      }
      options[:cloud_controller_uri] = "http://invalid_uri" if cc_invalid
      if create_custom_resource_manager
        options[:custom_resource_manager] = MockCustomResourceManager.new(options)
      end

      sg = VCAP::Services::AsynchronousServiceGateway.new(options)
      @server = Thin::Server.new('localhost', GW_PORT, sg)
      if @service_timeout
        @server.timeout = [@service_timeout + 1, Thin::Server::DEFAULT_TIMEOUT].max
      end

      @create_resource_http_code = 0
      @get_resource_http_code = 0
      @update_resource_http_code = 0
      @delete_resource_http_code = 0

      @provision_http_code = 0
      @unprovision_http_code = 0
      @bind_http_code = 0
      @unbind_http_code = 0
      @restore_http_code = 0
      @recover_http_code = 0
      @migrate_http_code = 0
      @instances_http_code = 0
      @purge_orphan_http_code = 0
      @check_orphan_http_code = 0
      @snapshots_http_code = 0
      @last_service_id = nil
      @last_bind_id = nil
      @last_snapshot = nil
    end

    def start
      Thread.new { @server.start }
    end

    def stop
      @server.stop
    end

    def gen_req(body = nil)
      req = { :head => @cc_head }
      req[:body] = body if body
      req
    end

    def check_orphan_invoked
      @sp.check_orphan_invoked
    end

    def double_check_orphan_invoked
      @sp.double_check_orphan_invoked
    end

    def send_create_resource_request(msg_opts={})
      msg = VCAP::Services::Internal::PerformOperationRequest.new(
          {
              :args => {"foo" => "bar"},
          }.merge(msg_opts)
      ).encode
      url = "http://localhost:#{GW_PORT}/gateway/v1/resources/#{MockCustomResourceManager::RESOURCE_NAME}"
      http = EM::HttpRequest.new(url, :inactivity_timeout => @service_timeout).post(gen_req(msg))
      http.callback {
        @create_resource_http_code = http.response_header.status
        @response = http.response
      }
      http.errback {
        @create_resource_http_code = -1
        @response = http.response
      }
    end

    def send_update_resource_request(msg_opts={})
      msg = VCAP::Services::Internal::PerformOperationRequest.new(
          {
              :args => {"foo" => "bar"},
          }.merge(msg_opts)
      ).encode
      url = "http://localhost:#{GW_PORT}/gateway/v1/resources/#{MockCustomResourceManager::RESOURCE_NAME}/12345"
      http = EM::HttpRequest.new(url, :inactivity_timeout => @service_timeout).put(gen_req(msg))
      http.callback {
        @update_resource_http_code = http.response_header.status
        @response = http.response
      }
      http.errback {
        @update_resource_http_code = -1
        @response = http.response
      }
    end

    def send_provision_request(msg_opts={})
      msg = VCAP::Services::Api::GatewayProvisionRequest.new(
        {
          :unique_id => plan_unique_id,
          :name  => 'service',
          :email => "foobar@abc.com",
        }.merge(msg_opts)
      ).encode
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v1/configurations", :inactivity_timeout => @service_timeout).post(gen_req(msg))
      http.callback {
        @provision_http_code = http.response_header.status
        if @provision_http_code == 200
          res = VCAP::Services::Api::GatewayHandleResponse.decode(http.response)
          @last_service_id = res.service_id
        end
      }
      http.errback {
        @provision_http_code = -1
      }
    end

    def send_unprovision_request(service_id = nil)
      service_id ||= @last_service_id
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v1/configurations/#{service_id}").delete(gen_req)
      http.callback {
        @unprovision_http_code = http.response_header.status
      }
      http.errback {
        @unprovision_http_code = -1
      }
    end

    def send_bind_request(service_id = nil)
      service_id ||= @last_service_id
      msg = VCAP::Services::Api::GatewayBindRequest.new(
        :service_id => service_id,
        :label => label,
        :email => "foobar@abc.com",
        :binding_options => {}
      ).encode
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v1/configurations/#{service_id}/handles").post(gen_req(msg))
      http.callback {
        @bind_http_code = http.response_header.status
        if @bind_http_code == 200
          res = VCAP::Services::Api::GatewayHandleResponse.decode(http.response)
          @last_bind_id = res.service_id
        end
      }
      http.errback {
        @bind_http_code = -1
      }
    end

    def send_unbind_request(service_id = nil, bind_id = nil)
      service_id ||= @last_service_id
      bind_id ||= @last_bind_id
      msg = Yajl::Encoder.encode({
        :service_id => service_id,
        :handle_id => bind_id,
        :binding_options => {}
      })
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v1/configurations/#{service_id}/handles/#{bind_id}").delete(gen_req(msg))
      http.callback {
        @unbind_http_code = http.response_header.status
      }
      http.errback {
        @unbind_http_code = -1
      }
    end

    def send_restore_request(service_id = nil)
      service_id ||= @last_service_id
      msg = Yajl::Encoder.encode({
        :instance_id => service_id,
        :backup_path => '/'
      })
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/restore").post(gen_req(msg))
      http.callback {
        @restore_http_code = http.response_header.status
      }
      http.errback {
        @restore_http_code = -1
      }
    end

    def send_recover_request(service_id = nil)
      service_id ||= @last_service_id
      msg = Yajl::Encoder.encode({
        :instance_id => service_id,
        :backup_path => '/'
      })
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/recover").post(gen_req(msg))
      http.callback {
        @recover_http_code = http.response_header.status
      }
      http.errback {
        @recover_http_code = -1
      }
    end

    def send_migrate_request(service_id = nil)
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/migration/test_node/test_instance/test_action").post(gen_req)
      http.callback {
        @migrate_http_code = http.response_header.status
      }
      http.errback {
        @migrate_http_code = -1
      }
    end

    def send_instances_request(service_id = nil)
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/migration/test_node/instances").get(gen_req)
      http.callback {
        @instances_http_code = http.response_header.status
      }
      http.errback {
        @instances_http_code = -1
      }
    end

    def send_purge_orphan_request
      msg = Yajl::Encoder.encode({
        :orphan_instances => TEST_PURGE_INS_HASH,
        :orphan_bindings => TEST_PURGE_BIND_HASH
      })
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/purge_orphan").delete(gen_req(msg))
      http.callback {
        @purge_orphan_http_code = http.response_header.status
      }
      http.errback {
        @purge_orphan_http_code = -1
      }
    end
    def send_check_orphan_request
      msg = Yajl::Encoder.encode({
      })
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/service/internal/v1/check_orphan").post(gen_req(msg))
      http.callback {
        @check_orphan_http_code = http.response_header.status
      }
      http.errback {
        @check_orphan_http_code = -1
      }
    end

    def send_get_v2_snapshots_request
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v2/configurations/test/snapshots").get(gen_req)
      http.callback {
        @snapshots_http_code = http.response_header.status
        if @snapshots_http_code == 200
          res = VCAP::Services::Api::SnapshotListV2.decode(http.response)
        end
      }
      http.errback {
        @snapshots_http_code = -1
      }
    end

    def send_create_v2_snapshot_request(name)
      payload= Yajl::Encoder.encode({'name' => name})
      http = EM::HttpRequest.new("http://localhost:#{GW_PORT}/gateway/v2/configurations/test/snapshots").post(gen_req(payload))
      http.callback {
        @snapshots_http_code = http.response_header.status
        if @snapshots_http_code == 200
          @last_snapshot = VCAP::Services::Api::SnapshotV2.decode(http.response)
        end
      }
      http.errback {
        @snapshots_http_code = -1
      }
    end
  end

  class MockCloudController
    def initialize
      @server = Thin::Server.new('localhost', CC_PORT, Handler.new)
    end

    def start
      Thread.new { @server.start }
    end

    def stop
      @server.stop if @server
    end

    class Handler < Sinatra::Base
      post "/services/v1/offerings" do
        "{}"
      end

      get "/services/v1/offerings/:label/handles" do
        Yajl::Encoder.encode({
          :handles => [{
            'service_id' => MockProvisioner::SERV_ID,
            'configuration' => {},
            'credentials' => {}
          }]
        })
      end

      get "/services/v1/offerings/:label/handles/:id" do
        "{}"
      end
    end
  end

  class MockProvisioner
    SERV_ID = "service_id"
    BIND_ID = "bind_id"

    include VCAP::Services::Base::Error

    attr_accessor :got_provision_request
    attr_accessor :got_unprovision_request
    attr_accessor :got_bind_request
    attr_accessor :got_unbind_request
    attr_accessor :got_restore_request
    attr_accessor :got_recover_request
    attr_accessor :got_migrate_request
    attr_accessor :got_instances_request
    attr_reader   :purge_orphan_invoked
    attr_reader   :check_orphan_invoked
    attr_reader   :double_check_orphan_invoked

    attr_reader :node_nats

    def initialize
      @got_provision_request = false
      @got_unprovision_request = false
      @got_bind_request = false
      @got_unbind_request = false
      @got_restore_request = false
      @got_recover_request = false
      @got_migrate_request = false
      @got_instances_request = false
      @purge_orphan_invoked = false
      @check_orphan_invoked = false
      @double_check_orphan_invoked = false

      @node_nats = nil
    end

    def register_update_handle_callback
      # Do nothing
    end

    def update_handles(handles)
      # Do nothing
    end

    def update_responses_metrics(status)
      # Do nothing
    end

  end

  class NiceProvisioner < MockProvisioner
    def provision_service(request, prov_handle=nil, &blk)
      @got_provision_request = true
      blk.call(success({:configuration => {}, :service_id => SERV_ID, :credentials => {}}))
    end

    def unprovision_service(instance_id, &blk)
      @got_unprovision_request = true
      blk.call(success(true))
    end

    def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
      @got_bind_request = true
      blk.call(success({:configuration => {}, :service_id => BIND_ID, :credentials => {}}))
    end

    def unbind_instance(instance_id, handle_id, binding_options, &blk)
      @got_unbind_request = true
      blk.call(success(true))
    end

    def restore_instance(instance_id, backup_path, &blk)
      @got_restore_request = true
      blk.call(success(true))
    end

    def recover(instance_id, backup_path, handles, &blk)
      @got_recover_request = true
      blk.call(success(true))
    end

    def migrate_instance(node_id, instance_id, action, &blk)
      @got_migrate_request = true
      blk.call(success(true))
    end

    def get_instance_id_list(node_id, &blk)
      @got_instances_request = true
      blk.call(success(true))
    end

    def purge_orphan(orphan_ins_hash, orphan_binding_hash, &blk)
      @purge_orphan_invoked = true
      blk.call(success(true))
    end

    def check_orphan(handles, &blk)
      @check_orphan_invoked = true
      blk.call(success(true))
    end

    def double_check_orphan(handles)
      @double_check_orphan_invoked = true
    end

    def enumerate_snapshots_v2(service_id, &blk)
      blk.call(success([]))
    end

    def create_snapshot_v2(service_id, name, &blk)
      blk.call(success("snapshot_id" => "999", "name" => name, "state" => "empty", "size" => 0))
    end
  end

  class NastyProvisioner < MockProvisioner
    def provision_service(request, prov_handle=nil, &blk)
      @got_provision_request = true
      blk.call(internal_fail)
    end

    def unprovision_service(instance_id, &blk)
      @got_unprovision_request = true
      blk.call(internal_fail)
    end

    def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
      @got_bind_request = true
      blk.call(internal_fail)
    end

    def unbind_instance(instance_id, handle_id, binding_options, &blk)
      @got_unbind_request = true
      blk.call(internal_fail)
    end

    def restore_instance(instance_id, backup_path, &blk)
      @got_restore_request = true
      blk.call(internal_fail)
    end

    def recover(instance_id, backup_path, handles, &blk)
      @got_recover_request = true
      blk.call(internal_fail)
    end

    def migrate_instance(node_id, instance_id, action, &blk)
      @got_migrate_request = true
      blk.call(internal_fail)
    end

    def get_instance_id_list(node_id, &blk)
      @got_instances_request = true
      blk.call(internal_fail)
    end

    def purge_orphan(orphan_ins_hash,orphan_binding_hash,&blk)
      @purge_orphan_invoked = true
      blk.call(internal_fail)
    end
    def check_orphan(handles,&blk)
      @check_orphan_invoked = true
      blk.call(internal_fail)
    end
    def create_snapshot_v2(service_id, name, &blk)
      blk.call(internal_fail)
    end
  end

  # Timeout Provisioner is a simple version of provisioner.
  # It only support provisioning.
  class TimeoutProvisioner < MockProvisioner
    def initialize(timeout)
      @timeout = timeout
    end

    def provision_service(request, prov_handle=nil, &blk)
      @got_provision_request = true
      EM.add_timer(@timeout) do
        blk.call(
          success({
            :configuration => {},
            :service_id => SERV_ID,
            :credentials => {}
            }
          )
        )
      end
    end
  end
end
