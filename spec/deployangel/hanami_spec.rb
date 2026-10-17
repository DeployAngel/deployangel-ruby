# frozen_string_literal: true

# Runs with Hanami installed: HANAMI_VERSION=3.0 bundle exec rspec (CI runs
# the oldest and newest supported). Without it, these are skipped.
begin
  require "hanami"
rescue LoadError
  RSpec.describe "DeployAngel::Hanami" do
    it("needs Hanami (set HANAMI_VERSION)") { skip "Hanami isn't installed" }
  end
  return
end

require_relative "../fixtures/hanami_app/config/app"
require_relative "../fixtures/hanami_app/config/routes"

RSpec.describe DeployAngel::Hanami do
  let(:root) { File.expand_path("../fixtures/hanami_app", __dir__) }
  let(:recorded) { [] }
  let(:exceptions) { [] }

  before(:all) { Hanami.app.boot }

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_request) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error, options ] }
    # The fixture's action records one; announcing the capability would leak
    # into other specs.
    allow(DeployAngel).to receive(:checkpoint)
  end

  def request(path, method: "GET")
    env = Rack::MockRequest.env_for(path, method: method)
    status, _headers, body = Hanami.app.call(env)
    body.close if body.respond_to?(:close)
    status
  end

  describe "requests" do
    it "records each request by the pattern of the route it matched, scopes' and slices' prefixes included" do
      expect(request("/books/7")).to eq(200)
      request("/api/v1/books/8")
      request("/admin/reports/9")
      expect(request("/books", method: "POST")).to eq(201)

      expect(recorded.map { |r| r[:route_key] }).to eq([ "GET /books/:id", "GET /api/v1/books/:id", "GET /admin/reports/:id", "POST /books" ])
      expect(recorded.map { |r| r[:status] }).to eq([ 200, 200, 200, 201 ])
      expect(recorded).to all(include(unhandled: false, in_totals: true))
    end

    it "records an exception Hanami renders as an error page against its route, as unhandled" do
      expect(request("/boom")).to eq(500)

      expect(recorded.sole).to include(route_key: "GET /boom", status: 500, unhandled: true)
      error, options = exceptions.sole
      expect(error).to be_a(ArgumentError)
      expect(options).to eq(source: "route:GET /boom")
    end

    it "records a request no route matched as a 404 outside the totals, not as an exception, though Hanami raises one" do
      expect(request("/wp-login.php")).to eq(404)

      expect(recorded.sole).to include(route_key: "GET unmatched", status: 404, unhandled: false, in_totals: false)
      expect(exceptions).to be_empty
    end

    it "leaves out health checks at a conventional path" do
      request("/healthz")

      expect(recorded).to be_empty
    end

    it "counts checkpoints as recorded in a request" do
      contexts = []
      allow(DeployAngel).to receive(:checkpoint) { contexts << DeployAngel::ExecutionContext.current }
      request("/books/1")

      expect(contexts).to eq([ DeployAngel::ExecutionContext::HTTP ])
    end
  end

  describe "the resolver" do
    # The fixture installs twice; each request above is recorded once.
    it "builds on the resolver the app configured" do
      expect(Hanami.app.config.router.resolver.superclass).to eq(Bookshelf::Resolver)
      expect(DeployAngel::Hanami::Resolver.for(Hanami.app.config.router.resolver)).to eq(Hanami.app.config.router.resolver)
    end
  end

  describe "a raised exception's status" do
    def raised_status(config, error)
      DeployAngel::Hanami::Http.new(->(_env) {}, config).send(:raised_status, {}, error)
    end

    it "is the one Hanami renders it as, and 500 without error pages, when the exception reaches the server" do
      config = Hanami.app.config
      expect(raised_status(config, Hanami::Router::NotFoundError.new({}))).to eq(404)
      expect(raised_status(config, ArgumentError.new)).to eq(500)
      expect(raised_status(Struct.new(:render_errors).new(false), Hanami::Router::NotFoundError.new({}))).to eq(500)
      expect(raised_status(nil, ArgumentError.new)).to eq(500)
    end
  end

  describe DeployAngel::Hanami::Metadata do
    subject(:metadata) do
      described_class.new(app: Hanami.app, config: DeployAngel::Configuration.new.tap { |c| c.ignored_routes = [ "GET /status" ] },
        root: root, environment: "production")
    end

    it "lists the routes with each action and the files behind it, without HEAD, health checks, or ignored routes" do
      routes = metadata.routes.to_h { |route| [ route["key"], route ] }

      expect(routes.keys).to contain_exactly("GET /books/:id", "POST /books", "GET /boom", "GET /api/v1/books/:id", "GET /admin/reports/:id")
      expect(routes["GET /books/:id"]).to eq("key" => "GET /books/:id", "controller" => "Bookshelf::Actions::Books::Show",
        "files" => [ "app/actions/books/show.rb", "app/views/books/show.rb", "app/templates/books/show.html.erb" ])
      expect(routes["GET /admin/reports/:id"]).to include("controller" => "Admin::Actions::Reports::Show",
        "files" => [ "slices/admin/actions/reports/show.rb" ])
      expect(routes["POST /books"]["files"]).to eq([ "app/actions/books/create.rb" ])
    end

    it "digests the app's code in Hanami's layout, slices included" do
      files = metadata.files

      expect(files.keys).to include("app/actions/books/show.rb", "slices/admin/actions/reports/show.rb", "config/routes.rb")
    end

    it "lists nothing rather than raise when the routes can't be read" do
      allow(DeployAngel::Hanami::RouteTable).to receive(:new).and_raise(RuntimeError)

      expect(metadata.routes).to eq([])
    end
  end

  it "starts the agent naming Hanami, the app's environment and root, with its metadata" do
    expect(DeployAngel).to receive(:start).with(hash_including(framework: "hanami", framework_version: Hanami::VERSION,
      environment: Hanami.env.to_s, root: root, metadata: an_instance_of(DeployAngel::Hanami::Metadata)))

    DeployAngel::Hanami.start(Hanami.app)
  end
end
