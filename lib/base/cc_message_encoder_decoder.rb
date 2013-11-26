require 'message_encoder_decoder_base'

module VCAP
  module Services
    class CCMessageEncoderDecoder < VCAP::Services::MessageEncoderDecoderBase

      def decode_provision_request(body)
        VCAP::Services::Api::GatewayProvisionRequest.decode(body)
      end

      def encode_provision_response(body)
        VCAP::Services::Api::GatewayHandleResponse.new(body).encode
      end

      def decode_bind_request(body)
        VCAP::Services::Api::GatewayBindRequest.decode(body)
      end

      def encode_bind_response(body)
        VCAP::Services::Api::GatewayHandleResponse.new(body).encode
      end

      def decode_unbind_request(body)
        VCAP::Services::Api::GatewayUnbindRequest.decode(body)
      end
    end
  end
end
