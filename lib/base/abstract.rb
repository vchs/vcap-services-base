# Copyright (c) 2009-2011 VMware, Inc.
class Module
  def abstract(*args)
    args.each do |method_name|
      define_method(method_name) do
        raise NotImplementedError.new("Unimplemented abstract method #{self.class.name}##{method_name}")
      end
    end
  end
end

