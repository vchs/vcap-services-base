require 'helper/spec_helper'
require 'helper/nats_server_helper'
require 'eventmachine'
require 'vcap_services_messages/service_message'

include VCAP::Services::Base::Error

describe ProvisionerTests do
  let(:version) { 'v3' }
  let(:options) { {:provisioner_version => version} }

  describe "Backup jobs v3" do
    it "should create backup job with service_id, node_id and metadata" do
      klass = double("subclass")
      mock_nats = double("test_mock_nats")
      klass.should_receive(:create).with(
        :service_id => "service_id",
        :backup_id  => "backup_id",
        :node_id    => "1",
        :metadata   => {},
      ).and_return(2)
      EM.run do
        provisioner = ProvisionerTests.create_provisioner(options)
        provisioner.nats = mock_nats
        provisioner.should_receive(:before_backup_apis).and_return(true)
        provisioner.should_receive(:create_backup_job).and_return(klass)
        provisioner.should_receive(:find_backup_peer).and_return("1")
        provisioner.should_receive(:backup_metadata).and_return({})
        provisioner.should_receive(:get_job).and_return({})
        provisioner.create_backup("service_id", "backup_id", {}) { |x| }
        EM.next_tick {EM.stop}
      end
    end
  end

  describe "Provisioner" do
    it "should support provision" do
      provisioner = nil
      gateway = nil
      mock_nats = nil
      mock_nodes = nil
      EM.run do
        mock_nats = double("test_mock_nats")
        provisioner = ProvisionerTests.create_provisioner(options)
        # assign mock nats to provisioner
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        mock_nodes = {
            "node-1" => {
                "id" => "node-1",
                "plan" => "free",
                "available_capacity" => 200,
                "capacity_unit" => 1,
                "supported_versions" => ["1.0"],
                "time" => Time.now.to_i
            }
        }
        provisioner.nodes = mock_nodes

        mock_nats.should_receive(:request).with(any_args()).and_return { |*args, &cb|
          response = VCAP::Services::Internal::ProvisionResponse.new
          response.success = true
          response.credentials = {
            "node_id" => "node-1",
            "name" => "D501B915-5B50-4C3A-93B7-7E0C48B6A9FA"
          }
          cb.call(response.encode)
          "5"
        }

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback service_id

        gateway.got_provision_response.should be_true
        provisioner.provision_refs["node-1"].should eq(0)
        EM.stop
      end
    end

    it "should support unprovision" do
      provisioner = nil
      gateway = nil
      mock_nats = nil
      provision_request = ""
      EM.run do
        mock_nats = mock("test_mock_nats")
        provisioner = ProvisionerTests.create_provisioner(options)
        # assign mock nats to provisioner
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        # mock node to send provision & unprovision request
        mock_nodes = {
            "node-1" => {
                "id" => "node-1",
                "plan" => "free",
                "available_capacity" => 200,
                "capacity_unit" => 1,
                "supported_versions" => ["1.0"],
                "time" => Time.now.to_i
            }
        }
        provisioner.nodes = mock_nodes

        mock_nats.should_receive(:request).exactly(2).times.with(any_args()).\
        and_return { |*args, &cb|
          response = VCAP::Services::Internal::SimpleResponse.new
          response.success = true
          cb.call(response.encode)
          "5"
        }

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback(service_id)
        gateway.got_provision_response.should == true

        gateway.send_unprovision_request
        gateway.got_unprovision_response.should == true

        EM.stop
      end
    end

    it "should delete instance handles in cache after unprovision" do
      provisioner = gateway = nil
      mock_nats = nil
      provision_request = ""
      EM.run do
        mock_nats = mock("test_mock_nats")
        provisioner = ProvisionerTests.create_provisioner(options)
        provisioner.get_all_handles.size.should == 0
        # assign mock nats to provisioner
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        # mock node to send unprovision request
        mock_nodes = {
            "node-1" => {
                "id" => "node-1",
                "plan" => "free",
                "available_capacity" => 200,
                "capacity_unit" => 1,
                "supported_versions" => ["1.0"],
                "time" => Time.now.to_i
            }
        }
        provisioner.nodes = mock_nodes

        service_id = nil
        mock_nats.should_receive(:request).exactly(3).times.with(any_args()).\
          and_return { |*args, &cb|
          if provision_request == "Test.unprovision.node-1"
            response = VCAP::Services::Internal::SimpleResponse.new
            response.success = true
          else
            response = VCAP::Services::Internal::BindResponse.new
            response.success = true
            response.credentials = {
              "name" => service_id
            }
          end
          cb.call(response.encode)
          "5"
        }
        mock_nats.stub(:unsubscribe)

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback(service_id)
        gateway.got_provision_response.should be_true

        gateway.send_bind_request

        cache = provisioner.get_all_handles
        cache.size.should == 2

        gateway.send_unprovision_request
        cache = provisioner.get_all_handles
        cache.size.should == 0

        EM.stop
      end
    end

    it "should support bind" do
      provisioner = nil
      gateway = nil
      mock_nats = nil
      provision_request = ""
      EM.run do
        mock_nats = mock("test_mock_nats")
        provisioner = ProvisionerTests.create_provisioner(options)
        # assgin mock nats to provisioner
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        # mock node to send provision & bind request
        mock_nodes = {
            "node-1" => {
                "id" => "node-1",
                "plan" => "free",
                "available_capacity" => 200,
                "capacity_unit" => 1,
                "supported_versions" => ["1.0"],
                "time" => Time.now.to_i
            }
        }
        provisioner.nodes = mock_nodes

        mock_nats.should_receive(:request).twice.with(any_args()).\
        and_return { |*args, &cb|
            provision_request = args[0]
            if provision_request == "Test.provision.node-1"
              response = VCAP::Services::Internal::ProvisionResponse.new
              response.success = true
              response.credentials = {
                  "node_id" => "node-1",
                  "name" => "b66e62e8-c87a-4adf-b08b-3cd30fcdbebb"
              }
            else
              response = VCAP::Services::Internal::BindResponse.new
              response.success = true
              response.credentials = {
                  "node_id" => "node-1",
                  "name" => "b66e62e8-c87a-4adf-b08b-3cd30fcdbebb"
              }
            end
            cb.call(response.encode)
            "5"
        }
        mock_nats.should_receive(:unsubscribe).once.with(any_args())

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback service_id

        gateway.send_bind_request
        gateway.got_bind_response.should be_true

        EM.stop
      end
    end

    it "should not allow over provisioning when it is not configured so" do
      provisioner = nil
      gateway = nil
      mock_nats = nil
      EM.run do
        mock_nats = mock("test_mock_nats")
        opt = {
          :plan_management => {:plans => {:free => {:allow_over_provisioning => false}}},
        }.merge!(options)
        provisioner = ProvisionerTests.create_provisioner(opt)
        # assign mock nats to provisioner
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        # mock node to send provision request
        mock_nodes = {
            "node-1" => {
                "id" => "node-1",
                "plan" => "free",
                "available_capacity" => -1,
                "capacity_unit" => 1,
                "supported_versions" => ["1.0"],
                "time" => Time.now.to_i
            }
        }
        provisioner.nodes = mock_nodes

        gateway.send_provision_request

        gateway.got_provision_response.should be_false

        EM.stop
      end
    end

  end
end
