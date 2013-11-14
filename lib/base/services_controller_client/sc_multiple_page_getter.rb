require 'base/services_controller_client/sc_service'
require 'base/services_controller_client/sc_plan'

module VCAP::Services::ServicesControllerClient
  class MultiplePageGetter
    def initialize(http_client, headers, logger)
      @http_client = http_client
      @headers = headers
      @logger = logger
    end

    attr_reader :logger

    def load_registered_services(service_list_uri)
      logger.debug("SCCM(v1): Getting services listing from services controller")
      registered_services = []

      self.each(service_list_uri, "Registered Offerings") do |s|
        entity = s["entity"]
        plans = []

        service_plans_url = "/api/v1/service_plans?service_id=#{s["metadata"]["guid"]}"
        logger.debug("Getting service plans for: #{entity["label"]}/#{entity["provider"]}")
        self.each(service_plans_url, "Service Plans") do |p|
          plan_entity = p.fetch('entity')
          plan_metadata = p.fetch('metadata')

          plan_properties = {}
          begin
            plan_properties = JSON.parse(plan_entity["properties"])
          rescue Exception => e
            logger.debug("Failed to parse properties #{plan_entity['properties']}")
          end

          plans << VCAP::Services::ServicesControllerClient::SCPlan.new(
              :guid => plan_metadata["guid"],

              :unique_id   => plan_entity["id"],
              :name        => plan_entity["name"],
              :description => plan_entity["description"],
              :active      => plan_entity["active"],

              :free   => plan_properties["free"] || false,
              :extra  => plan_properties["extra"] || {},
              :public => plan_properties["public"] || {},
          )
        end

        registered_services << VCAP::Services::ServicesControllerClient::SCService.new(
            'guid' => s["metadata"]["guid"],

            'label'       => entity["label"],
            'unique_id'   => entity["id"],
            'description' => entity["description"],
            'provider'    => entity["provider"],
            'timeout'     => entity["timeout_secs"],
            'version'     => entity['version'],
            'url'         => entity["url"],
            'info_url'    => entity["info_url"],
            'extra'       => entity['extra'],

            'plans' => plans
        )
      end

      registered_services
    end

    def each(seed_url, description, &block)
      url = seed_url
      logger.info("SCCM(v1): Initiate fetching #{description} from: #{seed_url}")

      while !url.nil? do
        logger.debug("SCCM(v1): Fetching #{description} from: #{url}")
        @http_client.call(:uri => url,
                          :method => "get",
                          :head => @headers,
                          :need_raise => true) do |http|
          result = nil
          if (200..299) === http.response_header.status
            logger.debug("SCCM(v1): Response for (#{url}): #{result.inspect}")
            result = JSON.parse(http.response)
          elsif 404 == http.response_header.status
            logger.debug("SCCM(v1): No result")
            return
          else
            raise "SCCM(v1): Multiple page fetch via: #{url} failed: (#{http.response_header.status}) - #{http.response}"
          end

          result.fetch("resources").each { |r| block.yield r }
          url = result["next_url"]
        end
      end
    end
  end
end
