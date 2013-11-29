# Copyright (c) 2009-2011 VMware, Inc.
require 'base_async_gateway'
require 'gateway_service_catalog'
require 'vcap_services_messages/service_message'

$:.unshift(File.dirname(__FILE__))

# A simple service gateway that proxies requests onto an asynchronous service provisioners.
# NB: Do not use this with synchronous provisioners, it will produce unexpected results.
#
# TODO(mjp): This needs to handle unknown routes
module VCAP::Services
  class AsynchronousServiceGateway < BaseAsynchronousServiceGateway

    REQ_OPTS = %w(service token provisioner cloud_controller_uri).map { |o| o.to_sym }
    attr_reader :event_machine, :logger, :service

    def initialize(opts)
      super(opts)
    end

    # setup the environment
    def setup(opts)
      missing_opts = REQ_OPTS.select { |o| !opts.has_key? o }
      raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?
      @service = opts[:service]
      @token = opts[:token]
      @logger = opts[:logger] || make_logger()
      @cld_ctrl_uri = http_uri(opts[:cloud_controller_uri])
      @provisioner = opts[:provisioner]
      @hb_interval = opts[:heartbeat_interval] || 60
      @node_timeout = opts[:node_timeout]
      @handle_fetch_interval = opts[:handle_fetch_interval] || 1
      @check_orphan_interval = opts[:check_orphan_interval] || -1
      @double_check_orphan_interval = opts[:double_check_orphan_interval] || 300
      @handle_fetched = opts[:handle_fetched] || false
      @fetching_handles = false
      @version_aliases = service[:version_aliases] || {}

      @custom_resource_manager = opts[:custom_resource_manager]

      opts[:gateway_name] ||= "Service Gateway"

      @cc_api_version = opts[:cc_api_version] || "v1"
      if @cc_api_version == "v1"
        require 'catalog_manager_v1'
        @catalog_manager = VCAP::Services::CatalogManagerV1.new(opts)
      elsif @cc_api_version == "v2"
        require 'catalog_manager_v2'
        @catalog_manager = VCAP::Services::CatalogManagerV2.new(opts)
      elsif @cc_api_version == "scv1"
        require 'services_controller_client/catalog_manager_sc_v1'
        @catalog_manager = VCAP::Services::ServicesControllerClient::SCCatalogManagerV1.new(opts)
      else
        raise "Unknown cc_api_version: #{@cc_api_version}"
      end

      @event_machine = opts[:event_machine] || EM

      # Setup heartbeats and exit handlers
      event_machine.add_periodic_timer(@hb_interval) { send_heartbeat }
      event_machine.next_tick { send_heartbeat }
      Kernel.at_exit do
        @logger.error("Kernel exit. #{$!}:#{$!.backtrace.join('|')}") if (@logger && $!)
        if event_machine.reactor_running?
          # :/ We can't stop others from killing the event-loop here. Let's hope that they play nice
          send_deactivation_notice(false)
        else
          event_machine.run { send_deactivation_notice }
        end
      end

      # Add any necessary handles we don't know about
      update_callback = Proc.new do |resp|
        @provisioner.update_handles(resp.handles)
        @handle_fetched = true
        event_machine.cancel_timer(@fetch_handle_timer)
      end

      @fetch_handle_timer = event_machine.add_periodic_timer(@handle_fetch_interval) { fetch_handles(&update_callback) }
      event_machine.next_tick { fetch_handles(&update_callback) }

      if @check_orphan_interval > 0
        handler_check_orphan = Proc.new do |resp|
          check_orphan(resp.handles,
                       lambda { logger.info("Check orphan is requested") },
                       lambda { |errmsg| logger.error("Error on requesting to check orphan #{errmsg}") })
        end
        event_machine.add_periodic_timer(@check_orphan_interval) { fetch_handles(&handler_check_orphan) }
      end

      # Register update handle callback
      @provisioner.register_update_handle_callback { |handle, &blk| update_service_handle(handle, &blk) }
    end

    def get_current_catalog
      GatewayServiceCatalog.new([service]).to_hash
    end

    def check_orphan(handles, callback, errback)
      @provisioner.check_orphan(handles) do |msg|
        if msg['success']
          callback.call
          event_machine.add_timer(@double_check_orphan_interval) { fetch_handles { |rs| @provisioner.double_check_orphan(rs.handles) } }
        else
          errback.call(msg['response'])
        end
      end
    end

    # Validate the incoming request
    def validate_incoming_request
      unless request.media_type == Rack::Mime.mime_type('.json')
        error_msg = ServiceError.new(ServiceError::INVALID_CONTENT).to_hash
        logger.error("Validation failure: #{error_msg.inspect}, request media type: #{request.media_type} is not json")
        abort_request(error_msg)
      end
      unless auth_token && (auth_token == @token)
        error_msg = ServiceError.new(ServiceError::NOT_AUTHORIZED).to_hash
        logger.error("Validation failure: #{error_msg.inspect}, expected token: #{@token}, specified token: #{auth_token}")
        abort_request(error_msg)
      end
      unless @handle_fetched
        error_msg = ServiceError.new(ServiceError::SERVICE_UNAVAILABLE).to_hash
        logger.error("Validation failure: #{error_msg.inspect}, handles not fetched")
        abort_request(error_msg)
      end
    end

    ########## Custom Operations Handlers ############

    # Create custom resource
    post '/gateway/v1/resources/:resource_name' do
      op_name = "create_#{params['resource_name']}"
      req = VCAP::Services::Internal::PerformOperationRequest.decode(request_body)
      req.args["operation"] = op_name

      unless @custom_resource_manager
        error_msg = "No custom resource manager defined"
        abort_request(error_msg)
      end

      @custom_resource_manager.invoke(op_name, nil, req.args) do |msg|
        async_reply(msg)
      end
      async_mode
    end

    # Read custom resource
    get '/gateway/v1/resources/:resource_name/:resource_id' do
      op_name = "get_#{params['resource_name']}"
      req = VCAP::Services::Internal::PerformOperationRequest.decode(request_body)
      req.args["operation"] = op_name

      unless @custom_resource_manager
        error_msg = "No custom resource manager defined"
        abort_request(error_msg)
      end

      @custom_resource_manager.invoke(op_name, params['resource_id'], req.args) do |msg|
        async_reply(msg)
      end
      async_mode
    end

    # Update custom resource
    put '/gateway/v1/resources/:resource_name/:resource_id' do
      op_name = "update_#{params['resource_name']}"
      req = VCAP::Services::Internal::PerformOperationRequest.decode(request_body)
      req.args["operation"] = op_name

      unless @custom_resource_manager
        error_msg = "No custom resource manager defined"
        abort_request(error_msg)
      end

      @custom_resource_manager.invoke(op_name, params['resource_id'], req.args) do |msg|
        async_reply(msg)
      end
      async_mode
    end

    # Delete custom resource
    delete '/gateway/v1/resources/:resource_name/:resource_id' do
      op_name = "delete_#{params['resource_name']}"
      req = VCAP::Services::Internal::PerformOperationRequest.decode(request_body)
      req.args["operation"] = op_name

      unless @custom_resource_manager
        error_msg = "No custom resource manager defined"
        abort_request(error_msg)
      end

      @custom_resource_manager.invoke(op_name, params['resource_id'], req.args) do |msg|
        async_reply(msg)
      end
      async_mode
    end

    #################### Handlers ####################

    # Provisions an instance of the service
    #
    post '/gateway/v1/configurations' do
      req = VCAP::Services::Api::GatewayProvisionRequest.decode(request_body)
      @logger.debug("Provision request for unique_id=#{req.unique_id}")

      plan_unique_ids = service.fetch(:plans).values.map {|p| p.fetch(:unique_id) }

      unless plan_unique_ids.include?(req.unique_id)
        error_msg = ServiceError.new(ServiceError::UNKNOWN_PLAN_UNIQUE_ID).to_hash
        abort_request(error_msg)
      end

      @provisioner.provision_service(req) do |msg|
        if msg['success']
          async_reply(VCAP::Services::Api::GatewayHandleResponse.new(msg['response']).encode)
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    # Unprovisions a previously provisioned instance of the service
    #
    delete '/gateway/v1/configurations/:service_id' do
      logger.debug("Unprovision request for service_id=#{params['service_id']}")

      @provisioner.unprovision_service(params['service_id']) do |msg|
        if msg['success']
          async_reply
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    # Binds a previously provisioned instance of the service to an application
    #
    post '/gateway/v1/configurations/:service_id/handles' do
      logger.info("Binding request for service=#{params['service_id']}")

      req = VCAP::Services::Api::GatewayBindRequest.decode(request_body)
      logger.debug("Binding options: #{req.binding_options.inspect}")

      @provisioner.bind_instance(req.service_id, req.binding_options) do |msg|
        if msg['success']
          async_reply(VCAP::Services::Api::GatewayHandleResponse.new(msg['response']).encode)
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    # Unbinds a previously bound instance of the service
    #
    delete '/gateway/v1/configurations/:service_id/handles/:handle_id' do
      logger.info("Unbind request for service_id={params['service_id']} handle_id=#{params['handle_id']}")

      req = VCAP::Services::Api::GatewayUnbindRequest.decode(request_body)

      @provisioner.unbind_instance(req.service_id, req.handle_id, req.binding_options) do |msg|
        if msg['success']
          async_reply
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    # Get Job details
    get "/gateway/v1/configurations/:service_id/jobs/:job_id" do
      service_id = params["service_id"]
      job_id = params["job_id"]
      logger.info("Get job=#{job_id} for service_id=#{service_id}")
      @provisioner.job_details(service_id, job_id) do |msg|
        if msg['success']
          async_reply(VCAP::Services::Api::Job.new(msg['response']).encode)
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    post '/service/internal/v1/check_orphan' do
      logger.info("Request to check orphan")
      fetch_handles do |resp|
        check_orphan(resp.handles,
                     lambda { async_reply },
                     lambda { |errmsg| async_reply_error(errmsg) })
      end
      async_mode
    end

    delete '/service/internal/v1/purge_orphan' do
      logger.info("Purge orphan request")
      req = Yajl::Parser.parse(request_body)
      orphan_ins_hash = req["orphan_instances"]
      orphan_binding_hash = req["orphan_bindings"]
      @provisioner.purge_orphan(orphan_ins_hash, orphan_binding_hash) do |msg|
        if msg['success']
          async_reply
        else
          async_reply_error(msg['response'])
        end
      end
      async_mode
    end

    #################### Helpers ####################

    helpers do

      # Fetches canonical state (handles) from the Cloud Controller
      def fetch_handles(&cb)
        f = Fiber.new do
          @catalog_manager.fetch_handles_from_cc(service[:label], cb)
        end
        f.resume
      end

      # Update a service handle using REST
      def update_service_handle(handle, &cb)
        f = Fiber.new do
          @catalog_manager.update_handle_in_cc(
            service[:label],
            handle,
            lambda {
              # Update local array in provisioner
              @provisioner.update_handles([handle])
              cb.call(true) if cb
            },
            lambda { cb.call(false) if cb }
          )
        end
        f.resume
      end

      # Lets the cloud controller know we're alive and where it can find us
      def send_heartbeat
        @catalog_manager.update_catalog(
          true,
          lambda { return get_current_catalog },
          nil
        )
      end

      # Lets the cloud controller know that we're going away
      def send_deactivation_notice(stop_event_loop=true)
        @catalog_manager.update_catalog(
          false,
          lambda { return get_current_catalog },
          lambda { event_machine.stop if stop_event_loop }
        )
      end

    end
  end
end
