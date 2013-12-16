require 'abstract'

module VCAP
  module Services
    class MessageEncoderDecoderBase

      # Support Provision Request / Response
      def decode_provision_request(body)
        raise "Unsupported Operation"
      end

      def encode_provision_response(body)
        raise "Unsupported Operation"
      end

      # Perform request
      def decode_perform_request(body)
        raise "Unsupported Operation"
      end

      # Bind request/response
      def decode_bind_request(body)
        raise "Unsupported Operation"
      end

      def encode_bind_response(body)
        raise "Unsupported Operation"
      end

      # Unbind request
      def decode_unbind_request(body)
        raise "Unsupported Operation"
      end

      # Update Bind request
      def decode_update_bind_request(body)
        raise "Unsupported Operation"
      end
    end
  end
end
