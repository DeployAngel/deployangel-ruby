# frozen_string_literal: true

# Runs with Sinatra installed: SINATRA_VERSION=4.2 bundle exec rspec (CI runs
# the oldest and newest supported). Without it, these are skipped.
begin
  require "sinatra/base"
rescue LoadError
  RSpec.describe "DeployAngel::Sinatra" do
    it("needs Sinatra (set SINATRA_VERSION)") { skip "Sinatra isn't installed" }
  end
  return
end

require "deployangel/sinatra"
require "rack/builder"

module SinatraSpec
  # Production settings: Sinatra rescues exceptions and renders error pages.
  class Inner < Sinatra::Base
    set :environment, :production
    register DeployAngel::Sinatra
    get("/inner/:id") { "inner" }
  end

  class Books < Sinatra::Base
    set :environment, :production
    register DeployAngel::Sinatra
    register DeployAngel::Sinatra
    use Inner

    get("/books/:id") do
      DeployAngel.checkpoint("book.viewed")
      "book"
    end
    get("/books/:id/related") { pass }
    get("/books/*") { "fallback" }
    post("/books") { status 201 }
    get("/boom") { raise ArgumentError, "Book 42 exploded" }
    get("/refused") { halt 422, "no" }
    get("/healthz") { "ok" }
    get("/status") { "ok" }
  end

  App = Rack::Builder.new do
    map("/api") { run Books }
    run Books
  end
end

RSpec.describe DeployAngel::Sinatra do
  let(:recorded) { [] }
  let(:exceptions) { [] }
  let(:checkpoints) { [] }

  before do
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_request) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error, options ] }
    allow(DeployAngel).to receive(:checkpoint) { checkpoints << DeployAngel::ExecutionContext.current }
  end

  def request(path, method: "GET")
    status, _headers, body = SinatraSpec::App.call(Rack::MockRequest.env_for(path, method: method))
    body.close if body.respond_to?(:close)
    status
  end

  describe "requests" do
    it "records each request by the pattern of the route it ran, with the app's mount point" do
      expect(request("/books/7")).to eq(200)
      request("/api/books/8")
      expect(request("/books", method: "POST")).to eq(201)

      expect(recorded.map { |r| r[:route_key] }).to eq([ "GET /books/:id", "GET /api/books/:id", "POST /books" ])
      expect(recorded).to all(include(unhandled: false, in_totals: true))
      expect(checkpoints).to eq([ DeployAngel::ExecutionContext::HTTP ] * 2)
    end

    it "names a request after the route that handled it when one passes" do
      request("/books/7/related")

      expect(recorded.sole[:route_key]).to eq("GET /books/*")
    end

    it "records a request once when it passes through an app the app uses as middleware" do
      expect(request("/inner/3")).to eq(200)
      request("/books/1")

      expect(recorded.map { |r| r[:route_key] }).to eq([ "GET /inner/:id", "GET /books/:id" ])
    end

    it "records an exception Sinatra renders as an error page against its route, as unhandled" do
      expect(request("/boom")).to eq(500)

      expect(recorded.sole).to include(route_key: "GET /boom", status: 500, unhandled: true)
      error, options = exceptions.sole
      expect(error).to be_a(ArgumentError)
      expect(options).to eq(source: "route:GET /boom")
    end

    it "records a request no route matched as a 404 outside the totals, and a halt with its status" do
      expect(request("/wp-login.php")).to eq(404)
      expect(request("/refused")).to eq(422)

      expect(recorded.first).to include(route_key: "GET unmatched", status: 404, unhandled: false, in_totals: false)
      expect(recorded.last).to include(route_key: "GET /refused", status: 422, unhandled: false)
      expect(exceptions).to be_empty
    end

    it "leaves out health checks at a conventional path" do
      request("/healthz")

      expect(recorded).to be_empty
    end
  end

  describe DeployAngel::Sinatra::Metadata do
    # The fixture mounts Books at / and at /api; requests in other examples
    # teach the extension the /api mount.
    before { DeployAngel::Sinatra.mounts.clear }

    subject(:metadata) do
      described_class.new(config: DeployAngel::Configuration.new.tap { |c| c.ignored_routes = [ "GET /status" ] },
        root: File.expand_path("../..", __dir__), environment: "production")
    end

    it "lists every app's routes with the file each is defined in, without HEAD, health checks, or ignored routes" do
      routes = metadata.routes.to_h { |route| [ route["key"], route ] }

      expect(routes.keys).to include("GET /books/:id", "POST /books", "GET /boom", "GET /inner/:id")
      expect(routes.keys).not_to include("HEAD /books/:id", "GET /healthz", "GET /status")
      expect(routes["GET /books/:id"]["files"]).to eq([ "spec/deployangel/sinatra_spec.rb" ])
    end

    it "names a mounted app's routes with its mount point, once a request has shown it" do
      expect(metadata.routes.map { |r| r["key"] }).to include("GET /books/:id")

      request("/api/books/1")
      expect(metadata.routes.map { |r| r["key"] }).to include("GET /api/books/:id")
    end

    it "digests a typical Sinatra layout" do
      expect(metadata.digest_globs).to include("*.rb", "*.ru", "lib/**/*", "views/**/*", "Gemfile.lock")
    end
  end

  it "starts the agent naming Sinatra and the app's environment, with its metadata" do
    expect(DeployAngel).to receive(:start).with(hash_including(framework: "sinatra", framework_version: Sinatra::VERSION,
      environment: "production", root: Dir.pwd, metadata: an_instance_of(DeployAngel::Sinatra::Metadata)))

    DeployAngel::Sinatra.start(SinatraSpec::Books)
  end
end
