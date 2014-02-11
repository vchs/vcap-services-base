require 'base64'

module AuthTokenGenerator
  def sc_token_generator(options)
    lambda { "Basic #{Base64.strict_encode64(options[:auth_key])}" }
  end
end