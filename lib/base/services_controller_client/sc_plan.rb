require 'base/plan'


module VCAP::Services::ServicesControllerClient
  class SCPlan < VCAP::Services::Plan

    def initialize(opts)
      super(opts)
    end

    def to_hash
      properties = {
          'free' => @free,
          'extra' => @extra,
          'public' => @public,
      }

      {
          'id' => @unique_id,
          'name' => @name,
          'description' => @description,
          'version' => "1", # TODO: Is this really needed
          'properties' => properties.to_json
      }
    end

    def self.plan_hash_as_plan_array(plans)
      plan_array = []
      return plan_array unless plans
      if plans.first.is_a?(SCPlan)
        return plans
      else
        plans.each do |_, v|
          plan_array << SCPlan.new(v)
        end
      end
      plan_array
    end
  end
end
