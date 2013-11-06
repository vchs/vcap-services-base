require 'base/service_error'

class VCAP::Services::CustomResourceManager

  def initialize(opts)
    @logger = opts[:logger]
    @provisioner = opts[:provisioner]
    @node_timeout = opts[:node_timeout]
    @node_nats = @provisioner.node_nats  # Used if gateway wishes to communicate over nats for custom operations
  end

  def invoke(method_name, resource_id, args, &blk)
    @logger.info("CustomResourceManager: #{method_name}(#{resource_id.nil? ? "" : resource_id}) - Args= #{args}")

    begin
      unless self.respond_to?(method_name)
        @logger.error("CustomResourceManager: #{@klass_name} does not support - #{method_name}")
        raise "CustomResourceManager: Unsupported Operation: #{method_name}"
      end

      self.send(method_name, resource_id, args, blk)
    end
  end

  def update_resource_properties(url, properties)
    @http_handler.cc_http_request(:uri => url,
                                  :method => "put",
                                  :body => Yajl::Encoder.encode({ "properties" => properties})) do |http|
      if !http.error
        if (200..299) === http.response_header.status
          @logger.info("CustomResourceManager: Successfully updated resource properties: #{JSON.parse(http.response)}")
        else
          logger.error("CustomResourceManager:: Failed to update resource properties - status=#{http.response_header.status}")
        end
      else
        logger.error("CustomResourceManager:: Failed to update resource properties: #{http.error}")
      end
    end
  end

end