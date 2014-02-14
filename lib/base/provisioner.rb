# -*- coding: utf-8 -*-
# Copyright (c) 2009-2011 VMware, Inc.

require "set"
require "data_mapper"

$LOAD_PATH.unshift File.dirname(__FILE__)
require 'base/base'
require 'base/simple_aop'
require 'base/job/async_job'
require 'base/http_handler'
require 'base/auth_token_generator'
require 'barrier'
require 'vcap_services_messages/service_message'
require 'securerandom'

class VCAP::Services::Base::Provisioner < VCAP::Services::Base::Base
  include VCAP::Services::Internal
  include VCAP::Services::Base::AsyncJob
  include Before
  include AuthTokenGenerator

  BARRIER_TIMEOUT = 2
  MASKED_PASSWORD = '********'

  attr_reader :options, :node_nats

  def initialize(options)
    super(options)
    @options = options
    @node_timeout = options[:node_timeout]
    @restore_timeout = options[:restore_timeout] || 3600
    @nodes = {}
    @provision_refs = Hash.new(0)
    @instance_handles_CO = {}
    @binding_handles_CO = {}
    @responses_metrics = {
      :responses_xxx => 0,
      :responses_2xx => 0,
      :responses_3xx => 0,
      :responses_4xx => 0,
      :responses_5xx => 0,
    }
    @plan_mgmt = options[:plan_management] && options[:plan_management][:plans] || {}
    @instance_provision_callbacks = {}

    provisioner_version = options[:provisioner_version] || 'v2'
    if provisioner_version == "v1"
      require 'provisioner_v1'
      self.class.send(:include, VCAP::Services::Base::ProvisionerV1)
      @prov_svcs = {}
    elsif provisioner_version == "v2"
      require 'provisioner_v2'
      self.class.send(:include, VCAP::Services::Base::ProvisionerV2)
      @service_instances = {}
      @service_bindings = {}
    elsif provisioner_version == "v3"
      @cc_http_handler = HTTPHandler.new(options, sc_token_generator(options))
      require 'provisioner_v3'
      self.class.send(:include, VCAP::Services::Base::ProvisionerV3)
      @service_instances = {}
      @service_bindings = {}
    else
      raise "unknown provisioner version: #{provisioner_version}"
    end

    init_service_extensions

    @staging_orphan_instances = {}
    @staging_orphan_bindings = {}
    @final_orphan_instances = {}
    @final_orphan_bindings = {}

    z_interval = options[:z_interval] || 30

    EM.add_periodic_timer(z_interval) do
      update_varz
    end if @node_nats

    # Defer 5 seconds to give service a change to wake up
    EM.add_timer(5) do
      update_varz
    end if @node_nats

    EM.add_periodic_timer(60) { process_nodes }
  end

  def flavor
    'Provisioner'
  end

  def create_redis(opt)
    redis_client = ::Redis.new(opt)
    raise "Can't connect to redis:#{opt.inspect}" unless redis_client
    redis_client
  end

  def init_service_extensions
    @extensions = {}
    @plan_mgmt.each do |plan, value|
      lifecycle = value[:lifecycle]
      next unless lifecycle
      @extensions[plan] ||= {}
      %w(job).each do |ext|
        ext = ext.to_sym
        @extensions[plan][ext] = true if lifecycle[ext] == "enable"
      end
    end
  end

  def update_responses_metrics(status)
    return unless status.is_a? Fixnum

    metric = :responses_xxx
    if status >=200 and status <300
      metric = :responses_2xx
    elsif status >=300 and status <400
      metric = :responses_3xx
    elsif status >=400 and status <500
      metric = :responses_4xx
    elsif status >=500 and status <600
      metric = :responses_5xx
    end
    @responses_metrics[metric] += 1
  rescue => e
    @logger.warn("Failed update responses metrics: #{e}")
  end

  def verify_handle_format(handle)
    return nil unless handle
    return nil unless handle.is_a? Hash

    VCAP::Services::Internal::ServiceHandle.new(handle)
    true
  rescue => e
    @logger.warn("Verify handle #{handle} failed:#{e}")
    return nil
  end

  def process_nodes
    @nodes.delete_if do |id, node|
      stale = (Time.now.to_i - node["time"]) > 300
      @provision_refs.delete(id) if stale
      stale
    end
  end

  def pre_send_announcement
    addition_opts = self.options[:additional_options]
    if addition_opts
      if addition_opts[:resque]
        # Initial AsyncJob module
        job_repo_setup()
      end
    end
  end

  # update version information of existing instances
  def update_version_info(current_version)
    @logger.debug("[#{service_description}] Update version of existing instances to '#{current_version}'")

    updated_prov_handles = []
    get_all_instance_handles do |handle|
      next if handle[:configuration].has_key? "version"

      updated_prov_handle = {}
      # update_handle_callback need string as key
      handle.each {|k, v| updated_prov_handle[k.to_s] = v.deep_dup}
      updated_prov_handle["configuration"]["version"] = current_version

      updated_prov_handles << updated_prov_handle
    end

    f = Fiber.new do
      failed, successful = 0, 0
      updated_prov_handles.each do |handle|
        @logger.debug("[#{service_description}] trying to update handle: #{handle}")
        # NOTE: serialized update_handle in case CC/router overload
        res = fiber_update_handle(handle)
        if res
          @logger.info("Successful update version of handle:#{handle}")
          successful += 1
        else
          @logger.error("Failed to update version of handle:#{handle}")
          failed += 1
        end
      end
      @logger.info("Result of update handle version: #{successful} successful, #{failed} failed.")
    end
    f.resume
  rescue => e
    @logger.error("Unexpected error when update version info: #{e}, #{e.backtrace.join('|')}")
  end

  def fiber_update_handle(updated_handle)
    f = Fiber.current

    @update_handle_callback.call(updated_handle) {|res| f.resume(res)}

    Fiber.yield
  end

  def config_update_event
    "#{service_name}.config_update.provisioner"
  end

  def on_connect_node
    @logger.debug("[#{service_description}] Connected to node mbus..")
    %w[announce node_handles update_service_handle instances_info].each do |op|
      eval %[@node_nats.subscribe("#{service_name}.#{op}") { |msg, reply| on_#{op}(msg, reply) }]
    end

    pre_send_announcement()
    @node_nats.publish("#{service_name}.discover")
  end

  def on_announce(msg, reply=nil)
    @logger.debug("[#{service_description}] Received node announcement: #{msg.inspect}")
    announce_message = Yajl::Parser.parse(msg)
    if announce_message["id"]
      id = announce_message["id"]
      announce_message["time"] = Time.now.to_i
      if @provision_refs[id] > 0
        announce_message['available_capacity'] = @nodes[id]['available_capacity']
      end
      @nodes[id] = announce_message
    end
  end

  def on_node_handles(msg, reply)
    @logger.debug("[#{service_description}] Received node handles")
    response = NodeHandlesReport.decode(msg)
    nid = response.node_id
    @staging_orphan_instances[nid] ||= []
    @staging_orphan_bindings[nid] ||= []
    response.instances_list.each do |ins|
      @staging_orphan_instances[nid] << ins unless @instance_handles_CO.has_key?(ins)
    end
    response.bindings_list.each do |bind|
      user = bind["username"] || bind["user"]
      next unless user
      key = bind["service_id"] + user
      @staging_orphan_bindings[nid] << bind unless @binding_handles_CO.has_key?(key)
    end
    oi_count = @staging_orphan_instances.values.reduce(0) { |m, v| m += v.count }
    ob_count = @staging_orphan_bindings.values.reduce(0) { |m, v| m += v.count }
    @logger.debug("Staging Orphans: Instances: #{oi_count}; Bindings: #{ob_count}")
  rescue => e
    @logger.warn("Exception at on_node_handles #{e}")
  end

  def check_orphan(handles, &blk)
    @logger.debug("[#{service_description}] Check if there are orphans")
    @staging_orphan_instances = {}
    @staging_orphan_bindings = {}
    @instance_handles_CO, @binding_handles_CO = indexing_handles(handles.deep_dup)
    @node_nats.publish("#{service_name}.check_orphan","Send Me Handles")
    blk.call(success)
  rescue => e
    @logger.warn("Exception at check_orphan #{e}")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def double_check_orphan(handles)
    @logger.debug("[#{service_description}] Double check the orphan result")
    ins_handles, bin_handles = indexing_handles(handles)
    @final_orphan_instances.clear
    @final_orphan_bindings.clear

    @staging_orphan_instances.each do |nid, oi_list|
      @final_orphan_instances[nid] ||= []
      oi_list.each do |oi|
        @final_orphan_instances[nid] << oi unless ins_handles.has_key?(oi)
      end
    end
    @staging_orphan_bindings.each do |nid, ob_list|
      @final_orphan_bindings[nid] ||= []
      ob_list.each do |ob|
        user = ob["username"] || ob["user"]
        next unless user
        key = ob["service_id"] + user
        @final_orphan_bindings[nid] << ob unless bin_handles.has_key?(key)
      end
    end
    oi_count = @final_orphan_instances.values.reduce(0) { |m, v| m += v.count }
    ob_count = @final_orphan_bindings.values.reduce(0) { |m, v| m += v.count }
    @logger.debug("Final Orphans: Instances: #{oi_count}; Bindings: #{ob_count}")
  rescue => e
    @logger.warn("Exception at double_check_orphan #{e}")
  end

  def purge_orphan(orphan_ins_hash,orphan_bind_hash, &blk)
    @logger.debug("[#{service_description}] Purge orphans for given list")
    handles_size = @max_nats_payload - 200

    send_purge_orphan_request = Proc.new do |node_id, i_list, b_list|
      group_handles_in_json(i_list, b_list, handles_size) do |ins_list, bind_list|
        @logger.debug("[#{service_description}] Purge orphans for #{node_id} instances: #{ins_list.count} bindings: #{bind_list.count}")
        req = PurgeOrphanRequest.new
        req.orphan_ins_list = ins_list
        req.orphan_binding_list = bind_list
        @node_nats.publish("#{service_name}.purge_orphan.#{node_id}", req.encode)
      end
    end

    orphan_ins_hash.each do |nid, oi_list|
      ob_list = orphan_bind_hash.delete(nid) || []
      send_purge_orphan_request.call(nid, oi_list, ob_list)
    end

    orphan_bind_hash.each do |nid, ob_list|
      send_purge_orphan_request.call(nid, [], ob_list)
    end
    blk.call(success)
  rescue => e
    @logger.warn("Exception at purge_orphan #{e}")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  def unprovision_service(instance_id, &blk)

    @logger.debug("[#{service_description}] Unprovision service #{instance_id}")
    begin
      svc = get_instance_handle(instance_id)
      @logger.debug("[#{service_description}] Unprovision service #{instance_id} found instance: #{svc}")
      raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      bindings = find_instance_bindings(instance_id)
      @logger.debug("[#{service_description}] Unprovisioning instance #{instance_id} from #{node_id}")
      request = UnprovisionRequest.new
      request.name = instance_id
      request.bindings = bindings.map{|h| h[:credentials]}
      @logger.debug("[#{service_description}] Sending request #{request}")
      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request(
          "#{service_name}.unprovision.#{node_id}", request.encode
       ) do |msg|
          # Delete local entries
          delete_instance_handle(svc)
          bindings.each do |binding|
            delete_binding_handle(binding)
          end

          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = SimpleResponse.decode(msg)
          if opts.success
            blk.call(success())
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at unprovision_service #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def provision_service(request, prov_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to provision instance (request=#{request.extract})")
    subscription = nil
    plan = request.plan || "free"
    version = request.version

    plan_nodes = @nodes.select{ |_, node| node["plan"] == plan}.values

    @logger.debug("[#{service_description}] Picking version nodes from the following #{plan_nodes.count} \'#{plan}\' plan nodes: #{plan_nodes}")
    if plan_nodes.count > 0
      allow_over_provisioning = @plan_mgmt[plan.to_sym] && @plan_mgmt[plan.to_sym][:allow_over_provisioning] || false

      version_nodes = plan_nodes.select{ |node|
        node["supported_versions"] != nil && node["supported_versions"].include?(version)
      }
      @logger.debug("[#{service_description}] #{version_nodes.count} nodes allow provisioning for version: #{version}")

      if version_nodes.count > 0

        best_node = version_nodes.max_by { |node| node_score(node) }

        if best_node && ( allow_over_provisioning || node_score(best_node) > 0 )
          best_node = best_node["id"]
          @logger.debug("[#{service_description}] Provisioning on #{best_node}")

          prov_req = ProvisionRequest.new
          prov_req.plan = plan
          prov_req.version = version
          # use old credentials to provision a service if provided.
          prov_req.credentials = prov_handle["credentials"] if prov_handle

          @provision_refs[best_node] += 1
          @nodes[best_node]['available_capacity'] -= @nodes[best_node]['capacity_unit']
          subscription = nil

          timer = EM.add_timer(@node_timeout) {
            @provision_refs[best_node] -= 1
            @node_nats.unsubscribe(subscription)
            blk.call(timeout_fail)
          }

          subscription = @node_nats.request("#{service_name}.provision.#{best_node}", prov_req.encode) do |msg|
            @provision_refs[best_node] -= 1
            EM.cancel_timer(timer)
            @node_nats.unsubscribe(subscription)
            response = ProvisionResponse.decode(msg)

            if response.success
              @logger.debug("Successfully provision response:[#{response.inspect}]")

              # credentials is not necessary in cache
              prov_req.credentials = nil
              credential = response.credentials
              svc = {:configuration => prov_req.dup, :service_id => credential['name'], :credentials => credential}
              @logger.debug("Provisioned: #{svc.inspect}")
              add_instance_handle(svc)
              blk.call(success(svc))
            else
              blk.call(wrap_error(response))
            end
          end
        else
          # No resources
          @logger.warn("[#{service_description}] Could not find a node to provision")
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
    blk.call(internal_fail)
  end

  def bind_instance(instance_id, binding_options, bind_handle=nil, &blk)
    @logger.debug("[#{service_description}] Attempting to bind to service #{instance_id}")

    begin
      svc = get_instance_handle(instance_id)
      raise ServiceError.new(ServiceError::NOT_FOUND, instance_id) if svc.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      @logger.debug("[#{service_description}] bind instance #{instance_id} from #{node_id}")
      #FIXME options = {} currently, should parse it in future.
      request = BindRequest.new
      request.name = instance_id
      request.bind_opts = binding_options
      service_id = nil
      if bind_handle
        request.credentials = bind_handle["credentials"]
        service_id = bind_handle["service_id"]
      else
        service_id = SecureRandom.uuid
      end
      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request( "#{service_name}.bind.#{node_id}",
                           request.encode
       ) do |msg|
          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = BindResponse.decode(msg)
          if opts.success
            opts = opts.credentials
            # Save binding-options in :data section of configuration
            config = svc[:configuration].clone
            config['data'] ||= {}
            config['data']['binding_options'] = binding_options
            res = {
              :service_id => service_id,
              :configuration => config,
              :credentials => opts
            }
            @logger.debug("[#{service_description}] Binded: #{res.inspect}")
            add_binding_handle(res)
            blk.call(success(res))
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at bind_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def unbind_instance(instance_id, binding_id, binding_options, &blk)
    @logger.debug("[#{service_description}] Attempting to unbind to service #{instance_id}")
    begin
      svc = get_instance_handle(instance_id)
      raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?

      handle = get_binding_handle(binding_id)
      raise ServiceError.new(ServiceError::NOT_FOUND, "binding_id #{binding_id}") if handle.nil?

      node_id = svc[:credentials]["node_id"]
      raise "Cannot find node_id for #{instance_id}" if node_id.nil?

      @logger.debug("[#{service_description}] Unbind instance #{binding_id} from #{node_id}")
      request = UnbindRequest.new
      request.credentials = handle[:credentials]

      subscription = nil
      timer = EM.add_timer(@node_timeout) {
        @node_nats.unsubscribe(subscription)
        blk.call(timeout_fail)
      }
      subscription =
        @node_nats.request( "#{service_name}.unbind.#{node_id}",
                           request.encode
       ) do |msg|
          delete_binding_handle(handle)
          EM.cancel_timer(timer)
          @node_nats.unsubscribe(subscription)
          opts = SimpleResponse.decode(msg)
          if opts.success
            blk.call(success())
          else
            blk.call(wrap_error(opts))
          end
        end
    rescue => e
      if e.instance_of? ServiceError
        blk.call(failure(e))
      else
        @logger.warn("Exception at unbind_instance #{e}")
        blk.call(internal_fail)
      end
    end
  end

  def before_job_apis service_id, *args, &blk
    raise "service_id can't be nil" unless service_id

    svc = get_instance_handle(service_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc

    plan = find_service_plan(svc)
    extensions_enabled?(plan, :job, &blk)
  rescue => e
    handle_error(e, &blk)
    nil # terminate evoke chain
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

  # Get detail job information by job id.
  #
  def job_details(service_id, job_id, &blk)
    @logger.debug("Get job_id=#{job_id} for service_id=#{service_id}")
    svc = get_instance_handle(service_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, service_id) unless svc
    job = get_job(job_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, job_id) unless job
    blk.call(success(job))
  rescue => e
    handle_error(e, &blk)
  end

  def on_update_service_handle(msg, reply)
    @logger.debug("[#{service_description}] Update service handle #{msg.inspect}")
    handle = Yajl::Parser.parse(msg)
    @update_handle_callback.call(handle) do |response|
      response = Yajl::Encoder.encode(response)
      @node_nats.publish(reply, response)
    end
  end

  # Gateway invoke this function to register a block which provisioner could use to update a service handle
  def register_update_handle_callback(&blk)
    @logger.debug("Register update handle callback with #{blk}")
    @update_handle_callback = blk
  end

  def varz_details
    # Service Provisioner subclasses may want to override this method
    # to provide service specific data beyond the following

    # Mask password from varz details
    svcs = get_all_handles
    svcs.each do |k,v|
      v[:credentials]['pass'] &&= MASKED_PASSWORD
      v[:credentials]['password'] &&= MASKED_PASSWORD
    end

    orphan_instances = @final_orphan_instances.deep_dup
    orphan_bindings = @final_orphan_bindings.deep_dup
    orphan_bindings.each do |k, list|
      list.each do |v|
        v['pass'] &&= MASKED_PASSWORD
        v['password'] &&= MASKED_PASSWORD
      end
    end

    plan_mgmt = []
    @plan_mgmt.each do |plan, v|
      plan_nodes = @nodes.select { |_, node| node["plan"] == plan.to_s }.values
      score = plan_nodes.inject(0) { |sum, node| sum + node_score(node) }
      plan_mgmt << {
        :plan => plan,
        :score => score,
        :low_water => v[:low_water],
        :high_water => v[:high_water],
        :allow_over_provisioning => v[:allow_over_provisioning]?1:0
      }
    end

    varz = {
      :nodes => @nodes,
      :prov_svcs => svcs,
      :orphan_instances => orphan_instances,
      :orphan_bindings => orphan_bindings,
      :plans => plan_mgmt,
      :responses_metrics => @responses_metrics,
    }
    return varz
  rescue => e
    @logger.warn("Exception at varz_details #{e}")
  end

  ########
  # Helpers
  ########

  # Find instance related handles in all handles
  def find_instance_handles(instance_id, handles)
    prov_handle = nil
    binding_handles = []
    handles.each do |h|
      if h['service_id'] == instance_id
        prov_handle = h
      else
        binding_handles << h if h['credentials']['name'] == instance_id
      end
    end
    return [prov_handle, binding_handles]
  end

  # wrap a service message to hash
  def wrap_error(service_msg)
    {
      'success' => false,
      'response' => service_msg.error
    }
  end

  # handle request exception
  def handle_error(e, &blk)
    @logger.error("[#{service_description}] Unexpected Error: #{e}:[#{e.backtrace.join(" | ")}]")
    if e.instance_of? ServiceError
      blk.call(failure(e))
    else
      blk.call(internal_fail)
    end
  end

  # Find which node the service instance is running on.
  def find_node(instance_id)
    svc = get_instance_handle(instance_id)
    raise ServiceError.new(ServiceError::NOT_FOUND, "instance_id #{instance_id}") if svc.nil?
    node_id = svc[:credentials]["node_id"]
    raise "Cannot find node_id for #{instance_id}" if node_id.nil?
    node_id
  end

  # node_score(node) -> number.  this base class provisions on the
  # "best" node (lowest load, most free capacity, etc). this method
  # should return a number; higher scores represent "better" nodes;
  # negative/zero scores mean that a node should be ignored
  def node_score(node)
    node['available_capacity'] if node
  end

  # Service Provisioner subclasses must implement the following
  # methods

  # service_name() --> string
  # (inhereted from VCAP::Services::Base::Base)
  #

  before :job_details, :before_job_apis
end
