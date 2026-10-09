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

  describe "exercise" do
    let(:plan) do
      exercise_plan.merge("items" => exercise_plan["items"] + [
        { "kind" => "route", "key" => "GET /products", "runs" => 1, "runs_needed" => 3, "mutating" => false },
        { "kind" => "route", "key" => "GET /about", "runs" => 0, "mutating" => false },
        { "kind" => "route", "key" => "GET /items/<int:pk>/", "runs" => 0, "mutating" => false }
      ])
    end
    let(:document) { verdict_document(state: "observing").merge("exercise_plan" => plan) }
    let(:sent) { [] }

    def exercise(*argv, client:, answer: 200)
      described_class.new([ "exercise", *argv ], env: {}, stdout: stdout, stderr: stderr, client: client, sleeper: sleeper,
        clock: clock, git_head: "81ac27d0000", requester: ->(url) { sent << url && answer }).run
    end

    it "sends the plan's read-only requests from here, spreads the request shortfall, and records what it sent" do
      client = FakeClient.new(documents: [ document ])
      expect(exercise("--url=https://shop.example.com/", client: client)).to eq(0)

      # 12 of 30 requests: 18 more, 2 + 1 of them by the routes' own runs needed.
      expect(sent.tally).to eq("https://shop.example.com/products" => 10, "https://shop.example.com/about" => 8)
      exercise_call = client.calls.find { |call| call.first == :exercise }
      expect(exercise_call[1]).to eq(42)
      expect(exercise_call[2][:routes]).to eq([
        { "key" => "GET /products", "requests" => 10, "statuses" => { "2xx" => 10 } },
        { "key" => "GET /about", "requests" => 8, "statuses" => { "2xx" => 8 } }
      ])
      expect(exercise_call[2][:skipped]).to eq([
        { "key" => "GET /orders/:id", "reason" => "needs a path parameter" },
        { "key" => "POST /password_resets", "reason" => "changes data" },
        { "key" => "GET /items/<int:pk>/", "reason" => "needs a path parameter" }
      ])
      expect(stdout.string).to include("Sent 18 requests to https://shop.example.com/", "GET /products ×10: 10 2xx",
        "POST /password_resets (changes data)", "Recorded on the release.")
    end

    it "sends nothing on a dry run, and caps the requests it sends" do
      client = FakeClient.new(documents: [ document ])
      exercise("--url=https://shop.example.com", "--dry-run", "--max-requests=5", client: client)

      expect(sent).to be_empty
      expect(client.calls.map(&:first)).not_to include(:exercise)
      expect(stdout.string).to include("Would send 5 requests:", "https://shop.example.com/products ×")
    end

    it "stops when the app doesn't answer, and says so" do
      client = FakeClient.new(documents: [ document ])
      expect(exercise("--url=https://shop.example.com", client: client, answer: nil)).to eq(5)

      expect(sent.size).to eq(DeployAngel::Exerciser::MAX_CONSECUTIVE_ERRORS)
      expect(stdout.string).to include("Stopped early: https://shop.example.com isn't answering.")
    end

    it "sends nothing for a release with nothing to exercise, and needs the production URL" do
      cleared = verdict_document(state: "closed", verdict: "verified").merge("exercise_plan" => { "status" => "nothing_needed", "summary" => "Cleared." })
      expect(exercise("--url=https://shop.example.com", client: FakeClient.new(documents: [ cleared ]))).to eq(0)
      expect(stdout.string).to include("Nothing to exercise. Cleared.")
      expect(sent).to be_empty

      expect(exercise("--url=shop.example.com", client: FakeClient.new(documents: [ document ]))).to eq(5)
      expect(stderr.string).to include("exercise needs --url")
    end
  end

  describe "plan" do
    let(:document) { verdict_document(state: "observing").merge("exercise_plan" => exercise_plan) }

    it "says what's short and what to exercise, flagging routes that change data" do
      expect(run("plan", "--format=text", client: FakeClient.new(documents: [ document ]))).to eq(0)

      text = stdout.string
      expect(text).to include("v184: Not cleared yet.", "requests: 12 of 30 (low-traffic rule)",
        "routes run 3+ times: 1 of the 3 needed (3 normally active)",
        "GET /orders/:id (normally active, run 1 of 3)", "POST /password_resets (changed in this release, not run yet) [changes data]",
        "InvoiceMailer (normally active, runs when the app starts it)", "Use a test account, or ask first",
        %(Then report it: deployangel check --name="exercise plan"))
      # What clearance waits on comes first; the rest is only worth running.
      needed = text.index("Needed to clear")
      also = text.index("Also worth running, not needed to clear")
      expect(needed).to be < text.index("InvoiceMailer")
      expect(text.index("InvoiceMailer")).to be < also
      expect(also).to be < text.index("POST /password_resets")
    end

    it "counts normally active items as needed from a server that doesn't say" do
      plan = exercise_plan.merge("items" => exercise_plan["items"].map { |item| item.except("needed") })
      run("plan", "--format=text", client: FakeClient.new(documents: [ verdict_document(state: "observing").merge("exercise_plan" => plan) ]))

      text = stdout.string
      expect(text.index("GET /orders/:id")).to be < text.index("Also worth running")
    end

    it "prints the deployment and plan as JSON for agents" do
      run("plan", "--format=json", client: FakeClient.new(documents: [ document ]))

      json = JSON.parse(stdout.string)
      expect(json.keys).to eq(%w[deployment exercise_plan])
      expect(json.dig("exercise_plan", "status")).to eq("exercisable")
    end

    it "says plainly when the server doesn't return plans yet, or the deployment isn't found" do
      run("plan", "--format=text", client: FakeClient.new(documents: [ verdict_document(state: "observing") ]))
      expect(stdout.string).to include("No exercise plan in this response; update the server.")

      expect(run("plan", client: FakeClient.new(deployments_list: []))).to eq(4)
    end

    it "adds the first items to verify's output and the GitHub job summary" do
      Dir.mktmpdir do |dir|
        summary = File.join(dir, "summary.md")
        run("verify", "--format=text", client: FakeClient.new(documents: [ document ]), env: { "GITHUB_STEP_SUMMARY" => summary })

        expect(stdout.string).to include("To clear sooner, exercise (deployangel plan for details):", "GET /orders/:id (normally active, run 1 of 3)")
        expect(stdout.string).not_to include("POST /password_resets")
        expect(File.read(summary)).to include("**To clear sooner, exercise (deployangel plan for details)**", "- InvoiceMailer")
        expect(File.read(summary)).not_to include("POST /password_resets")
      end
    end

    it "leaves verify's output alone when there's nothing to exercise" do
      warm = verdict_document(state: "observing").merge("exercise_plan" => exercise_plan(status: "warm_up"))
      run("verify", "--format=text", client: FakeClient.new(documents: [ warm ]))

      expect(stdout.string).not_to include("To clear sooner")
    end
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

  describe "install agents" do
    around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

    def install = described_class.new(%w[install agents], stdout: stdout, stderr: stderr, root: @root).run
    def read(path) = File.read(File.join(@root, path))
    def write(path, content) = FileUtils.mkdir_p(File.dirname(File.join(@root, path))) && File.write(File.join(@root, path), content)

    it "sets up Claude Code, Cursor, and Codex in a project that has none of their files" do
      expect(install).to eq(0)

      server = { "command" => "bundle", "args" => %w[exec deployangel mcp] }
      expect(JSON.parse(read(".mcp.json"))).to eq("mcpServers" => { "deployangel" => server })
      expect(JSON.parse(read(".cursor/mcp.json"))).to eq("mcpServers" => { "deployangel" => server })
      expect(read(".codex/config.toml")).to eq(<<~TOML)
        [mcp_servers.deployangel]
        command = "bundle"
        args = ["exec", "deployangel", "mcp"]
        env_vars = ["DEPLOYANGEL_API_TOKEN", "DEPLOYANGEL_URL"]
      TOML
      expect(read("AGENTS.md")).to eq(described_class::AGENT_INSTRUCTIONS)
      expect(read("AGENTS.md")).to include("bundle exec deployangel verify --commit=<sha> --wait --until=initial")
      expect(read("CLAUDE.md")).to eq("@AGENTS.md\n")
      expect(stdout.string).to include("Created .mcp.json", "Created .cursor/mcp.json", "Created .codex/config.toml",
        "Created AGENTS.md", "Created CLAUDE.md", "DEPLOYANGEL_API_TOKEN", "Never put it in these files")
    end

    it "adds to existing files without disturbing them, and changes nothing when run again" do
      write(".mcp.json", JSON.generate("mcpServers" => { "github" => { "command" => "gh-mcp" } }))
      write(".codex/config.toml", "model = \"gpt-5\"\n")
      write("AGENTS.md", "# Project\n\nRun the tests first.\n")
      write("CLAUDE.md", "# Claude\n")

      install
      expect(JSON.parse(read(".mcp.json"))["mcpServers"].keys).to eq(%w[github deployangel])
      expect(read(".codex/config.toml")).to start_with("model = \"gpt-5\"\n\n[mcp_servers.deployangel]\n")
      expect(read("AGENTS.md")).to eq("# Project\n\nRun the tests first.\n\n#{described_class::AGENT_INSTRUCTIONS}")
      expect(read("CLAUDE.md")).to eq("# Claude\n\n#{described_class::AGENT_INSTRUCTIONS}")

      files = %w[.mcp.json .cursor/mcp.json .codex/config.toml AGENTS.md CLAUDE.md].to_h { |path| [ path, read(path) ] }
      stdout.truncate(0)
      install
      expect(files.to_h { |path, _| [ path, read(path) ] }).to eq(files)
      expect(stdout.string).to include("already has a deployangel MCP server", "already has DeployAngel's instructions")
    end

    it "replaces an older version of its instructions, and leaves a CLAUDE.md that imports AGENTS.md alone" do
      write("AGENTS.md", "# Project\n\n#{described_class::AGENTS_START}\nold advice\n#{described_class::AGENTS_END}\n\n## Style\n")
      write("CLAUDE.md", "@AGENTS.md\n")

      install
      expect(read("AGENTS.md")).to eq("# Project\n\n#{described_class::AGENT_INSTRUCTIONS}\n## Style\n")
      expect(read("CLAUDE.md")).to eq("@AGENTS.md\n")
      expect(stdout.string).to include("Updated DeployAngel's instructions in AGENTS.md.")
    end

    it "names the targets when given an unknown one" do
      expect(described_class.new(%w[install heroku], stdout: stdout, stderr: stderr, root: @root).run).to eq(5)
      expect(stderr.string).to include("deployangel install kamal, docker, or agents")
    end

    it "leaves a config file it can't read for you to edit" do
      write(".mcp.json", "{ not json")

      expect(install).to eq(0)
      expect(read(".mcp.json")).to eq("{ not json")
      expect(stdout.string).to include("Couldn't read .mcp.json, so it's unchanged.", %(command "bundle", args ["exec","deployangel","mcp"]))
    end
  end

  describe "install docker" do
    around { |example| Dir.mktmpdir { |root| @root = root; example.run } }

    let(:dockerfile) { File.join(@root, "Dockerfile") }
    let(:lines) do
      [ "# The commit this image runs, for DeployAngel. Build with --build-arg GIT_SHA=$(git rev-parse HEAD).\n",
        "ARG GIT_SHA\n", "ENV DEPLOYANGEL_REVISION=$GIT_SHA\n" ].join
    end

    def install = described_class.new(%w[install docker], stdout: stdout, stderr: stderr, root: @root).run

    it "adds the revision at the end of the last stage, before its CMD, so earlier layers stay cached" do
      File.write(dockerfile, <<~DOCKERFILE)
        FROM ruby:3.4 AS build
        RUN bundle install
        CMD ["build"]

        FROM ruby:3.4-slim
        COPY --from=build /rails /rails
        RUN apt-get install -y \\
            libpq5
        ENTRYPOINT ["/rails/bin/docker-entrypoint"]

        # Start the server
        EXPOSE 80
        # Thrust in front of Puma
        CMD ["./bin/thrust", "./bin/rails", "server"]
      DOCKERFILE

      expect(install).to eq(0)
      expect(File.read(dockerfile)).to end_with("EXPOSE 80\n#{lines}# Thrust in front of Puma\nCMD [\"./bin/thrust\", \"./bin/rails\", \"server\"]\n")
      expect(File.read(dockerfile).scan("ARG GIT_SHA").size).to eq(1)
      expect(stdout.string).to include("docker build --build-arg GIT_SHA=$(git rev-parse HEAD) .",
        "fly deploy --build-arg GIT_SHA=$(git rev-parse HEAD)", "build-args: GIT_SHA=${{ github.sha }}", "KAMAL_VERSION")
    end

    it "goes before the first of the CMD and ENTRYPOINT lines that end the stage" do
      File.write(dockerfile, "FROM ruby:3.4\nUSER app\nENTRYPOINT [\"bin/entry\"]\nCMD [\"bin/web\"]\n")

      install
      expect(File.read(dockerfile)).to eq("FROM ruby:3.4\nUSER app\n#{lines}ENTRYPOINT [\"bin/entry\"]\nCMD [\"bin/web\"]\n")
    end

    it "appends to a Dockerfile whose last stage has no CMD or ENTRYPOINT" do
      File.write(dockerfile, "FROM ruby:3.4\nCOPY . /app")

      expect(install).to eq(0)
      expect(File.read(dockerfile)).to eq("FROM ruby:3.4\nCOPY . /app\n\n#{lines}")
    end

    it "changes nothing when the Dockerfile already sets DEPLOYANGEL_REVISION" do
      File.write(dockerfile, "FROM ruby:3.4\nENV DEPLOYANGEL_REVISION=abc\n")

      expect(install).to eq(0)
      expect(File.read(dockerfile)).to eq("FROM ruby:3.4\nENV DEPLOYANGEL_REVISION=abc\n")
      expect(stdout.string).to include("already sets DEPLOYANGEL_REVISION")
    end

    it "fails without a Dockerfile" do
      expect(install).to eq(5)
      expect(stderr.string).to include("no Dockerfile")
      expect(File.exist?(dockerfile)).to be(false)
    end
  end

  it "reports usage and auth problems with exit 5" do
    expect(run("verify", "--until=never", client: FakeClient.new)).to eq(5)
    expect(run("check", "--name=x", client: FakeClient.new)).to eq(5)
    expect(described_class.new(%w[verify], stdout: stdout, stderr: stderr, env: {}, git_head: "abc1234").run).to eq(5)
    expect(stderr.string).to include("DEPLOYANGEL_API_TOKEN is not set")
  end
end
