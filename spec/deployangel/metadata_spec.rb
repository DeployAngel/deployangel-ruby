# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe DeployAngel::Rails::Metadata do
  FakeRoute = Struct.new(:verb, :spec, :defaults) do
    def path = Struct.new(:spec).new(spec)
  end

  let(:routes) do
    [ FakeRoute.new("GET", "/users/:id(.:format)", { controller: "users", action: "show" }),
      FakeRoute.new("GET|POST", "/password_resets(.:format)", { controller: "password_resets", action: "create" }),
      FakeRoute.new("GET", "/up(.:format)", { controller: "rails/health", action: "show" }) ]
  end
  let(:app) { Struct.new(:routes).new(Struct.new(:routes).new(routes)) }
  let(:config) { DeployAngel::Configuration.new({}).tap { |c| c.critical_flows = { password_reset: [ "POST /password_resets" ] } } }

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  end

  before { stub_const("Rails", Module.new { def self.env = "production" }) }

  def metadata
    described_class.new(app: app, config: config, root: @root)
  end

  it "lists routes as patterns with their controller, skipping framework routes" do
    expect(metadata.routes.map { |r| r["key"] }).to eq([ "GET /users/:id", "GET /password_resets", "POST /password_resets" ])
    expect(metadata.routes.first).to include("controller" => "users", "action" => "show")
  end

  it "reads Solid Queue recurring schedules for the current environment" do
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/recurring.yml"), <<~YAML)
      production:
        nightly_invoices:
          class: NightlyInvoiceJob
          schedule: at 3am every day
        cleanup:
          command: "Thing.cleanup"
          schedule: every hour
    YAML

    expect(metadata.schedules).to eq([
      { "key" => "nightly_invoices", "class" => "NightlyInvoiceJob", "schedule" => "at 3am every day", "source" => "solid_queue",
        "time_zone" => nil },
      { "key" => "cleanup", "class" => nil, "schedule" => "every hour", "source" => "solid_queue", "time_zone" => nil }
    ])
  end

  it "reports the time zone Solid Queue reads schedules in" do
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config/recurring.yml"), "nightly:\n  class: NightlyInvoiceJob\n  schedule: at 3am every day\n")
    stub_const("SolidQueue", Module.new { def self.time_zone = "Etc/UTC" })

    expect(metadata.schedules.sole).to include("time_zone" => "Etc/UTC")
  end

  it "digests application files by relative path, and the manifest hash changes with content" do
    FileUtils.mkdir_p(File.join(@root, "app/controllers"))
    file = File.join(@root, "app/controllers/users_controller.rb")
    File.write(file, "class UsersController; end")
    first = metadata.file_manifest

    File.write(file, "class UsersController; def show; end; end")
    second = metadata.file_manifest

    expect(first["files"].keys).to eq([ "app/controllers/users_controller.rb" ])
    expect(first["files"].values.first.length).to eq(16)
    expect(second["hash"]).not_to eq(first["hash"])
  end

  it "sends no digests when disabled" do
    config.file_digests = false
    expect(metadata.to_protocol["file_manifest"]).to eq("hash" => nil, "count" => 0, "truncated" => false)
  end

  it "includes critical flows from configuration" do
    expect(metadata.to_protocol["critical_flows"]).to eq("password_reset" => [ "POST /password_resets" ])
  end
end

RSpec.describe DeployAngel::Agent, "#send_metadata" do
  let(:transport) { FakeTransport.new }
  let(:agent) do
    described_class.new(config: active_config, environment: "production", env: {}, transport: transport,
      clock: FakeClock.new(Time.utc(2026, 9, 30, 14))).tap { |a| allow(a).to receive(:start_reporter) }
  end
  let(:metadata) do
    instance_double(DeployAngel::Rails::Metadata, to_protocol: { "routes" => [], "file_manifest" => { "hash" => "abc" } },
      files: { "app/x.rb" => "0123456789abcdef" })
  end

  before { agent.metadata = metadata }

  it "uploads files only when the cloud asks for them, and only once" do
    transport.results = [ DeployAngel::Transport::Result.new(:ok, 202, nil, { "manifest_needed" => true }) ]
    agent.send_metadata
    agent.send_metadata

    expect(transport.posts.map(&:first)).to eq([ "/api/v1/application_metadata" ] * 2)
    expect(transport.posts.first.last).not_to have_key("files")
    expect(transport.posts.last.last["files"]).to eq("app/x.rb" => "0123456789abcdef")
  end

  it "retries later when sending fails" do
    transport.results = [ DeployAngel::Transport::Result.new(:retry, 503, nil, nil) ]
    agent.send_metadata
    agent.send_metadata

    expect(transport.posts.size).to eq(2)
  end
end
