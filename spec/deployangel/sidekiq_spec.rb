# frozen_string_literal: true

RSpec.describe DeployAngel::Sidekiq do
  let(:recorded) { [] }
  let(:middleware) { described_class::ServerMiddleware.new }

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_job) { |**attributes| recorded << attributes }
  end

  it "records native Sidekiq jobs with queue latency from millisecond timestamps" do
    job = { "class" => "HardWorker", "enqueued_at" => ((Time.now.to_f - 2) * 1000).to_i }
    middleware.call(nil, job, "default") { :done }

    expect(recorded.sole).to include(job_class: "HardWorker", failed: false)
    expect(recorded.sole[:queue_latency_ms]).to be_within(500).of(2_000)
  end

  it "accepts second-based timestamps from older Sidekiq versions" do
    expect(described_class.queue_latency_ms("enqueued_at" => Time.now.to_f - 3)).to be_within(500).of(3_000)
  end

  it "records and re-raises failures" do
    expect { middleware.call(nil, { "class" => "HardWorker" }, "default") { raise "boom" } }.to raise_error("boom")

    expect(recorded.sole).to include(failed: true)
  end

  it "skips ActiveJob wrappers, which the ActiveJob instrumentation records" do
    middleware.call(nil, { "class" => "Sidekiq::ActiveJob::Wrapper" }, "default") { :done }

    expect(recorded).to be_empty
  end
end
