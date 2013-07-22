# Copyright (c) 2009-2011 VMware, Inc.
#
$:.unshift(File.expand_path("../..", __FILE__))
require 'json_message'
require 'base'

class ServiceMessage < JsonMessage

  def set_field(field, value)
    f = self.class.fields[field.to_sym]
    if !value && f && f.required == false
      @msg.delete(field)
    else
      super(field, value)
    end
  end

  # Return a deep copy of @msg
  def dup
    @msg.deep_dup
  end

  def inspect
    @msg.inspect
  end
end
