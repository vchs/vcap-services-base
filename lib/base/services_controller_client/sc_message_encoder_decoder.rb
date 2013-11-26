require 'message_encoder_decoder_base'
require 'vcap_services_messages/service_message'

module VCAP
  module Services
    module ServicesControllerClient
      class SCMessageEncoderDecoder < VCAP::Services::MessageEncoderDecoderBase

        def decode_provision_request(body)
          VCAP::Services::Internal::GatewayProvisionRequest.decode(body)
        end

        def encode_provision_response(body)
          VCAP::Services::Internal::GatewayProvisionResponse.new(body).encode
        end

        def decode_perform_request(body)
          VCAP::Services::Internal::PerformOperationRequest.decode(body)
        end
      end
    end
  end
end

