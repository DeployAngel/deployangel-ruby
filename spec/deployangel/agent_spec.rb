# frozen_string_literal: true

RSpec.describe DeployAngel::Agent do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14, 0, 10)) }
  let(:transport) { FakeTransport.new }
  let(:config) { active_config }

  def build_agent(environment: "production")
    described_class.new(config: config, environment: environment, env: { "DYNO" => "web.1" },
      transport: transport, clock: clock, framework: "rails", framework_version: "8.1.0").tap do |agent|
      allow(agent).to receive(:start_reporter)
    end
  end

  it "sends one Agent Protocol payload per completed minute" do
    agent = build_agent
    agent.record_request(route_key: "GET /products", status: 200, duration_ms: 84)
    clock.advance(60)

    expect(agent.flush).to eq(1)
    path, payload = transport.posts.sole
    expect(path).to eq("/api/v1/telemetry")
    expect(payload).to include(
      "protocol_version" => 1,
      "release" => { "version" => "v184", "commit" => "81ac27d", "source" => "config" },
      "period" => { "started_at" => "2026-09-30T14:00:00Z", "duration_seconds" => 60 }
    )
    expect(payload.dig("instance", "id")).to start_with("web.1:#{Process.pid}:")
    expect(payload.dig("http", "requests")).to eq(1)
    expect(payload["routes"].sole["key"]).to eq("GET /products")
  end

  it "does nothing when inactive" do
    agent = build_agent(environment: "development")
    agent.record_request(route_key: "GET /", status: 200, duration_ms: 1)
    clock.advance(60)

    expect(agent.flush).to eq(0)
    expect(transport.posts).to be_empty
  end

  it "keeps payloads for retry after network or server errors" do
    transport.results = [ DeployAngel::Transport::Result.new(:retry, 503, nil) ]
    agent = build_agent
    clock.advance(60)

    expect(agent.flush).to eq(0)
    expect(agent.flush).to eq(1)
    expect(transport.posts.map { |_, p| p["period"]["started_at"] }.uniq).to eq([ "2026-09-30T14:00:00Z" ])
  end

  it "drops rate-limited payloads and pauses for Retry-After" do
    transport.results = [ DeployAngel::Transport::Result.new(:drop, 429, 120) ]
    agent = build_agent
    clock.advance(60)
    agent.flush
    clock.advance(60)

    expect(agent.flush).to eq(0)
    expect(transport.posts.size).to eq(1)

    clock.advance(120)
    expect(agent.flush).to be >= 1
  end

  it "bounds the buffer when the endpoint is down" do
    transport.results = Array.new(100) { DeployAngel::Transport::Result.new(:retry, nil, nil) }
    config.max_queued_payloads = 3
    agent = build_agent
    clock.advance(600)

    agent.flush
    expect(agent.instance_variable_get(:@buffer).size).to be <= 3
  end

  it "queues unsent minutes as gzipped JSON, then sends them once the endpoint recovers" do
    transport.results = [ DeployAngel::Transport::Result.new(:retry, nil, nil) ]
    agent = build_agent
    agent.record_request(route_key: "GET /products", status: 200, duration_ms: 84)
    clock.advance(60)

    expect(agent.flush).to eq(0)
    queued = agent.instance_variable_get(:@buffer).shift
    expect(queued).to be_a(DeployAngel::Transport::Encoded)
    expect(JSON.parse(Zlib.gunzip(queued.bytes)).dig("http", "requests")).to eq(1)

    agent.instance_variable_get(:@buffer).unshift(queued)
    expect(agent.flush).to eq(1)
    expect(transport.posts.last.last.dig("http", "requests")).to eq(1)
  end

  it "never raises into the application" do
    agent = build_agent
    allow(agent.instance_variable_get(:@aggregator)).to receive(:record).and_raise("boom")

    expect { agent.record_request(route_key: "GET /", status: 200, duration_ms: 1) }.not_to raise_error
  end

  it "takes a fresh identity and empty counts after fork" do
    agent = build_agent
    agent.record_request(route_key: "GET /", status: 200, duration_ms: 1)
    parent_id = agent.instance.id

    agent.after_fork!
    clock.advance(60)
    agent.flush

    expect(agent.instance.id).not_to eq(parent_id)
    expect(transport.posts.sole.last.dig("http", "requests")).to eq(0)
  end

  it "flushes the minute in progress at shutdown" do
    agent = build_agent
    agent.record_request(route_key: "GET /", status: 200, duration_ms: 1)
    agent.shutdown

    expect(transport.posts.sole.last.dig("http", "requests")).to eq(1)
  end

  it "includes jobs and capabilities in the payload" do
    agent = build_agent
    agent.record_job(job_class: "SyncJob", duration_ms: 40, failed: true, queue_latency_ms: 10)
    clock.advance(60)
    agent.flush

    payload = transport.posts.sole.last
    expect(payload["jobs"]).to include("processed" => 1, "failed" => 1, "discarded" => 0)
    expect(payload["job_classes"].sole["key"]).to eq("SyncJob")
    expect(payload["capabilities"]).to eq(DeployAngel.capabilities)
  end

  it "records each exception object once, with a fingerprint and sources" do
    agent = described_class.new(config: config, environment: "production", env: {}, transport: transport,
      clock: clock, root: "/app")
    allow(agent).to receive(:start_reporter)
    error = NoMethodError.new("undefined method 'x' for nil")
    error.set_backtrace([ "/app/app/controllers/orders_controller.rb:7:in 'OrdersController#create'" ])

    agent.record_exception(error, source: "route:POST /orders")
    agent.record_exception(error, source: "route:POST /orders")
    clock.advance(60)
    agent.flush

    exception = transport.posts.sole.last["exceptions"].sole
    expect(exception).to include("exception_class" => "NoMethodError", "count" => 1, "fingerprint_version" => 1,
      "top_frame" => "app/controllers/orders_controller.rb#create", "sources" => { "route:POST /orders" => 1 })
    expect(exception["backtrace"]).to eq([ "app/controllers/orders_controller.rb#create" ])
  end
end
