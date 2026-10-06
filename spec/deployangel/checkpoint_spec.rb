# frozen_string_literal: true

require "active_job"

RSpec.describe "Checkpoints" do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14, 0, 10)) }
  let(:aggregator) { DeployAngel::Aggregator.new(clock: clock) }

  # Leaves the capabilities other specs announced (such as "jobs") in place.
  around do |example|
    capabilities = DeployAngel.capabilities.dup
    example.run
  ensure
    DeployAngel.instance_variable_set(:@capabilities, capabilities)
  end

  def payload_for(period)
    DeployAngel::Protocol.telemetry(period, instance: DeployAngel::Instance.new(env: { "DYNO" => "web.1" }),
      release: DeployAngel::Release.new("v1", nil, "config"), runtime: {})
  end

  it "counts checkpoints per minute and sends them in the payload, always with http and job" do
    aggregator.record_checkpoint(name: "order.created")
    aggregator.record_checkpoint(name: "order.created", count: 2)
    aggregator.record_checkpoint(name: "webhook.stripe.processed")
    clock.advance(60)

    expect(payload_for(aggregator.drain.sole)["checkpoints"]).to contain_exactly(
      { "key" => "order.created", "count" => 3, "http" => 0, "job" => 0 },
      { "key" => "webhook.stripe.processed", "count" => 1, "http" => 0, "job" => 0 }
    )
  end

  it "splits each count by where it was recorded, leaving the rest as neither" do
    aggregator.record_checkpoint(name: "order.created", count: 3, context: :http)
    aggregator.record_checkpoint(name: "order.created", count: 2, context: :job)
    aggregator.record_checkpoint(name: "order.created")
    clock.advance(60)

    expect(payload_for(aggregator.drain.sole)["checkpoints"].sole)
      .to eq("key" => "order.created", "count" => 6, "http" => 3, "job" => 2)
  end

  it "folds names past the limit into one bucket that keeps where they were recorded" do
    stub_const("DeployAngel::Aggregator::MAX_CHECKPOINTS", 3)
    aggregator.record_checkpoint(name: "a", context: :http)
    aggregator.record_checkpoint(name: "b")
    aggregator.record_checkpoint(name: "c", context: :http)
    aggregator.record_checkpoint(name: "d", count: 2, context: :job)
    aggregator.record_checkpoint(name: "e")
    clock.advance(60)

    expect(payload_for(aggregator.drain.sole)["checkpoints"]).to eq([
      { "key" => "a", "count" => 1, "http" => 1, "job" => 0 },
      { "key" => "b", "count" => 1, "http" => 0, "job" => 0 },
      { "key" => "__other__", "count" => 4, "http" => 1, "job" => 2 }
    ])
  end

  it "ignores invalid names and counts without raising, and announces the capability" do
    expect(DeployAngel.checkpoint("")).to be_nil
    expect(DeployAngel.checkpoint("has spaces")).to be_nil
    expect(DeployAngel.checkpoint("order.created", count: 0)).to be_nil
    expect(DeployAngel.capabilities).not_to include("checkpoints")

    DeployAngel.checkpoint("order.created")
    expect(DeployAngel.capabilities).to include("checkpoints")
  end

  describe "where a checkpoint was recorded" do
    class CheckpointingJob < ActiveJob::Base
      self.queue_adapter = :inline
      def perform(name = "job.ran") = DeployAngel.checkpoint(name)
    end

    class FailingCheckpointJob < ActiveJob::Base
      self.queue_adapter = :inline
      def perform
        DeployAngel.checkpoint("job.failed")
        raise ArgumentError, "boom"
      end
    end

    let(:transport) { FakeTransport.new }
    let(:agent) do
      DeployAngel::Agent.new(config: active_config, environment: "production", env: { "DYNO" => "web.1" },
        transport: transport, clock: clock).tap { |agent| allow(agent).to receive(:start_reporter) }
    end
    let(:middleware) do
      Class.new(DeployAngel::Rack::Http) do
        private
          def route_pattern(_env) = "/orders"
      end
    end

    before(:all) do
      ActiveJob::Base.logger = Logger.new(nil)
      DeployAngel::Rails::ActiveJob.install
    end

    before { DeployAngel.instance_variable_set(:@agent, agent) }

    after do
      DeployAngel.instance_variable_set(:@agent, nil)
      Thread.current[DeployAngel::ExecutionContext::KEY] = nil
    end

    def request(&block)
      app = lambda do |_env|
        block.call
        [ 200, {}, [ "ok" ] ]
      end
      middleware.new(app).call(Rack::MockRequest.env_for("/orders", method: "POST"))
    end

    def sent_checkpoints
      clock.advance(60)
      agent.flush
      transport.posts.sole.last["checkpoints"].to_h { |entry| [ entry["key"], entry.except("key") ] }
    end

    it "counts one recorded while handling a request as http" do
      request { DeployAngel.checkpoint("order.created", count: 2) }

      expect(sent_checkpoints).to eq("order.created" => { "count" => 2, "http" => 2, "job" => 0 })
    end

    it "counts one recorded by an ActiveJob job as job" do
      CheckpointingJob.perform_now

      expect(sent_checkpoints).to eq("job.ran" => { "count" => 1, "http" => 0, "job" => 1 })
    end

    it "counts one recorded by a native Sidekiq job as job" do
      DeployAngel::Sidekiq::ServerMiddleware.new.call(nil, { "class" => "HardWorker" }, "default") do
        DeployAngel.checkpoint("sidekiq.ran")
      end

      expect(sent_checkpoints).to eq("sidekiq.ran" => { "count" => 1, "http" => 0, "job" => 1 })
    end

    it "counts one recorded outside a request or job as neither" do
      DeployAngel.checkpoint("console.ran")

      expect(sent_checkpoints).to eq("console.ran" => { "count" => 1, "http" => 0, "job" => 0 })
    end

    it "lets a job performed inline during a request win, then goes back to the request" do
      request do
        DeployAngel.checkpoint("order.created")
        CheckpointingJob.perform_now("receipt.sent")
        CheckpointingJob.perform_later("receipt.sent")
        DeployAngel.checkpoint("order.created")
      end
      DeployAngel.checkpoint("after.request")

      expect(sent_checkpoints).to eq(
        "order.created" => { "count" => 2, "http" => 2, "job" => 0 },
        "receipt.sent" => { "count" => 2, "http" => 0, "job" => 2 },
        "after.request" => { "count" => 1, "http" => 0, "job" => 0 }
      )
    end

    it "restores the context when a request, an inline job, or a Sidekiq job raises" do
      expect { request { raise "boom" } }.to raise_error("boom")
      expect(DeployAngel::ExecutionContext.current).to be_nil

      request do
        expect { FailingCheckpointJob.perform_now }.to raise_error(ArgumentError)
        DeployAngel.checkpoint("order.created")
      end
      expect(DeployAngel::ExecutionContext.current).to be_nil

      expect do
        DeployAngel::Sidekiq::ServerMiddleware.new.call(nil, { "class" => "HardWorker" }, "default") { raise "boom" }
      end.to raise_error("boom")
      expect(DeployAngel::ExecutionContext.current).to be_nil

      expect(sent_checkpoints).to eq(
        "job.failed" => { "count" => 1, "http" => 0, "job" => 1 },
        "order.created" => { "count" => 1, "http" => 1, "job" => 0 }
      )
    end

    it "keeps each thread's context to itself" do
      inside = Queue.new
      release = Queue.new
      thread = Thread.new do
        request do
          inside << true
          release.pop
        end
      end
      inside.pop
      DeployAngel.checkpoint("other.thread")
      release << true
      thread.join

      expect(sent_checkpoints).to eq("other.thread" => { "count" => 1, "http" => 0, "job" => 0 })
    end

    it "leaves the context alone when not recording" do
      DeployAngel.instance_variable_set(:@agent, nil)
      contexts = []
      request { contexts << DeployAngel::ExecutionContext.current }
      CheckpointingJob.perform_now

      expect(contexts).to eq([ nil ])
      expect(DeployAngel::ExecutionContext.current).to be_nil
    end
  end
end
