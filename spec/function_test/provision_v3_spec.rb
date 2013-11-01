# Copyright (c) 2009-2013 VMware, Inc.
require 'helper/spec_helper'
require 'helper/nats_server_helper'
require 'eventmachine'

describe ProvisionerTests do
  let(:version) { 'v3' }
  let(:options) { {:provisioner_version => version} }

  describe "Provision" do
    it "should support provision" do
      provisioner = nil
      gateway = nil
      node = nil
      service_id = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { EM.stop }
      end
      gateway.got_provision_response.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should avoid over provision when provisioning" do
      provisioner = nil
      gateway = nil
      node1 = nil
      node2 = nil
      service_id1 = nil
      service_id2 = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node1 = ProvisionerTests.create_node(1, 1) }
        Do.at(3) { node2 = ProvisionerTests.create_node(2, 1) }
        Do.at(4) do
          service_id1 = gateway.send_provision_request
          service_id2 = gateway.send_provision_request
        end
        Do.at(5) do
          gateway.fire_provision_callback service_id1
          gateway.fire_provision_callback service_id2
        end
        Do.at(10) { gateway.send_provision_request }
        Do.at(15) { EM.stop }
      end
      node1.got_provision_request.should be_true
      node2.got_provision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 2
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should support unprovision" do
      provisioner = nil
      gateway = nil
      node = nil
      service_id = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { gateway.send_unprovision_request }
        Do.at(6) { EM.stop }
      end
      node.got_unprovision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should delete instance handles in cache after unprovision" do
      provisioner = gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          provisioner = ProvisionerTests.create_provisioner(options)
          provisioner.get_all_handles.size.should == 0
        end
        service_id = nil
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { gateway.send_bind_request }
        Do.at(6) { gateway.send_unprovision_request }
        Do.at(7) { EM.stop }
      end
      node.got_provision_request.should be_true
      node.got_bind_request.should be_true
      node.got_unprovision_request.should be_true
      provisioner.get_all_handles.size.should == 0
    end

    it "should handle error in unprovision" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_error_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_error_node(1) }
        Do.at(3) do
          ProvisionerTests.setup_fake_instance_by_id(
            gateway, provisioner, node.node_id)
        end
        Do.at(4) { gateway.send_unprovision_request }
        Do.at(5) { EM.stop }
      end
      node.got_unprovision_request.should be_true
      gateway.unprovision_response.should be_false
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
      gateway.error_msg.should_not == nil
      gateway.error_msg['status'].should == 500
      gateway.error_msg['msg']['code'].should == 30500
    end

    it "should support bind" do
      provisioner = nil
      gateway = nil
      node = nil
      service_id = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { gateway.send_bind_request }
        Do.at(6) { EM.stop }
      end
      gateway.got_provision_response.should be_true
      gateway.got_bind_response.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 1
    end

    it "should support get instance id list" do
      provisioner = nil
      gateway = nil
      node = nil
      service_id = nil
      EM.run do
        Do.at(0) { provisioner = ProvisionerTests.create_provisioner(options) }
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { gateway.send_instances_request("node-1") }
        Do.at(6) { EM.stop }
      end
      gateway.got_instances_response.should be_true
    end

    it "should allow over provisioning when it is configured so" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          opts = {
            :plan_management => {:plans => {:free => {:allow_over_provisioning => true }}},
          }.merge(options)
          provisioner = ProvisionerTests.create_provisioner(opts)
        end
        service_id = nil
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, -1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(4) { gateway.fire_provision_callback service_id }
        Do.at(5) { EM.stop }
      end
      node.got_provision_request.should be_true
      provisioner.get_all_instance_handles.size.should == 1
      provisioner.get_all_binding_handles.size.should == 0
    end

    it "should not allow over provisioning when it is not configured so" do
      provisioner = nil
      gateway = nil
      node = nil
      EM.run do
        Do.at(0) do
          opts = {
            :plan_management => {:plans => {:free => {:allow_over_provisioning => false }}},
          }.merge(options)
          provisioner = ProvisionerTests.create_provisioner(opts)
        end
        service_id = nil
        Do.at(1) { gateway = ProvisionerTests.create_gateway(provisioner) }
        Do.at(2) { node = ProvisionerTests.create_node(1, -1) }
        Do.at(3) { service_id = gateway.send_provision_request }
        Do.at(5) { EM.stop }
      end
      node.got_provision_request.should be_false
      provisioner.get_all_instance_handles.size.should == 0
      provisioner.get_all_binding_handles.size.should == 0
    end
  end
end
