# frozen_string_literal: true

RSpec.describe DeployAngel::Rack::Http do
  let(:recorded) { [] }
  let(:exceptions) { [] }

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_request) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error, options ] }
  end

  # A framework adapter is this small: name the route, and the base records
  # it. Nothing in this file sets an action_dispatch key or loads Rails, so a
  # Rails dependency that crept back into the base would fail here.
  let(:adapter) do
    Class.new(described_class) do
      private
        def route_pattern(env)
          env["test.route"]
        end
    end
  end

  def call(app, env_overrides = {}, middleware = adapter)
    middleware.new(app).call(Rack::MockRequest.env_for("/users/42", method: "GET").merge(env_overrides))
  end

  it "records the pattern an adapter names, never the raw path" do
    call(->(_env) { [ 200, {}, [ "ok" ] ] }, "test.route" => "/users/:id")

    expect(recorded.sole).to include(route_key: "GET /users/:id", status: 200, unhandled: false, in_totals: true)
    expect(recorded.sole[:duration_ms]).to be >= 0
  end

  it "leaves out health checks at a conventional path without a controller to ask about" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    %w[/up /health /healthz /statusz /api/livez].each { |path| call(app, "test.route" => path) }
    call(app, "test.route" => "/webhooks")

    expect(recorded.map { |request| request[:route_key] }).to eq([ "GET /webhooks" ])
  end

  it "leaves out routes the app ignores" do
    allow(DeployAngel).to receive(:configuration)
      .and_return(DeployAngel::Configuration.new({}).tap { |config| config.ignored_routes = [ "GET /metrics" ] })
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }
    call(app, "test.route" => "/metrics")
    call(app, "test.route" => "/users/:id")

    expect(recorded.map { |request| request[:route_key] }).to eq([ "GET /users/:id" ])
  end

  it "records and re-raises an exception that escapes the app" do
    expect { call(->(_env) { raise ArgumentError, "boom" }, "test.route" => "/users/:id") }
      .to raise_error(ArgumentError)

    expect(recorded.sole).to include(route_key: "GET /users/:id", status: 500, unhandled: true)
    expect(exceptions.sole.last).to eq(source: "route:GET /users/:id")
  end

  # Only a framework can say whether it caught something and rendered the
  # 500 itself. Without an adapter that answers, a 500 is still recorded,
  # but nothing is claimed about its cause.
  it "counts a 5xx as handled when the adapter reports no rendered exception" do
    call(->(_env) { [ 500, {}, [] ] }, "test.route" => "/users/:id")

    expect(recorded.sole).to include(status: 500, unhandled: false)
    expect(exceptions).to be_empty
  end

  it "surfaces an exception the adapter rendered itself" do
    error = RuntimeError.new("boom")
    rendering = Class.new(adapter) do
      private def rendered_exception(env) = env["test.exception"]
    end
    call(->(env) { env["test.exception"] = error; [ 500, {}, [] ] }, { "test.route" => "/x" }, rendering)

    expect(recorded.sole).to include(unhandled: true)
    expect(exceptions.sole).to eq([ error, { source: "route:GET /x" } ])
  end

  it "passes straight through when not recording" do
    allow(DeployAngel).to receive(:recording?).and_return(false)
    expect(call(->(_env) { [ 200, {}, [ "ok" ] ] }, "test.route" => "/x")).to eq([ 200, {}, [ "ok" ] ])
    expect(recorded).to be_empty
  end

  # The base names no routes on its own, so an app that mounts it without an
  # adapter still reports errors rather than nothing at all.
  describe "without an adapter" do
    it "ignores unrouted successes but counts unrouted errors as unmatched" do
      call(->(_env) { [ 200, {}, [] ] }, {}, described_class)
      call(->(_env) { [ 503, {}, [] ] }, {}, described_class)

      expect(recorded.map { |request| request.slice(:route_key, :status, :in_totals) })
        .to eq([ { route_key: "GET unmatched", status: 503, in_totals: true } ])
    end
  end
end
