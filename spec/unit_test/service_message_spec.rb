require 'helper/spec_helper'
require 'base/api/message'

describe "ServiceMessage" do
  let(:klass) do
    k = Class.new(ServiceMessage)
    k.required :name, String
    k.optional :tag, String
    k
  end

  it "ignore the unknown field" do
    expect do
      klass.new({:name => "test", :unknown => "unknown"})
    end.not_to raise_error
  end

  it "remove the optional field that has nil value" do
    msg = klass.new({:name => "test", :tag => nil})
    msg.encode !~ /tag/
  end
end

