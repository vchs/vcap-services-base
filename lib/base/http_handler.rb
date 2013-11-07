require 'uaa'

class HTTPHandler
  HTTP_UNAUTHENTICATED_CODE = 401
  attr_reader :logger

  def initialize(options, auth_token_generator = nil)
    @logger = options[:logger]
    @options = options
    @cld_ctrl_uri = options[:cloud_controller_uri]
    @auth_token_generator = auth_token_generator
  end

  def cc_http_request(args, &block)
    args[:uri] = "#{@cld_ctrl_uri}#{args[:uri]}"
    args[:head] = cc_req_hdrs
    max_attempts = args[:max_attempts] || 2
    attempts = 0
    while true
      attempts += 1
      logger.debug("#{args[:method].upcase} - #{args[:uri]}")
      http = make_http_request(args)
      if attempts < max_attempts && http.response_header.status == HTTP_UNAUTHENTICATED_CODE
        @cc_req_hdrs = regenerate_http_header
      else
        block.call(http)
        return http
      end
    end
  end

  def regenerate_http_header
    @cc_req_hdrs = {'Content-Type' => 'application/json'}
    @cc_req_hdrs.merge!({'Authorization' => @auth_token_generator.call }) if @auth_token_generator
    @cc_req_hdrs
  end


  def cc_req_hdrs
    @cc_req_hdrs || regenerate_http_header
  end

  def generate_cc_advertise_offering_request(service, active = true)
    svc = service.to_hash

    # NOTE: In CCNG, multiple versions is expected to be supported via multiple plans
    # The gateway will have to maintain a mapping of plan-name to version so that
    # the correct version will be provisioned
    plans = {}
    svc.delete('plans').each do |p|
      plans[p[:name]] = {
        "unique_id" => p[:unique_id],
        "name" => p[:name],
        "description" => p[:description],
        "free" => p[:free]
      }
    end

    [svc, plans]
  end

  private
  def make_http_request(args)
    req = {
      :head => args[:head],
      :body => args[:body],
    }

    f = Fiber.current
    http = EM::HttpRequest.new(args[:uri]).send(args[:method], req)
    if http.error && http.error != ""
      unless args[:need_raise]
        @logger.error("Catalog Manager (HTTPHandler): Failed to connect to CC, the error is #{http.error}")
        return
      else
        raise("Catalog Manager (HTTPHandler): Failed to connect to CC, the error is #{http.error}")
      end
    end
    http.callback { f.resume(http, nil) }
    http.errback { |e| f.resume(http, e) }
    _, error = Fiber.yield
    yield http, error if block_given?
    http
  end
end
