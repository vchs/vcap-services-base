module VCAP
  module Services
    module Base
    end
  end
end

class VCAP::Services::Base::CMDHandle

  def initialize(cmd, timeout=nil, &blk)
    @cmd  = cmd
    @timeout = timeout
    @errback = blk
  end

  def run
    pid = fork
    if pid
      # parent process
      success = false
      begin
        success = Timeout::timeout(@timeout) do
          Process.waitpid(pid)
          value = $?.exitstatus
          @errback.call(@cmd, value, "No message.") if value != 0 && @errback
          return value == 0
        end
      rescue Timeout::Error
        Process.detach(pid)
        Process.kill("KILL", pid)
        @errback.call(@cmd, -1, "Killed due to timeout.") if @errback
        return false
      end
    else
      begin
        # child process
        exec(@cmd)
      rescue
        exit!
      end
    end
  end

  def self.execute(cmd, timeout = nil, *args)
    errb = args.pop if args.last.is_a? Proc
    instance = self.new(cmd, timeout, &errb)
    instance.run
  end
end
