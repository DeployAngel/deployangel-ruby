# frozen_string_literal: true

require "tmpdir"

RSpec.describe DeployAngel::CLI do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14)) }
  let(:sleeper) { ->(seconds) { clock.advance(seconds) } }

  # A fixed environment, so a CI system running these specs (GitHub Actions
  # sets GITHUB_SHA) doesn't change what the CLI detects.
  def run(*argv, client:, git_head: "81ac27d0000", env: {})
    described_class.new(argv, env: env, stdout: stdout, stderr: stderr, client: client, sleeper: sleeper,
      clock: clock, git_head: git_head).run
  end

  it "maps verdicts to exit codes" do
    { "verified" => 0, "failed" => 1, "inconclusive" => 2 }.each do |verdict, code|
      client = FakeClient.new(documents: [ verdict_document(state: "closed", verdict: verdict) ])
      expect(run("verify", "--format=json", client: client)).to eq(code)
    end
  end

  it "defaults to the git HEAD commit" do
    client = FakeClient.new(documents: [ verdict_document(state: "closed", verdict: "verified") ])
    run("verify", client: client)

    expect(client.calls.first).to eq([ :deployments, { commit: "81ac27d0000", version: nil, limit: 1 } ])
  end

  it "exits 3 without waiting while the verification is in progress" do
    client = FakeClient.new(documents: [ verdict_document(state: "observing") ])
    expect(run("verify", client: client)).to eq(3)
  end

  it "waits for a verdict, printing progress to stderr" do
    client = FakeClient.new(documents: [ verdict_document(state: "pending"), verdict_document(state: "observing"),
                                         verdict_document(state: "closed", verdict: "verified") ])

    expect(run("verify", "--wait", "--format=json", client: client)).to eq(0)
    expect(stderr.string).to include("v184: pending", "v184: observing", "v184: closed")
    expect(JSON.parse(stdout.string).dig("verification", "verdict")).to eq("verified")
  end

  it "returns at the initial check with --until initial, never as success" do
    ok = FakeClient.new(documents: [ verdict_document(state: "observing"),
                                     verdict_document(state: "observing", initial_check: { "result" => "no_problems_so_far" }) ])
    warn = FakeClient.new(documents: [ verdict_document(state: "observing", initial_check: { "result" => "warnings" }) ])

    expect(run("verify", "--wait", "--until=initial", client: ok)).to eq(6)
    expect(run("verify", "--wait", "--until=initial", client: warn)).to eq(7)
  end

  it "returns a failed verdict immediately even when waiting through watching" do
    client = FakeClient.new(documents: [ verdict_document(state: "closed", verdict: "failed") ])
    expect(run("verify", "--wait", "--until=closed", client: client)).to eq(1)
  end

  it "keeps waiting through watching with --until closed" do
    client = FakeClient.new(documents: [ verdict_document(state: "watching", verdict: "verified"),
                                         verdict_document(state: "closed", verdict: "verified") ])
    expect(run("verify", "--wait", "--until=closed", client: client)).to eq(0)
    expect(client.calls.count { |call| call.first == :verification }).to eq(2)
  end

  it "times out with exit 3 and the current document" do
    client = FakeClient.new(documents: [ verdict_document(state: "observing") ])

    expect(run("verify", "--wait", "--timeout=5m", "--format=json", client: client)).to eq(3)
    expect(stderr.string).to include("timed out")
    expect(clock.now).to eq(Time.utc(2026, 9, 30, 14, 5))
  end

  it "waits for the deployment to be registered, or exits 4 without --wait" do
    missing = FakeClient.new(deployments_list: [])
    expect(run("verify", client: missing)).to eq(4)

    appears = FakeClient.new(deployments_list: [], documents: [ verdict_document(state: "closed", verdict: "verified") ])
    sleeper_with_registration = ->(seconds) { clock.advance(seconds) && appears.deployments_list = [ { "id" => 42 } ] }
    code = described_class.new(%w[verify --wait], stdout: stdout, stderr: stderr, client: appears,
      sleeper: sleeper_with_registration, clock: clock, git_head: "81ac27d").run
    expect(code).to eq(0)
    expect(stderr.string).to include("to be registered")
  end

  it "renders a readable summary" do
    document = verdict_document(state: "closed", verdict: "failed")
    document["findings"] = [ { "signal" => "http_5xx_rate", "scope" => "application", "status" => "failing",
                               "baseline_value" => 0.002, "observed_value" => 0.068, "observed_n" => 2140 },
                             { "signal" => "missing_recurring_job", "scope" => "recurring_job:prune_history", "status" => "failing",
                               "baseline_value" => 86_400.0, "observed_value" => nil,
                               "threshold" => "expected by 08:15 UTC (declared schedule)" } ]
    document["exceptions"] = [ { "exception_class" => "NoMethodError", "top_frame" => "app/services/order_creator.rb#call",
                                 "count" => 8, "sources" => { "route:POST /orders" => 8 } } ]
    document["deployment"] = (document["deployment"] || {}).merge(
      "promoted_from" => { "environment" => "staging", "version" => "v57", "verdict" => "verified" })
    run("verify", "--format=text", client: FakeClient.new(documents: [ document ]))

    expect(stdout.string).to include("HTTP 5xx rate on application: 0.2% -> 6.8% (2140 samples)",
      "NoMethodError in app/services/order_creator.rb#call (8x) route:POST /orders", "Verdict: failed",
      "Promoted from staging v57 (cleared)",
      "Recurring job on recurring_job:prune_history: didn't run, expected by 08:15 UTC (declared schedule)")
    expect(stdout.string).not_to include("8640000")
  end

  it "adds the verdict to the GitHub Actions job summary" do
    document = verdict_document(state: "closed", verdict: "failed")
    document["findings"] = [ { "signal" => "p95_latency", "scope" => "route:GET /a|b", "status" => "failing",
                               "baseline_value" => 120.0, "observed_value" => 480.0, "observed_n" => 900 },
                             { "signal" => "job_failure_rate", "scope" => "application", "status" => "pass" } ]
    document["exceptions"] = [ { "exception_class" => "KeyError", "top_frame" => "app/jobs/sync_job.rb#perform", "count" => 3 } ]

    Dir.mktmpdir do |dir|
      path = File.join(dir, "summary.md")
      code = run("verify", "--format=json", client: FakeClient.new(documents: [ document ]), env: { "GITHUB_STEP_SUMMARY" => path })

      expect(code).to eq(1)
      summary = File.read(path)
      expect(summary).to include("### DeployAngel: v184 failed", "| failing | p95 latency on route:GET /a\\|b: 120 ms -> 480 ms (900 samples) |",
        "**New exceptions**", "- KeyError in app/jobs/sync_job.rb#perform (3x)",
        "[Open in DeployAngel](https://app.deployangel.com/apps/1/deployments/42)")
      expect(summary).not_to include("Job failure rate")
      expect(JSON.parse(stdout.string).dig("verification", "verdict")).to eq("failed")
    end
  end

  it "says in the job summary when an initial check isn't a clearance, or no deployment was found" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "summary.md")
      ok = FakeClient.new(documents: [ verdict_document(state: "observing", initial_check: { "result" => "no_problems_so_far" }) ])
      run("verify", "--until=initial", client: ok, env: { "GITHUB_STEP_SUMMARY" => path })
      run("verify", client: FakeClient.new(deployments_list: []), env: { "GITHUB_STEP_SUMMARY" => path })

      expect(File.read(path)).to include("### DeployAngel: v184 has no problems so far, not cleared yet",
        "Initial check: no problems so far. Not cleared yet.", "### DeployAngel: no deployment found for 81ac27d0000")
    end
  end

  it "still exits with the verdict when the job summary can't be written" do
    client = FakeClient.new(documents: [ verdict_document(state: "closed", verdict: "verified") ])
    code = run("verify", "--format=json", client: client, env: { "GITHUB_STEP_SUMMARY" => "/nonexistent/summary.md" })

    expect(code).to eq(0)
    expect(stderr.string).to include("couldn't write the job summary")
  end

  it "registers deployments and reports checks against the current commit" do
    client = FakeClient.new
    expect(run("release", "--version=v185", client: client)).to eq(0)
    expect(run("check", "--name=smoke", "--status=pass", "--covers=password_reset", client: client)).to eq(0)

    expect(client.calls).to include([ :register, { commit: "81ac27d0000", version: "v185", kind: nil, provider: nil, source_url: nil } ],
      [ :check, "commit:81ac27d0000", { name: "smoke", status: "pass", covers: [ "password_reset" ], details_url: nil } ])
  end

  it "fills in the commit, label, provider, and run link inside GitHub Actions, even without a git checkout" do
    client = FakeClient.new
    env = { "DEPLOYANGEL_API_TOKEN" => "t", "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => "abc1234def5678", "GITHUB_RUN_NUMBER" => "12",
            "GITHUB_RUN_ID" => "99", "GITHUB_SERVER_URL" => "https://github.com", "GITHUB_REPOSITORY" => "acme/shop" }
    code = described_class.new(%w[release], env: env, stdout: stdout, stderr: stderr, client: client, git_head: false).run

    expect(code).to eq(0)
    expect(client.calls.last).to eq([ :register, { commit: "abc1234def5678", version: "run-12", kind: nil,
      provider: "github_actions", source_url: "https://github.com/acme/shop/actions/runs/99" } ])

    described_class.new(%w[release --version=2026.09.30 --provider=manual], env: env, stdout: stdout, stderr: stderr, client: client, git_head: false).run
    expect(client.calls.last.last).to include(version: "2026.09.30", provider: "manual", commit: "abc1234def5678")
  end

  it "registers Kamal's release from a post-deploy hook" do
    client = FakeClient.new
    env = { "DEPLOYANGEL_API_TOKEN" => "t", "KAMAL_VERSION" => "abc1234def5678", "KAMAL_COMMAND" => "deploy" }
    described_class.new(%w[release], env: env, stdout: stdout, stderr: stderr, client: client, git_head: false).run

    expect(client.calls.last).to eq([ :register, { commit: "abc1234def5678", version: nil, kind: nil, provider: "kamal", source_url: nil } ])
  end

  describe "install kamal" do
    around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

    def install = described_class.new(%w[install kamal], stdout: stdout, stderr: stderr, root: @root).run

    it "writes an executable post-deploy hook that registers each deploy" do
      expect(install).to eq(0)

      hook = File.join(@root, ".kamal/hooks/post-deploy")
      expect(File.read(hook)).to include("bundle exec deployangel release || true")
      expect(File.executable?(hook)).to be(true)
      expect(stdout.string).to include("Created .kamal/hooks/post-deploy", "DEPLOYANGEL_API_TOKEN")
    end

    it "leaves an existing hook alone and says what to add" do
      FileUtils.mkdir_p(File.join(@root, ".kamal/hooks"))
      File.write(File.join(@root, ".kamal/hooks/post-deploy"), "#!/bin/sh\necho deployed\n")

      expect(install).to eq(0)
      expect(File.read(File.join(@root, ".kamal/hooks/post-deploy"))).to eq("#!/bin/sh\necho deployed\n")
      expect(stdout.string).to include("already exists. Add this line to it:", "bundle exec deployangel release || true")
    end
  end

  it "reports usage and auth problems with exit 5" do
    expect(run("verify", "--until=never", client: FakeClient.new)).to eq(5)
    expect(run("check", "--name=x", client: FakeClient.new)).to eq(5)
    expect(described_class.new(%w[verify], stdout: stdout, stderr: stderr, env: {}, git_head: "abc1234").run).to eq(5)
    expect(stderr.string).to include("DEPLOYANGEL_API_TOKEN is not set")
  end
end
