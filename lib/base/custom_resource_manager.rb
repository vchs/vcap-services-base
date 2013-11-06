require 'base/service_error'

class VCAP::Services::CustomResourceManager

  def initialize(opts)
    @logger = opts[:logger]
    @provisioner = opts[:provisioner]
    @node_timeout = opts[:node_timeout]
    @node_nats = @provisioner.node_nats
  end

  def invoke(method_name, args, resource_id, &blk)
    @logger.info("CustomResourceManager: #{method_name}(#{resource_id.nil? ? "" : resource_id})")

    begin
      unless self.respond_to?(method_name)
        @logger.error("CustomResourceManager: #{@klass_name} does not support - #{method_name}")
        raise "CustomResourceManager: Unsupported Operation: #{method_name}"
      end

      self.send(method_name, resource_id, args, blk)
    end
  end
end