require "base/plan"
require "base/service"
require "base/service_plan_change_set"

module VCAP::Services::ServicesControllerClient
  class SCService < VCAP::Services::Service

    def initialize(opts)
      super(opts)
    end

    def load_plans(opts)
      @plans = SCPlan.plan_hash_as_plan_array(opts)
    end

    def to_hash
      {
          "description"  => description,
          "provider"     => provider,
          "version"      => version,
          "url"          => url,
          "plans"        => VCAP::Services::ServicesControllerClient::SCPlan.plans_array_to_hash(plans),
          "id"           => unique_id,
          "label"        => label,
          "active"       => active,
          "acls"         => acls,
          "timeout_secs" => timeout,
          "extra"        => extra
      }
    end

  end
end
