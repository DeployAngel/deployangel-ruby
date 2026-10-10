# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe "deployangel doctor" do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    File.write(File.join(@root, path), content)
  end

  def doctor(*argv, client: nil, env: {})
    DeployAngel::CLI.new([ "doctor", "--format=text", *argv ], env: env, stdout: stdout, stderr: stderr, client: client, root: @root).run
  end

  def setup_document(**overrides)
    { "app" => { "id" => 1, "name" => "shop", "environment" => "production" },
      "token" => { "scopes" => %w[verifications:read], "purpose" => "read" },
      "agent" => { "last_received_at" => "2026-10-09T11:59:00Z", "reporting" => true,
                   "processes" => [ { "host" => "web.1", "processes" => 2, "release" => "81ac27d" },
                                    { "host" => "worker.1", "processes" => 1, "release" => "81ac27d" } ] },
      "metadata" => { "routes" => 42, "job_classes" => 12, "schedules" => 2 },
      "scheduled_jobs" => [ { "label" => "NightlyInvoiceJob", "status" => "ran" }, { "label" => "SyncJob", "status" => "ran" } ],
      "warm_up_ends_at" => nil,
      "deployments" => { "count" => 3, "latest" => { "label" => "v12", "verdict" => "verified" } },
      "gaps" => [] }.merge(overrides.transform_keys(&:to_s))
  end

  before do
    write("Gemfile.lock", "GEM\n  specs:\n    deployangel (0.1.23)\n")
    write("config/application.rb", "")
    write("config/recurring.yml", "production:\n  nightly:\n    class: NightlyInvoiceJob\n    schedule: at 3am every day\n" \
                                  "  sync:\n    class: SyncJob\n    schedule: every hour\n")
  end

  it "checks this checkout and what DeployAngel has seen, and passes when nothing's wrong" do
    client = FakeClient.new.tap { |c| c.setup_document = setup_document }

    expect(doctor(client: client)).to eq(0)
    expect(stdout.string).to eq(<<~TEXT)
      DeployAngel doctor
        ✓ Agent: deployangel 0.1.23 in Gemfile.lock
        ✓ 2 scheduled jobs in this checkout (Solid Queue 2). config.recurring_jobs is read when the app runs.
        ✓ App: shop (production)
        ✓ Agent reporting from 3 processes (web.1 ×2, worker.1), release 81ac27d
        ✓ Reported: 42 routes, 12 job classes, 2 scheduled jobs
        · 3 deploys so far; the latest, v12, is verified
    TEXT
  end

  it "lists setup gaps with their fixes, and scheduled jobs needing attention, without failing" do
    client = FakeClient.new.tap do |c|
      c.setup_document = setup_document(
        scheduled_jobs: [ { "label" => "SyncJob", "status" => "overdue" } ],
        gaps: [ { "code" => "no_job_process", "title" => "No job has run since the agent started reporting", "fix" => "Give that process the settings." } ])
    end

    expect(doctor(client: client)).to eq(0)
    expect(stdout.string).to include(
      "! Reported: 42 routes, 12 job classes, 2 scheduled jobs, 1 needing attention (SyncJob overdue)",
      "! No job has run since the agent started reporting\n      Give that process the settings.")
  end

  it "says how production will know the release before the agent reports, from the deploy files here" do
    write("Dockerfile", "FROM ruby\nCMD [\"rails\", \"server\"]\n")
    client = FakeClient.new.tap do |c|
      c.setup_document = setup_document(agent: { "last_received_at" => nil, "reporting" => false, "processes" => [] }, metadata: nil,
        scheduled_jobs: nil, deployments: { "count" => 0, "latest" => nil })
    end

    doctor(client: client)
    expect(stdout.string).to include("! The agent hasn't reported yet",
      "· The Dockerfile doesn't set DEPLOYANGEL_REVISION; unless your platform passes the commit, releases won't be named by commit\n" \
      "      Run `deployangel install docker`")

    stdout.truncate(0)
    write(".do/app.yaml", "envs:\n  - key: DEPLOYANGEL_REVISION\n    value: ${_self.COMMIT_HASH}\n")
    doctor(client: client)
    expect(stdout.string).to include("✓ The DigitalOcean app spec passes the commit in DEPLOYANGEL_REVISION")
  end

  it "says when this checkout declares schedules the running agent hasn't reported" do
    client = FakeClient.new.tap { |c| c.setup_document = setup_document(metadata: { "routes" => 1, "job_classes" => 1, "schedules" => 0 }) }

    doctor(client: client)
    expect(stdout.string).to include("! This checkout declares 2 scheduled jobs; the running agent reported 0")
  end

  it "checks only this checkout without a token, and fails on a rejected token or a missing agent" do
    expect(doctor).to eq(0)
    expect(stdout.string).to include("! No token, so only this checkout was checked")

    stdout.truncate(0)
    rejected = FakeClient.new.tap { |c| c.setup_document = DeployAngel::Client::Unauthorized.new("HTTP 401") }
    expect(doctor(client: rejected)).to eq(5)
    expect(stdout.string).to include("✗ DeployAngel rejected the token")

    stdout.truncate(0)
    write("Gemfile.lock", "GEM\n  specs:\n    rails (8.1.0)\n")
    expect(doctor).to eq(5)
    expect(stdout.string).to include("✗ The agent isn't in the bundle")
  end

  it "reads either token, the CLI's or the agent's" do
    cli = DeployAngel::CLI.new([ "doctor" ], env: { "DEPLOYANGEL_TOKEN" => "da_live_agent" }, stdout: stdout, stderr: stderr, root: @root)
    expect(cli.send(:doctor_client).instance_variable_get(:@token)).to eq("da_live_agent")
  end

  it "says which release this process would report when run where the app runs, but not from a checkout's git HEAD" do
    client = FakeClient.new.tap { |c| c.setup_document = setup_document }

    doctor(client: client, env: { "DEPLOYANGEL_TOKEN" => "da_live_agent", "HEROKU_BUILD_COMMIT" => "81ac27d0", "HEROKU_RELEASE_VERSION" => "v12" })
    expect(stdout.string).to include("✓ Here, the agent would report release v12 (from heroku_dyno_metadata)")

    stdout.truncate(0)
    doctor(client: client, env: { "DEPLOYANGEL_TOKEN" => "da_live_agent" })
    expect(stdout.string).to include("! Here, the agent can't tell which release is running")

    stdout.truncate(0)
    doctor(client: client)
    expect(stdout.string).not_to include("Here, the agent")
  end

  it "writes the checks and the server's document as JSON" do
    client = FakeClient.new.tap { |c| c.setup_document = setup_document }
    DeployAngel::CLI.new(%w[doctor --format=json], stdout: stdout, stderr: stderr, client: client, root: @root).run

    json = JSON.parse(stdout.string)
    expect(json["checks"].first).to eq("status" => "ok", "message" => "Agent: deployangel 0.1.23 in Gemfile.lock")
    expect(json.dig("setup", "app", "name")).to eq("shop")
  end
end
