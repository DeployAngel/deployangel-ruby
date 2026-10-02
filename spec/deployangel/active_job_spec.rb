# frozen_string_literal: true

require "active_job"

RSpec.describe DeployAngel::Rails::ActiveJob do
  class SucceedingJob < ActiveJob::Base
    def perform; end
  end

  class RaisingJob < ActiveJob::Base
    def perform = raise(ArgumentError, "boom")
  end

  class RetryingJob < ActiveJob::Base
    retry_on ArgumentError, attempts: 3, wait: 0
    def perform = raise(ArgumentError, "boom")
  end

  class DiscardingJob < ActiveJob::Base
    discard_on ArgumentError
    def perform = raise(ArgumentError, "boom")
  end

  let(:recorded) { [] }

  before(:all) do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = Logger.new(nil)
    described_class.install
  end

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_job) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error.class, options ] }
  end

  let(:exceptions) { [] }

  it "announces the jobs capability" do
    expect(DeployAngel.capabilities).to include("jobs")
  end

  it "records a successful attempt with duration and queue latency" do
    job = SucceedingJob.new
    job.enqueued_at = Time.now - 5
    job.perform_now

    expect(recorded.sole).to include(job_class: "SucceedingJob", failed: false, discarded: false)
    expect(recorded.sole[:queue_latency_ms]).to be_within(1_000).of(5_000)
  end

  it "records an unhandled failure" do
    expect { RaisingJob.perform_now }.to raise_error(ArgumentError)

    expect(recorded.sole).to include(job_class: "RaisingJob", failed: true, discarded: false)
  end

  it "records a failure that retry_on handled" do
    RetryingJob.perform_now

    expect(recorded.sole).to include(failed: true, discarded: false)
  end

  it "records a failed and discarded attempt when retries are exhausted, once" do
    job = RetryingJob.new
    # retry_on counts attempts per exception list; two have already failed.
    job.exception_executions = { "[ArgumentError]" => 2 }
    expect { job.perform_now }.to raise_error(ArgumentError)

    expect(recorded.sole).to include(failed: true, discarded: true)
  end

  it "records discard_on as failed and discarded" do
    DiscardingJob.perform_now

    expect(recorded.sole).to include(job_class: "DiscardingJob", failed: true, discarded: true)
  end

  it "records nothing when not recording" do
    allow(DeployAngel).to receive(:recording?).and_return(false)
    SucceedingJob.perform_now

    expect(recorded).to be_empty
  end

  it "records the exception for unhandled and retry-handled failures" do
    RetryingJob.perform_now
    expect { RaisingJob.perform_now }.to raise_error(ArgumentError)

    expect(exceptions).to eq([ [ ArgumentError, { source: "job_class:RetryingJob" } ],
                               [ ArgumentError, { source: "job_class:RaisingJob" } ] ])
  end
end
