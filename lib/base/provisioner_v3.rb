# -*- coding: utf-8 -*-
# Copyright (c) 2009-2013 VMware, Inc.
require 'base/provisioner_v2'
require 'vcap_services_messages/constants'

module VCAP::Services::Base::ProvisionerV3
  include VCAP::Services::Base::ProvisionerV2
  include VCAP::Services::Internal
  include VCAP::Services::Base::Error
  include Before

  PA = VCAP::Services::Internal::ProvisionArguments

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
        :configuration => handle['gateway_data'] || handle['configuration'],
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
      %w(backup job).each do |ext|
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
      peers.each do |peer|
        creds = peer["credentials"]
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

    is_restoring = false
    if request.respond_to? :properties
      backup_id = request.properties[PA::BACKUP_ID]
      original_service_id = request.properties[PA::ORIGINAL_SERVICE_ID]
      is_restoring = true if backup_id && original_service_id
      @logger.debug("Restoring previous instance #{original_service_id} from backup #{backup_id}") if is_restoring
    end

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

          original_instance_handle = {}
          original_creds = {}
          if is_restoring
            original_instance_handle = get_instance_handle(original_service_id)
            raise "original instance #{original_service_id} not found" unless original_instance_handle
            original_creds = original_instance_handle[:credentials]
            raise "credentials for original instance #{original_service_id} not found" unless original_creds
          end

          # Subclass should define generate_recipes and return an instance of
          # VCAP::Services::Internal::ServiceRecipes.
          # recipes.credentials is the connection string presents to end user. Base code treat
          # credentials as a opaque string.
          # recipes.configuration contains any data that need persistent when gateway restart
          # such as version, plan and peers topology for a given service instance.
          recipes = generate_recipes(service_id, { plan.to_sym => plan_config }, version, best_nodes, original_creds)
          unless recipes.is_a? ServiceRecipes
            raise "Invalid response class: #{recipes.class}, requires #{ServiceRecipes.class}"
          end
          @logger.info("Provision recipes for #{service_id}: #{recipes.inspect}")
          instance_credentials = recipes.credentials
          configuration = recipes.configuration
          peers = configuration["peers"]
          provision_response_status = is_restoring ?
            VCAP::Services::Internal::ServiceInstanceStatus::RESTORING :
            VCAP::Services::Internal::ServiceInstanceStatus::READY
          svc = { configuration:  configuration,
                  service_id:     service_id,
                  credentials:    instance_credentials,
                  status:         provision_response_status
          }

          prov_properties = {}
          each_peer(peers) do |node_id, _|
            @provision_refs[node_id] += 1
            @nodes[node_id]['available_capacity'] -= @nodes[node_id]['capacity_unit']
          end

          provision_blk = Proc.new do |callback|
            peers.each do |peer|
              creds = peer["credentials"]
              node_id = creds["node_id"]
              prov_req = ProvisionRequest.new
              prov_req.plan = plan
              prov_req.version = version
              prov_req.credentials = creds
              prov_req.properties = prov_properties

              subject = "#{service_name}.provision.#{node_id}"
              payload = prov_req.encode
              @logger.debug("Send provision request to #{node_id}, payload #{payload}.")
              @node_nats.request(subject, payload) do |msg|
                @logger.debug("Successfully provision response:[#{msg}]")
              end
            end

            provision_failure_callback = Proc.new do
              begin
                callback.call(timeout_fail)
              ensure
                each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
              end
            end

            # Recover gateway status if even health manager failed.
            timer = EM.add_timer(@node_timeout) do
              begin
                @logger.warn("Provision #{service_id} timeout after after #{@node_timeout} seconds")
                @instance_provision_callbacks.delete service_id.to_sym
                callback.call(timeout_fail)
              ensure
                each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
              end
            end

            provision_success_callback = Proc.new do |*args|
              begin
                @logger.info("Successfully provision response from HM for #{service_id}")
                EM.cancel_timer(timer)
                @logger.debug("Provisioned: #{svc.inspect}")
                add_instance_handle(svc)
                callback.call(success(svc))
              ensure
                each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
              end
            end

            #register callbacks
            @instance_provision_callbacks[service_id.to_sym] = {
              success:  provision_success_callback,
              failed:   provision_failure_callback,
              timeout_timer: timer
            }
          end

          if is_restoring
            prov_properties = {:is_restoring => true}
            restore_opts = user_triggered_options({:plan => plan, :service_version => version})
            job_triggered = true
            count = peers.size

            subscription = nil
            timer = EM.add_timer(@restore_timeout) do
              @logger.warn("Restoring job for #{service_id} timeout after #{@restore_timeout} seconds")
              @node_nats.unsubscribe(subscription) if subscription
            end
            subscription = @node_nats.subscribe("#{service_name}.restore_backup.#{service_id}") do |msg, reply|
              sr = SimpleResponse.decode(msg)
              res_to_woker = SimpleResponse.new
              begin
                if sr.success
                  count -= 1
                  if count == 0
                    # TODO update instance status to "Ready"
                    update_status_blk = Proc.new do |res|
                      if res["success"]
                        @logger.info("Successfully provision after restore for #{service_id}")
                        # update Instance status to ready
                      else
                        @logger.warn("Provision after restore failed for #{service_id}")
                        # update Instance status to failed
                      end
                    end
                    provision_blk.call(update_status_blk)
                    @node_nats.unsubscribe(subscription) if subscription
                    EM.cancel_timer(timer)
                  end
                else
                  @logger.warn("Restoring job for #{service_id} failed")
                  @node_nats.unsubscribe(subscription) if subscription
                  EM.cancel_timer(timer)
                  each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
                end
                res_to_woker.success = true
              rescue => e
                @logger.warn("Exception at provision after restore job: #{e}")
                @node_nats.unsubscribe(subscription) if subscription
                EM.cancel_timer(timer)
                each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
                res_to_woker.success = false
              ensure
                @node_nats.publish(reply, res_to_woker.encode)
              end
            end

            peers.each do |peer|
              node_id = peer["credentials"]["node_id"]
              result = restore_backup(service_id, backup_id, node_id, original_service_id, restore_opts)
              job_triggered = false unless result
            end

            if job_triggered
              @logger.info("Provision for restoring: #{svc.inspect}")
              blk.call(success(svc))
            else
              @logger.warn("Provision for restoring failed because of error in restore job: #{svc.inspect}")
              @node_nats.unsubscribe(subscription) if subscription
              EM.cancel_timer(timer)
              each_peer(peers) {|node_id, _| @provision_refs[node_id] -= 1 }
              blk.call(internal_fail)
            end
          else
            prov_properties = {:is_restoring => false}
            provision_blk.call(blk)
          end

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

  def create_backup(service_id, backup_id, opts = {}, &blk)
    @logger.debug("Create backup job for service_id=#{service_id}")
    job_id = create_backup_job.create(:service_id => service_id,
                                      :backup_id  => backup_id,
                                      :node_id    => find_backup_peer(service_id),
                                      :metadata   => backup_metadata(service_id).merge(opts)
                                     )
    job = get_job(job_id)
    @logger.info("CreateBackupJob created: #{job.inspect}")
    blk.call(success(job))
  rescue => e
    @logger.error("CreateBackupJob failed: #{e}")
    blk.call(failure(e))
  end

  def restore_backup(service_id, backup_id, node_id, ori_service_id, opts)
    @logger.debug("Restore backup job for service_id=#{service_id}")
    job_id = restore_backup_job.create(:service_id          => service_id,
                                       :backup_id           => backup_id,
                                       :original_service_id => ori_service_id,
                                       :node_id             => node_id,
                                       :metadata            => opts
                                      )
    job = get_job(job_id)
    @logger.info("RestoreBackupJob created: #{job.inspect}")
    job.nil? ? false : true
  rescue
    @logger.error("RestoreBackupJob failed: #{e}")
    false
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

  def each_peer(peers)
    peers.each do |peer|
      creds = peer["credentials"]
      node_id = creds["node_id"]
      yield node_id, creds
    end
  end

  before [:create_backup], :before_backup_apis
end
