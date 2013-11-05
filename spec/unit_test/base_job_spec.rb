require "helper/job_spec_helper"

module VCAP::Services::Base::AsyncJob
  describe BaseJob do
    context "Send request to Gateway" do
      let(:mock_nats) { double("test_mock_nats") }
      let(:logger) { Logger.new(STDOUT) }

      before do
        ENV['WORKER_CONFIG'] = "{}"
        Config.logger = logger
        @base_job = BaseJob.new([])
        @base_job.instance_variable_set(:@config, { "mbus" => "" })
        NATS.should_receive(:connect).and_return do |&cb|
          cb.call(mock_nats)
        end
        mock_nats.should_receive(:unsubscribe).with(any_args())
      end

      it "should be able to send request through nats" do
        response = VCAP::Services::Internal::SimpleResponse.new
        response.success = true
        mock_nats.should_receive(:request).with(any_args()).and_return do |*args, &cb|
          cb.call(response.encode)
        end

        logger.should_receive(:info).with(/successfully received/)
        @base_job.send_msg("mysql.backups.create", {})
      end

      it "should be able to handle request timeout" do
        mock_nats.should_receive(:request).with(any_args())

        logger.should_receive(:error).with(/timeout/)
        @base_job.send_msg("mysql.backups.create", {})
      end
    end
  end
end
