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

    it "should be able to handle error in create_backup and delete_backup" do
      mock_nats = double("test_mock_nats")
      EM.run do
        provisioner = ProvisionerTests.create_provisioner(options)
        provisioner.nats = mock_nats
        provisioner.should_receive(:before_backup_apis).twice.and_return(true)

        [:create_backup, :delete_backup].each do |method|
          provisioner.should_receive(:"#{method}_job").and_raise("error")
          error = nil
          provisioner.send(method, "service_id", "backup_id", {}) { |e| error = e }
          error['response']['status'].should eq ServiceError::HTTP_INTERNAL
        end
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
              "name"       => service_id,
              "service_id" => service_id
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

    it "should support update credentials" do
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
          request = args[0]
          if request == "Test.provision.node-1"
            response = VCAP::Services::Internal::ProvisionResponse.new
            response.success = true
            response.credentials = {
                "node_id" => "node-1",
                "name" => "b66e62e8-c87a-4adf-b08b-3cd30fcdbebb"
            }
          elsif request == "Test.update_credentials.node-1"
            response = VCAP::Services::Internal::SimpleResponse.new
            response.success = true
          end
          cb.call(response.encode)
          "5"
        }
        mock_nats.should_receive(:unsubscribe).once.with(any_args())

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback service_id

        update_credentials_succeed = false
        provisioner.update_credentials(service_id, { 'credentials' => { "password" => "new_password" } } ) do |msg|
          update_credentials_succeed = msg['success']
        end

        update_credentials_succeed.should be_true

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

    it "should support provision service with multiple peers" do
      provisioner = nil
      gateway = nil
      mock_nats = nil
      mock_nodes = nil
      EM.run do
        mock_nats = double("test_mock_nats")
        opt = {
          :peers_number => 3
        }.merge!(options)
        provisioner = ProvisionerTests.create_multipeers_provisioner(opt)
        provisioner.nats = mock_nats
        gateway = ProvisionerTests.create_gateway(provisioner)
        mock_nodes = {}
        opt[:peers_number].times do |i|
          mock_nodes["node_#{i}"] = {
            "id" => "node_#{i}",
            "plan" => "free",
            "available_capacity" => 200,
            "capacity_unit" => 1,
            "supported_versions" => ["1.0"],
            "time" => Time.now.to_i
          }
        end
        provisioner.nodes = mock_nodes

        opt[:peers_number].times do |i|
          mock_nats.should_receive(:request).with("Test.provision.node_#{i}", an_instance_of(String))
        end

        service_id = gateway.send_provision_request
        gateway.fire_provision_callback service_id

        gateway.got_provision_response.should be_true

        provisioner.provision_refs.keys.size.should eq(opt[:peers_number])
        provisioner.provision_refs.each {|k,v| v.should eq(0)}

        EM.stop
      end
    end

    context "update instance status" do

      let(:get_success_response) { double('get_response',
                                          error: nil,
                                          response_header: double('header',
                                                                  status: 200,
                                                                  etag: 'head'),
                                          response: {
                                              'resources' => [ {
                                                                   'entity' => { id: 'abc'}
                                                               }]
                                          }.to_json)
                                }

      let(:put_success_response) { double('put_response',
                                          error: nil,
                                          response_header: double('header', status: 200),
                                          response: 'ok') }

      let(:put_fail_response) { double('put_response',
                                       error: nil,
                                       response_header: double('header', status: 412),
                                       response: 'ok') }

      it "should get status first before updating" do

        get_called = false
        update_called = false
        HTTPHandler.any_instance.should_receive(:cc_http_request).twice.with(any_args()).\
        and_return { |args, &cb|
          if args[:method] == 'get'
            get_called = true
            cb.call(get_success_response)
          elsif args[:method] == 'put'
            get_called.should be_true
            update_called = true
            cb.call(put_success_response)
          end
        }

        EM.run do
          succeed = false

          provisioner = ProvisionerTests.create_provisioner(options)
          provisioner.update_instance_status('http://ip/instance/1', 'READY').should be_true
          update_called.should be_true
          EM.stop
        end

      end

      it "should retry in case of IF-Match-Fail(412) error" do

        update_called = false
        first_time_put = true
        HTTPHandler.any_instance.should_receive(:cc_http_request).exactly(4).with(any_args()).\
        and_return { |args, &cb|
          if args[:method] == 'get'
            cb.call(get_success_response)
          elsif args[:method] == 'put'
            update_called = true
            if (first_time_put)
              first_time_put = false
              cb.call(put_fail_response)
            else
              cb.call(put_success_response)
            end
          end
        }

        EM.run do
          succeed = false

          provisioner = ProvisionerTests.create_provisioner(options)
          provisioner.update_instance_status('http://ip/instance/1', 'READY').should be_true
          update_called.should be_true
          EM.stop
        end

      end

    end

    context "support provision with restored data" do

      let(:mock_nats) { double("test_mock_nats") }
      let(:klass) { double("subclass") }
      let(:mock_instance_handle) {
        {
          :credentials => {
            "name"     => "fake_instance",
            "user"     => "fake_user",
            "password" => "fake_pass",
          }
        }
      }

      def check(provisioner, node_count)
        klass.should_receive(:create).exactly(node_count).times.and_return(an_instance_of(Integer))
        provisioner.should_receive(:restore_backup_job).exactly(node_count).times.and_return(klass)
        provisioner.should_receive(:get_job).exactly(node_count).times.and_return({})

        provisioner.should_receive(:get_instance_handle).and_return(mock_instance_handle)

        provisioner.should_receive(:update_instance_status).and_return(true)

        provisioner.nats = mock_nats
        mock_nodes = {}
        node_count.times do |i|
          mock_nodes["node_#{i}"] = {
            "id" => "node_#{i}",
            "plan" => "free",
            "available_capacity" => 200,
            "capacity_unit" => 1,
            "supported_versions" => ["1.0"],
            "time" => Time.now.to_i
          }
        end
        provisioner.nodes = mock_nodes

        mock_nodes.keys.each do |name|
          mock_nats.should_receive(:request).with("Test.provision.#{name}", an_instance_of(String))
        end

        mock_nats.should_receive(:publish).exactly(node_count).times
        mock_nats.should_receive(:subscribe).with(/Test\.restore_backup/).and_return do |channel, &blk|
          response = VCAP::Services::Internal::SimpleResponse.new
          response.success = true

          node_count.times { blk.call(response.encode, nil) }
        end

        # TODO finish the TODO in source file and set expectations here

        properties = {
          VCAP::Services::Internal::ProvisionArguments::BACKUP_ID => "fake_backup_id",
          VCAP::Services::Internal::ProvisionArguments::ORIGINAL_SERVICE_ID => "fake_instance_id",
          VCAP::Services::Internal::ProvisionArguments::UPDATE_URL => "http://",
        }

        gateway = ProvisionerTests.create_gateway(provisioner)
        service_id = gateway.send_provision_request(properties)
        gateway.fire_provision_callback service_id

        gateway.got_provision_response.should be_true
        provisioner.provision_refs.keys.size.should eq(node_count)
        provisioner.provision_refs.each {|k,v| v.should eq(0)}
      end

      it "for single node" do
        EM.run do
          provisioner = ProvisionerTests.create_provisioner(options)
          check(provisioner, 1)
          EM.stop
        end
      end

      it "for multiple peers" do
        EM.run do
          opt = {
            :peers_number => 3
          }.merge!(options)
          provisioner = ProvisionerTests.create_multipeers_provisioner(opt)
          check(provisioner, 3)
          EM.stop
        end
      end

    end
  end
end
