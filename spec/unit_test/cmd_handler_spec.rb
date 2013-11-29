require 'helper/spec_helper'

describe VCAP::Services::Base::CMDHandle do
  it "should return true if execution suceeds" do
    errback_called = false
    on_err = Proc.new do |cmd, code, msg|
      errback_called = true
    end
    res = VCAP::Services::Base::CMDHandle.execute("echo", 1, on_err)
    res.should be_true
    errback_called.should be_false
  end

  it "should handle errors if the executable is not found or execution fails" do
    ["cmdnotfound", "ls filenotfound"].each do |cmd|
      errback_called = false
      on_err = Proc.new do |command, code, msg|
        errback_called = true
      end
      res = VCAP::Services::Base::CMDHandle.execute(cmd, 1, on_err)
      res.should be_false
      errback_called.should be_true
    end
  end
end
