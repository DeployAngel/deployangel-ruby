# frozen_string_literal: true

RSpec.describe DeployAngel::Aggregator do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14, 0, 10)) }
  let!(:aggregator) { described_class.new(max_routes: 3, clock: clock) }

  it "accumulates requests into the current minute" do
    aggregator.record(route_key: "GET /products", status: 200, duration_ms: 84)
    aggregator.record(route_key: "GET /products", status: 500, duration_ms: 120, unhandled: true)
    aggregator.record(route_key: "GET /missing", status: 404, duration_ms: 5)
    clock.advance(60)

    period = aggregator.drain.sole
    expect(period.started_at).to eq(Time.utc(2026, 9, 30, 14, 0))
    expect(period.requests).to eq(3)
    expect(period.status_counts).to eq("500" => 1, "404" => 1)
    expect(period.unhandled_exceptions).to eq(1)
    expect(period.routes["GET /products"].requests).to eq(2)
  end

  it "records a request only under its route when it's left out of the totals" do
    aggregator.record(route_key: "GET /products", status: 200, duration_ms: 84)
    aggregator.record(route_key: "GET unmatched", status: 404, duration_ms: 2, in_totals: false)
    clock.advance(60)

    period = aggregator.drain.sole
    expect([ period.requests, period.status_counts, period.histogram.count ]).to eq([ 1, {}, 1 ])
    expect(period.routes["GET unmatched"].requests).to eq(1)
    expect(period.routes["GET unmatched"].status_counts).to eq("404" => 1)
  end

  it "does not drain the minute in progress unless asked" do
    aggregator.record(route_key: "GET /", status: 200, duration_ms: 1)

    expect(aggregator.drain).to be_empty
    expect(aggregator.drain(include_current: true).sole.requests).to eq(1)
  end

  it "emits empty periods for idle minutes so the process still reports its release" do
    clock.advance(180)

    periods = aggregator.drain
    expect(periods.map(&:started_at)).to eq([ Time.utc(2026, 9, 30, 14, 0), Time.utc(2026, 9, 30, 14, 1), Time.utc(2026, 9, 30, 14, 2) ])
    expect(periods.map(&:requests)).to eq([ 0, 0, 0 ])
  end

  it "never drains the same minute twice" do
    clock.advance(60)
    aggregator.drain
    clock.advance(60)

    expect(aggregator.drain.map(&:started_at)).to eq([ Time.utc(2026, 9, 30, 14, 1) ])
  end

  it "caps periods after a long pause" do
    clock.advance(3_600)

    expect(aggregator.drain(max_periods: 5).size).to eq(5)
  end

  it "folds routes beyond the cap into __other__" do
    %w[a b c d e].each { |route| aggregator.record(route_key: "GET /#{route}", status: 200, duration_ms: 1) }
    clock.advance(60)

    routes = aggregator.drain.sole.routes
    expect(routes.keys).to eq([ "GET /a", "GET /b", described_class::OTHER_ROUTE ])
    expect(routes[described_class::OTHER_ROUTE].requests).to eq(3)
  end

  it "accumulates job attempts per class, with discards counted separately" do
    aggregator.record_job(job_class: "SyncJob", duration_ms: 50, queue_latency_ms: 200)
    aggregator.record_job(job_class: "SyncJob", duration_ms: 70, failed: true)
    aggregator.record_discard(job_class: "SyncJob")
    clock.advance(60)

    period = aggregator.drain.sole
    expect([ period.jobs.processed, period.jobs.failed, period.jobs.discarded ]).to eq([ 2, 1, 1 ])
    expect(period.jobs.duration.count).to eq(2)
    expect(period.jobs.queue_latency.count).to eq(1)
    expect(period.job_classes["SyncJob"].processed).to eq(2)
  end
end
