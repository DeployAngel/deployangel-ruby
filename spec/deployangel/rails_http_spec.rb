# frozen_string_literal: true

RSpec.describe DeployAngel::Rails::Http do
  let(:recorded) { [] }

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_request) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error, options ] }
  end

  let(:exceptions) { [] }

  def call(app, env_overrides = {})
    middleware = described_class.new(app)
    middleware.call(Rack::MockRequest.env_for("/users/42", method: "GET").merge(env_overrides))
  end

  it "records the matched route pattern, never the raw path" do
    app = ->(_env) { [ 200, {}, [ "ok" ]] }
    call(app, "action_dispatch.route_uri_pattern" => "/users/:id(.:format)")

    expect(recorded.sole).to include(route_key: "GET /users/:id", status: 200, unhandled: false)
    expect(recorded.sole[:duration_ms]).to be >= 0
  end

  it "falls back to controller#action" do
    app = ->(_env) { [ 200, {}, [] ] }
    call(app, "action_dispatch.request.path_parameters" => { controller: "users", action: "show" })

    expect(recorded.sole[:route_key]).to eq("GET users#show")
  end

  it "marks exceptions rendered by Rails as unhandled" do
    app = ->(env) { env["action_dispatch.exception"] = RuntimeError.new; [ 500, {}, [] ] }
    call(app, "action_dispatch.route_uri_pattern" => "/users/:id(.:format)")

    expect(recorded.sole).to include(status: 500, unhandled: true)
  end

  it "does not count exceptions Rails renders as 4xx as unhandled" do
    app = ->(env) { env["action_dispatch.exception"] = StandardError.new("routing"); [ 404, {}, [] ] }
    call(app)

    expect(recorded.sole).to include(route_key: "GET unmatched", status: 404, unhandled: false)
  end

  it "records and re-raises exceptions that escape the stack" do
    app = ->(_env) { raise ArgumentError, "boom" }

    expect { call(app, "action_dispatch.route_uri_pattern" => "/users/:id") }.to raise_error(ArgumentError)
    expect(recorded.sole).to include(route_key: "GET /users/:id", status: 500, unhandled: true)
  end

  it "ignores unrouted successes such as static files but counts unrouted errors" do
    call(->(_env) { [ 200, {}, [] ] })
    call(->(_env) { [ 404, {}, [] ] })

    expect(recorded.map { |r| r[:route_key] }).to eq([ "GET unmatched" ])
  end

  it "passes straight through when not recording" do
    allow(DeployAngel).to receive(:recording?).and_return(false)
    call(->(_env) { [ 200, {}, [] ] }, "action_dispatch.route_uri_pattern" => "/x")

    expect(recorded).to be_empty
  end

  it "records rendered 5xx exceptions against the route" do
    error = RuntimeError.new("boom")
    app = ->(env) { env["action_dispatch.exception"] = error; [ 500, {}, [] ] }
    call(app, "action_dispatch.route_uri_pattern" => "/users/:id(.:format)")

    expect(exceptions.sole).to eq([ error, { source: "route:GET /users/:id" } ])
  end
end
