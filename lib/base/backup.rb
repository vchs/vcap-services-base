require 'rubygems'
require 'bundler/setup'
require 'optparse'
require 'timeout'
require 'fileutils'
require 'yaml'
require 'pathname'
require 'steno'

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..')
require 'vcap/common'

$:.unshift File.dirname(__FILE__)
require 'abstract'

module VCAP
  module Services
    module Base
    end
  end
end

#@config_file Full path to config file
#@config Config hash for config file
#@logger
#@nfs_base NFS base path
class VCAP::Services::Base::Backup
  abstract :default_config_file
  abstract :backup_db

  def initialize
    @run_lock = Mutex.new
    @shutdown = false
    trap("TERM") { exit_fun }
    trap("INT") { exit_fun }
  end

  def script_file
    $0
  end

  def exit_fun
    @shutdown = true
    Thread.new do
      @run_lock.synchronize { exit }
    end
  end

  def single_app(&blk)
    if File.open(script_file).flock(File::LOCK_EX|File::LOCK_NB)
      blk.call
    else
      echo "Script #{ script_file } is already running",true
    end
  end

  def start
    single_app do
      echo "#{File.basename(script_file)} starts"
      @config_file = default_config_file
      parse_options

      echo "Load config file"
      # load conf file
      begin
        @config = YAML.load(File.open(@config_file))
      rescue => e
        echo "Could not read configuration file: #{e}",true
        exit
      end

      # Setup logger
      echo @config["logging"]
      logging_config = Steno::Config.from_hash(@config["logging"])
      Steno.init(logging_config)
      # Use running binary name for logger identity name.
      @logger = Steno.logger(File.basename(script_file))

      # Make pidfile
      if @config["pid"]
        pf = VCAP::PidFile.new(@config["pid"])
        pf.unlink_at_exit
      end

      echo "Check mount points"
      check_mount_points

      # make sure backup dir on nfs storage exists
      @nfs_base = @config["backup_base_dir"] + "/backups/" + @config["service_name"]
      echo "Check NFS base"
      if File.directory? @nfs_base
        echo @nfs_base + " exists"
      else
        echo @nfs_base + " does not exist, create it"
        begin
          FileUtils.mkdir_p @nfs_base
        rescue => e
          echo "Could not create dir on nfs!",true
          exit
        end
      end
      echo "Run backup task"
      @run_lock.synchronize { backup_db }
      echo "#{File.basename(script_file)} task is completed"
    end
  rescue => e
    echo "Error: #{e.message}\n #{e.backtrace}",true
  rescue Interrupt => it
    echo "Backup is interrupted!"
  end

  def get_dump_path(name, options={})
    name = name.sub(/^(mongodb|redis)-/,'')
    mode = options[:mode] || 0
    time = options[:time] || Time.now
    case mode
    when 1
      File.join(@config['backup_base_dir'], 'backups', @config['service_name'],name, time.to_i.to_s,@config['node_id'])
    else
      File.join(@config['backup_base_dir'], 'backups', @config['service_name'], name[0,2], name[2,2], name[4,2], name, time.to_i.to_s)
    end
  end

  def check_mount_points
    # make sure the backup base dir is mounted
    pn = Pathname.new(@config["backup_base_dir"])
    if !@tolerant && !pn.mountpoint?
      echo @config["backup_base_dir"] + " is not mounted, exit",true
      exit
    end
  end

  def echo(output, err=false)
    if err
      $stderr.puts(output) unless @logger
      @logger.error(output) if @logger
    else
      $stdout.puts(output) unless @logger
      @logger.info(output) if @logger
    end
  end

  def parse_options
    OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename(script_file)} [options]"
      opts.on("-c", "--config [ARG]", "Node configuration File") do |opt|
        @config_file = opt
      end
      opts.on("-h", "--help", "Help") do
        puts opts
        exit
      end
      opts.on("-t", "--tolerant",    "Tolerant mode") do
        @tolerant = true
      end
      more_options(opts)
    end.parse!
  end

  def more_options(opts)
  end
end

class CMDHandle

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
      rescue => e
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

