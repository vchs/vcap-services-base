require 'base/service_error'
require 'base/http_handler'
require 'base/auth_token_generator'

class VCAP::Services::CustomResourceManager

  include VCAP::Services::Base::Error
  include AuthTokenGenerator

  def initialize(opts)
    @logger = opts[:logger]
    @provisioner = opts[:provisioner]
    @node_timeout = opts[:node_timeout]
    @http_handler = HTTPHandler.new(opts, sc_token_generator(opts))
    @node_nats = @provisioner.node_nats  # Used if gateway wishes to communicate over nats for custom operations
  end

  def invoke(method_name, resource_id, args, &blk)
    @logger.info("CustomResourceManager: #{method_name}(#{resource_id.nil? ? "" : resource_id}) - Args= #{args}")

    begin
      unless self.respond_to?(method_name)
        @logger.error("CustomResourceManager: #{@klass_name} does not support - #{method_name}")
        raise "Unsupported operation: #{method_name}"
      end

      self.send(method_name, resource_id, args, blk)
    rescue => e
      err_msg = VCAP::Services::Internal::PerformOperationResponse.new(
          {
              :result => 1,
              :code => "failed",
              :properties => {},
              :body => { :message => e.message }
          }
      ).encode
      blk.call(err_msg)
    end
  end

  def update_resource_properties(url, properties)
    properties = Yajl::Encoder.encode(properties)
    @http_handler.cc_http_request(:uri => url,
                                  :method => "put",
                                  :body => Yajl::Encoder.encode({ "properties" => properties})) do |http|
      if !http.error
        if (200..299) === http.response_header.status
          @logger.info("CustomResourceManager: Successfully updated resource properties: #{JSON.parse(http.response)}")
        else
          @logger.error("CustomResourceManager:: Failed to update resource properties - status=#{http.response_header.status}")
        end
      else
        @logger.error("CustomResourceManager:: Failed to update resource properties: #{http.error}")
      end
    end
  end

   def required_options(args, *fields)
     missing_opts = fields.select{|field| !args.has_key? field.to_s}
     raise ArgumentError, "Missing #{missing_opts.join(', ')} in args: #{args.inspect}" unless missing_opts.empty?
   end
end
