# -*- coding: utf-8 -*-
# Copyright (c) 2009-2013 VMware, Inc.
require 'base/provisioner_v2'

module VCAP::Services::Base::ProvisionerV3
  include VCAP::Services::Base::ProvisionerV2
  include VCAP::Services::Internal
  include Before

  def update_instance_handles(instance_handles)
    instance_handles.each do |instance_id, instance_handle|
      unless verify_instance_handle_format(instance_handle)
        @logger.warn("Skip not well-formed instance handle:#{instance_handle}.")
        next
      end

      old_handle = instance_handle[instance_id]
      handle = instance_handle.deep_dup
      new_handle = {
        :credentials   => handle['credentials'],
        # NOTE on gateway we have have 'configuration' field in instance handle in replacement
        # of the 'gateway_data' field as in ccdb handle, this is for a easy management/translation
        # between gateway v1 and v2 provisioner code
        :configuration => handle['gateway_data'],
        :gateway_name  => handle['credentials']['name'],
      }
      @service_instances[instance_id] = new_handle
      after_update_instance_handle(old_handle, new_handle)
      new_handle
    end
  end

  # default hook for update instance handle
  def after_update_instance_handle(old_handle, new_handle)
    true
  end

  def add_instance_handle(entity)
    @service_instances[entity[:service_id]] = {
      :credentials   => entity[:credentials],
      :configuration => entity[:configuration],
      :gateway_name  => entity[:service_id],
    }
    after_add_instance_handle(entity)
  end

  # default hook
  def after_add_instance_handle(entity)
    true
  end

  def delete_instance_handle(instance_handle)
    @service_instances.delete(instance_handle[:credentials]["name"])
    after_delete_instance_handle(instance_handle)
  end

  #default hook
  def after_delete_instance_handle(instance_handle)
    true
  end


  def init_service_extensions
    @extensions = {}
    @plan_mgmt.each do |plan, value|
      lifecycle = value[:lifecycle]
      next unless lifecycle
      @extensions[plan] ||= {}
      @extensions[plan][:snapshot] = lifecycle.has_key? :snapshot
      %w(backup serialization job).each do |ext|
        ext = ext.to_sym
        @extensions[plan][ext] = true if lifecycle[ext] == "enable"
      end
    end
  end

  def on_connect_node
    @logger.debug("[#{service_description}] Connected to node mbus..")
    %w[announce node_handles update_service_handle instances_info].each do |op|
      eval %[@node_nats.subscribe("#{service_name}.#{op}") { |msg, reply| on_#{op}(msg, reply) }]
    end

    # service health manager channels
    @node_nats.subscribe("#{service_name}.health.ok") {|msg, reply| on_health_ok(msg, reply)}

    pre_send_announcement()
    @node_nats.publish("#{service_name}.discover")
  end

  def unprovision_service(instance_id, &blk)
    @logger.debug("[#{service_description}] Unprovision service #{instance_id}")
    begin
      svc = get_instance_handle(instance_id)
      @logger.debug("[#{service_description}] Unprovision service #{instance_id} found instance: #{svc}")
      raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?

      # TODO unified string and symbol usage in loacl cache.
      peers = svc[:configuration]["peers"]
      raise "Cannot find peers information for #{instance_id}: #{svc}" unless peers

      bindings = find_instance_bindings(instance_id)
      subscriptions = []
      timer = EM.add_timer(@node_timeout) {
        subscriptions.each do |s|
          @node_nats.unsubscribe(s)
        end
        blk.call(timeout_fail)
      }

      responsed_peers = 0
      peers.each do |role, config|
        creds = config["credentials"]
        node_id = creds["node_id"]
        @logger.debug("Unprovisioning peer of #{instance_id} from #{node_id}")
        request = UnprovisionRequest.new
        request.name = instance_id
        request.bindings = bindings.map{|h| h[:credentials]}
        @logger.debug("Sending unprovision request #{request.inspect}")
        subscriptions << @node_nats.request(
            "#{service_name}.unprovision.#{node_id}", request.encode
        ) do |msg|
          @logger.debug("unprovision responsed received #{msg}")
          responsed_peers += 1
          if responsed_peers == peers.size
            delete_instance_handle(svc)
            bindings.each do |binding|
              delete_binding_handle(binding)
            end

            EM.cancel_timer(timer)
            after_unprovision(svc, bindings)
            opts = SimpleResponse.decode(msg)
            if opts.success
              blk.call(success())
            else
              blk.call(wrap_error(opts))
            end
          end
        end
      end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at unprovision_service #{e}")
        @logger.warn(e)
        blk.call(internal_fail)
      end
    end
  end

  # default after hook
  def after_unprovision(svc, bindings)
    true
  end

  def plan_peers_number(plan)
    plan = plan.to_sym
    peer_number = 1
    peers_config = @plan_mgmt[plan][:peers] rescue nil
    peers_config.each do |role, config|
      peer_number += config[:count]
    end if peers_config

    return peer_number
  end

  def on_health_ok(msg, reply)
    @logger.debug("Receive instance health ok from hm: #{msg}")
    request = InstanceHealthOK.decode(msg)
    instance_id = request.instance_id.to_sym

    if @instance_provision_callbacks[instance_id]
      @logger.debug("fire success callback for #{instance_id}")
      callbacks = @instance_provision_callbacks[instance_id]
      timer = callbacks[:timer]
      EM.cancel_timer(timer)
      callbacks[:success].call
      @instance_provision_callbacks.delete(instance_id)
    end
  rescue => e
    @logger.warn("Exception at on_health_ok #{e}")
    @logger.warn(e)
  end

  def provision_service(request, prov_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to provision instance (request=#{request.extract})")
    plan = request.plan || "free"
    version = request.version

    plan_nodes = @nodes.select{ |_, node| node["plan"] == plan}.values

    @logger.debug("[#{service_description}] Picking version nodes from the following #{plan_nodes.count} \'#{plan}\' plan nodes: #{plan_nodes}")
    if plan_nodes.count > 0
      plan_config = @plan_mgmt[plan.to_sym]
      allow_over_provisioning = plan_config && plan_config[:allow_over_provisioning] || false

      version_nodes = plan_nodes.select{ |node|
        node["supported_versions"] != nil && node["supported_versions"].include?(version)
      }
      @logger.debug("[#{service_description}] #{version_nodes.count} nodes allow provisioning for version: #{version}")

      if version_nodes.count > 0

        required_peers = plan_peers_number(plan)
        # TODO handles required_peers > version_nodes.size
        best_nodes = version_nodes.sort_by { |node| node_score(node) }[-required_peers..-1]

        if best_nodes.size > 0 && ( allow_over_provisioning ||
                                   !best_nodes.find {|n| node_score(n) <= 0} )
          @logger.debug("[#{service_description}] Provisioning on #{best_nodes}")
          service_id = generate_service_id
          # Subclass should response to generate recipes
          recipes = generate_recipes(service_id, { plan.to_sym => plan_config },version, best_nodes)
          @logger.info("Provision recipes for #{service_id}: #{recipes}")
          instance_credentials = recipes["credentials"]
          configuration = recipes["configuration"]
          peers = configuration["peers"]
          peers.each do |node, config|
            creds = config["credentials"]
            node_id = creds["node_id"]
            prov_req = ProvisionRequest.new
            prov_req.plan = plan
            prov_req.version = version
            prov_req.credentials = creds

            @provision_refs[node_id] += 1
            @nodes[node_id]['available_capacity'] -= @nodes[node_id]['capacity_unit']
            subject = "#{service_name}.provision.#{node_id}"
            payload = prov_req.encode
            @logger.debug("Send provision request to #{node_id}, payload #{payload}.")
            @node_nats.request(subject, payload) do |msg|
              @logger.debug("Successfully provision response:[#{msg}]")
            end
          end

          provision_failure_callback = Proc.new do
            peers.each do |node, _|
              node_id = node["id"]
              @provision_refs[node_id] -= 1
            end
            blk.call(timeout_fail)
          end

          # Recover gateway status if even health manager failed.
          timer = EM.add_timer(@node_timeout) {
            @logger.warn("Provision #{service_id} timeout after after #{@node_timeout} seconds")
            peers.each do |node, _|
              node_id = node["id"]
              @provision_refs[node_id] -= 1
            end
            @instance_provision_callbacks.delete service_id.to_sym
            blk.call(timeout_fail)
          }

          provision_success_callback = Proc.new do |*args|
            @logger.info("Successfully provision response from HM for #{service_id}")
            EM.cancel_timer(timer)
            svc = { configuration:  configuration,
                    service_id:     service_id,
                    credentials:    instance_credentials
            }
            @logger.debug("Provisioned: #{svc.inspect}")
            add_instance_handle(svc)
            blk.call(success(svc))
          end

          #register callbacks
          @instance_provision_callbacks[service_id.to_sym] = {
            success:  provision_success_callback,
            failed:   provision_failure_callback,
            timeout_timer: timer
          }
          service_id
        else
          # No resources
          @logger.warn("[#{service_description}] Could not find #{required_peers} nodes to provision")
          blk.call(internal_fail)
        end
      else
        @logger.error("No available nodes supporting version #{version}")
        blk.call(failure(ServiceError.new(ServiceError::UNSUPPORTED_VERSION, version)))
      end
    else
      @logger.error("Unknown plan(#{plan})")
      blk.call(failure(ServiceError.new(ServiceError::UNKNOWN_PLAN, plan)))
    end
  rescue => e
    @logger.warn("Exception at provision_service #{e}")
    @logger.warn(e)
    blk.call(internal_fail)
  end

  def before_backup_apis service_id, *args, &blk
    raise "service_id can't be nil" unless service_id

    svc = get_instance_handle(service_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    plan = find_service_plan(svc)
    extensions_enabled?(plan, :backup, &blk)
  rescue => e
    handle_error(e, &blk)
    nil # terminate evoke chain
  end

  def find_service_plan(svc)
    config = svc[:configuration] || svc["configuration"]
    raise "Can't find configuration for service=#{service_id} #{svc.inspect}" unless config
    plan = config["plan"] || config[:plan]
    raise "Can't find plan for service=#{service_id} #{svc.inspect}" unless plan
    plan
  end

  def extensions_enabled?(plan, extension, &blk)
    unless (@extensions[plan.to_sym] && @extensions[plan.to_sym][extension.to_sym])
      @logger.warn("Extension #{extension} is not enabled for plan #{plan}")
      blk.call(failure(ServiceError.new(ServiceError::EXTENSION_NOT_IMPL, extension)))
      nil
    else
      true
    end
  end

  def backup_metadata(service_id)
    service = self.options[:service]
    instance = get_instance_handle(service_id)
    service_version = instance[:configuration]["version"] || instance[:configuration][:version]

    metadata = {
      :plan => find_service_plan(instance),
      :provider => service[:provider] || 'core',
      :service_version => service_version
    }
    metadata
  rescue => e
    @logger.warn("Failed to get snapshot_metadata #{e}.")
  end

  def create_backup(service_id, opts = {}, &blk)
    @logger.debug("Create backup job for service_id=#{service_id}")
    job_id = create_backup_job.create(:service_id => service_id,
                                      :node_id    => find_backup_peer(service_id),
                                      :metadata   => backup_metadata(service_id).merge(opts)
                                     )
    job = get_job(job_id)
    @logger.info("CreateBackupJob created: #{job.inspect}")
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  def user_triggered_options(params)
    {}
  end

  def periodically_triggered_options(params)
    {}
  end

  def find_backup_peer(service_id)
    svc = get_instance_handle(service_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, "service id #{service_id}") if svc.nil?
    node_id = svc[:configuration]["backup_peer"]
    raise "Cannot find backup peer's node_id for #{service_id}" if node_id.nil?
    node_id
  end

  def generate_service_id
    SecureRandom.uuid
  end

  before [:create_backup], :before_backup_apis
end
