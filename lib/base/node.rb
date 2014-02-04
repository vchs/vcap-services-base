# Copyright (c) 2009-2011 VMware, Inc.
require 'nats/client'
require 'vcap/component'
require 'fileutils'
require 'socket'

$:.unshift(File.dirname(__FILE__))
require 'base'
require 'vcap_services_messages/service_message'
require 'datamapper_l'

class VCAP::Services::Base::Node < VCAP::Services::Base::Base
  include VCAP::Services::Internal

  DEFAULT_HEARTBEAT_INTERVAL = 10 # In secs

  def initialize(options)
    super(options)
    @node_id = options[:node_id]
    @plan = options[:plan]
    @capacity = options[:capacity]
    @max_capacity = @capacity
    @capacity_lock = Mutex.new
    @migration_nfs = options[:migration_nfs]
    @fqdn_hosts = options[:fqdn_hosts]
    @op_time_limit = options[:op_time_limit]
    @disabled_file = options[:disabled_file]
    DataMapper::initialize_lock_file(options[:database_lock_file]) if options[:database_lock_file]

    @setup_nats_for_custom_operations = options[:setup_nats_for_custom_operations] || false

    # A default supported version
    # *NOTE: All services *MUST* override this to provide the actual supported versions
    @supported_versions = options[:supported_versions] || []
    z_interval = options[:z_interval] || 30
    EM.add_periodic_timer(z_interval) do
      EM.defer { update_varz }
    end if @node_nats

    # Defer 5 seconds to give service a change to wake up
    EM.add_timer(5) do
      EM.defer { update_varz }
    end if @node_nats
  end

  def flavor
    return "Node"
  end

  def on_connect_node
    @logger.debug("#{service_description}: Connected to node mbus")

    %w[provision unprovision update_credentials bind unbind purge_orphan  config_update
    ].each do |op|
      eval %[@node_nats.subscribe("#{service_name}.#{op}.#{@node_id}") { |msg, reply| EM.defer{ on_#{op}(msg, reply) } }]
    end
    %w[discover check_orphan].each do |op|
      eval %[@node_nats.subscribe("#{service_name}.#{op}") { |msg, reply| EM.defer{ on_#{op}(msg, reply) } }]
    end

    if @setup_nats_for_custom_operations
      @logger.info("Subscribing to: #{service_name}.perform.#{@node_id} for performing custom operations")

      @node_nats.subscribe("#{service_name}.perform.#{@node_id}") { |msg, reply|
        EM.defer {
          @logger.debug("#{service_description}: Perform request: #{msg}")
          begin
            req = VCAP::Services::Internal::PerformOperationRequest.decode(msg)

            operation = req.args.delete("operation") { |k|
              raise "Missing operation name"
            }

            raise "Unsupported operation: #{operation}" unless self.respond_to?(operation, true)

            result = 0
            code = ""
            props = {}
            body = {}

            code, props, body = self.send(operation, req.args)
          rescue => e
            @logger.error("Failed to perform custom operation due to: #{e.inspect}")
            result = 1
            code = "failed"
            props = {}
            body = {:msg => e.message}
          end

          perform_response = VCAP::Services::Internal::PerformOperationResponse.new({
            :result => result,
            :code => code,
            :properties => props,
            :body => body
          })
          publish(reply, perform_response.encode)
        }
      }
    end

    pre_send_announcement
    send_node_announcement
    EM.add_periodic_timer(30) { send_node_announcement }

    hb_interval = @options[:instances_heartbeat_interval] || DEFAULT_HEARTBEAT_INTERVAL
    EM.add_periodic_timer(hb_interval) { send_instances_heartbeat }

  end

  # raise an error if operation does not finish in time limit
  # and perform a rollback action if rollback function is provided
  def timing_exec(time_limit, rollback=nil)
    return unless block_given?

    start = Time.now
    response = yield
    if response && Time.now - start > time_limit
      rollback.call(response) if rollback
      raise ServiceError::new(ServiceError::NODE_OPERATION_TIMEOUT)
    end
  end

  def on_provision(msg, reply)
    @logger.debug("#{service_description}: Provision request: #{msg} from #{reply}")
    response = ProvisionResponse.new
    rollback = lambda do |res|
      @logger.error("#{service_description}: Provision takes too long. Rollback for #{res.inspect}")
      @capacity_lock.synchronize { @capacity += capacity_unit } if unprovision(res.credentials["service_id"], [])
    end

    timing_exec(@op_time_limit, rollback) do
      provision_req = ProvisionRequest.decode(msg)
      plan = provision_req.plan
      credentials = provision_req.credentials
      version = provision_req.version
      properties = provision_req.properties
      @logger.debug("#{service_description}: Provision Request Details - plan=#{plan}, credentials=#{credentials}, version=#{version} properties #{properties}")
      credential = provision(plan, credentials, version, properties)
      credential['node_id'] = @node_id
      response.credentials = credential
      @capacity_lock.synchronize { @capacity -= capacity_unit }
      @logger.debug("#{service_description}: Successfully provisioned service for request #{msg}: #{response.inspect}")
      send_instances_heartbeat(credential["service_id"])
      response
    end
    publish(reply, encode_success(response))
  rescue => e
    @logger.warn("Exception at on_provision #{e}")
    publish(reply, encode_failure(response, e))
  end

  def on_unprovision(msg, reply)
    @logger.debug("#{service_description}: Unprovision request: #{msg}.")
    response = SimpleResponse.new
    unprovision_req = UnprovisionRequest.decode(msg)
    service_id = unprovision_req.name
    bindings = unprovision_req.bindings
    result = unprovision(service_id, bindings)
    if result
      publish(reply, encode_success(response))
      @capacity_lock.synchronize { @capacity += capacity_unit }
    else
      publish(reply, encode_failure(response))
    end
  rescue => e
    @logger.warn("Exception at on_unprovision #{e}")
    publish(reply, encode_failure(response, e))
  end


  def on_update_credentials(msg, reply)
    @logger.debug("#{service_description}: Update credentials request: #{msg} from #{reply}")
    response = SimpleResponse.new

    timing_exec(@op_time_limit) do
      args = PerformOperationRequest.decode(msg).args
      update_credentials(args['service_id'], args['credentials'])
      response
    end
    @logger.debug("#{service_description}: Update credentials succeeds")
    publish(reply, encode_success(response))
  rescue => e
    @logger.warn("Exception at on_update_credentials #{e}")

  def on_config_update(msg, reply)
    @logger.debug("#{service_description}: Config update request: #{msg}.")
    response = SimpleResponse.new
    config_update_req = ConfigUpdate.decode(msg)
    config_update = config_update_req.new_configs
    config_update.each do |k,v|
      eval  "@#{k} = #{v}"
    end

    publish(reply, encode_success(response))

  rescue => e
    @logger.warn("Exception at config update #{e}")

    publish(reply, encode_failure(response, e))
  end

  def on_bind(msg, reply)
    @logger.debug("#{service_description}: Bind request: #{msg} from #{reply}")
    response = BindResponse.new
    rollback = lambda do |res|
      @logger.error("#{service_description}: Binding takes too long. Rollback for #{res.inspect}")
      unbind(res.credentials)
    end

    timing_exec(@op_time_limit, rollback) do
      bind_message = BindRequest.decode(msg)
      service_id = bind_message.name
      bind_opts = bind_message.bind_opts
      credentials = bind_message.credentials
      response.credentials = bind(service_id, bind_opts, credentials)
      response
    end
    publish(reply, encode_success(response))
  rescue => e
    @logger.warn("Exception at on_bind #{e}")
    publish(reply, encode_failure(response, e))
  end

  def on_unbind(msg, reply)
    @logger.debug("#{service_description}: Unbind request: #{msg} from #{reply}")
    response = SimpleResponse.new
    unbind_req = UnbindRequest.decode(msg)
    result = unbind(unbind_req.credentials)
    if result
      publish(reply, encode_success(response))
    else
      publish(reply, encode_failure(response))
    end
  rescue => e
    @logger.warn("Exception at on_unbind #{e}")
    publish(reply, encode_failure(response, e))
  end

  # Send all handles to gateway to check orphan
  def on_check_orphan(msg, reply)
    @logger.debug("#{service_description}: Request to check orphan")
    live_ins_list = all_instances_list
    live_bind_list = all_bindings_list
    handles_size = @max_nats_payload - 200

    group_handles_in_json(live_ins_list, live_bind_list, handles_size) do |ins_list, bind_list|
      request = NodeHandlesReport.new
      request.instances_list = ins_list
      request.bindings_list = bind_list
      request.node_id = @node_id
      publish("#{service_name}.node_handles", request.encode)
    end
  rescue => e
    @logger.warn("Exception at on_check_orphan #{e}")
  end

  def on_purge_orphan(msg, reply)
    @logger.debug("#{service_description}: Request to purge orphan")
    request = PurgeOrphanRequest.decode(msg)
    purge_orphan(request.orphan_ins_list, request.orphan_binding_list)
  rescue => e
    @logger.warn("Exception at on_purge_orphan #{e}")
  end

  def purge_orphan(oi_list, ob_list)
    oi_list.each do |ins|
      begin
        @logger.debug("Unprovision orphan instance #{ins}")
        @capacity_lock.synchronize { @capacity += capacity_unit } if unprovision(ins, [])
      rescue => e
        @logger.debug("Error on purge orphan instance #{ins}: #{e}")
      end
    end

    ob_list.each do |credential|
      begin
        @logger.debug("Unbind orphan binding #{credential}")
        unbind(credential)
      rescue => e
        @logger.debug("Error on purge orphan binding #{credential}: #{e}")
      end
    end
  end

  def get_instance_health(instance_name)
  end

  def send_instances_heartbeat(given_instance_list = [])
    states = instances_health_details(given_instance_list)
    return if states.empty?

    hbs = {:node_type => service_name,
           :node_id => @node_id,
           :node_ip => get_host,
           :instances => states}
    publish("svc.heartbeat", Yajl::Encoder.encode(hbs))
    nil
  end

  def instances_health_details(given_instance_list = [])
    given_instance_list ||= []
    given_instance_list = [given_instance_list] unless given_instance_list.is_a?(Array)
    given_instance_list = given_instance_list.empty? ? all_instances_list : given_instance_list
    # provisioned services status
    states = {}
    begin
      given_instance_list.each do |service_id|
        states[service_id.to_sym] = get_instance_health(service_id)
      end
    rescue => e
      @logger.error("Error get instance health: #{e}")
    end
    states
  end

  # Subclass must overwrite this method to enable check orphan instance feature.
  # Otherwise it will not check orphan instance
  # The return value should be a list of instance name(handle["service_id"]).
  def all_instances_list
    []
  end

  # Subclass must overwrite this method to enable check orphan binding feature.
  # Otherwise it will not check orphan bindings
  # The return value should be a list of binding credentials
  # Binding credential will be the argument for unbind method
  # And it should have at least username & name property for base code
  # to find the orphans
  def all_bindings_list
    []
  end

  def get_all_bindings(handles)
    binding_creds = []
    handles.each do |handle|
      binding_creds << handle["credentials"]
    end
    binding_creds
  end

  def get_all_bindings_with_option(handles)
    binding_creds_hash = {}
    handles.each do |handle|
      value = {
          "credentials" => handle["credentials"],
          "binding_options" => nil
      }
      value["binding_options"] = handle["configuration"]["data"]["binding_options"] if handle["configuration"].has_key?("data")
      binding_creds_hash[handle["service_id"]] = value
    end
    binding_creds_hash
  end

  def on_discover(msg, reply)
    send_node_announcement(msg, reply)
  end

  def pre_send_announcement
  end

  def disabled?
    File.exist?(@disabled_file)
  end

  def send_node_announcement(msg=nil, reply=nil)
    if disabled?
      @logger.info("#{service_description}: Not sending announcement because node is disabled")
      return
    end
    unless node_ready?
      @logger.debug("#{service_description}: Not ready to send announcement")
      return
    end
    @logger.debug("#{service_description}: Sending announcement for #{reply || "everyone"}")
    req = nil
    req = Yajl::Parser.parse(msg) if msg
    if !req || req["plan"] == @plan
      a = announcement
      a[:id] = @node_id
      a[:plan] = @plan
      a[:supported_versions] = @supported_versions
      publish(reply || "#{service_name}.announce", Yajl::Encoder.encode(a))
    end
  rescue => e
    @logger.warn("Exception at send_node_announcement #{e}")
  end

  def node_ready?
    # Service Node subclasses can override this method if they depend
    # on some external service in order to operate; for example, MySQL
    # and Postgresql require a connection to the underlying server.
    true
  end

  def varz_details
    # Service Node subclasses may want to override this method to
    # provide service specific data beyond what is returned by their
    # "announcement" method.
    return announcement
  end

  def capacity_unit
    # subclasses could overwrite this method to re-define
    # the capacity unit decreased/increased by provision/unprovision
    1
  end

  # Helper
  def encode_success(response)
    response.success = true
    response.encode
  end

  def encode_failure(response, error=nil)
    response.success = false
    if error.nil? || !error.is_a?(ServiceError)
      error = ServiceError.new(ServiceError::INTERNAL_ERROR)
    end
    response.error = error.to_hash
    response.encode
  end

  def get_host
    @fqdn_hosts ? Socket.gethostname : @local_ip
  end

  # Service Node subclasses must implement the following methods

  # provision(plan) --> {name, host, port, user, password}, {version}
  abstract :provision

  # unprovision(name) --> void
  abstract :unprovision

  # bind(name, bind_opts) --> {host, port, login, secret}
  abstract :bind

  # unbind(credentials)  --> void
  abstract :unbind

  # announcement() --> { any service-specific announcement details }
  abstract :announcement

  # service_name() --> string
  # (inhereted from VCAP::Services::Base::Base)

  # perform(PerformCustomResourceOperationRequest)
  abstract :perform

end
