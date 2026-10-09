# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"

require_relative "version"
require_relative "configuration"
require_relative "client"
require_relative "ci_environment"
require_relative "verification_waiter"
require_relative "cli/formatter"

module DeployAngel
  # `deployangel` command for developers, CI, and coding agents.
  # Runs without booting Rails.
  class CLI
    USAGE_ERROR = 5
    COMMANDS = %w[release verify status exception check install mcp version help].freeze

    HELP = <<~TEXT
      Usage: deployangel <command> [options]

        release    Register a deployment        [--commit=SHA] [--version=V] [--kind=code]
                                                 [--provider=P] [--url=RUN_URL]
        verify     Report or wait for a verdict  [--commit=SHA | --version=V | --deployment=ID]
                                                 [--wait] [--until=initial|verdict|closed] [--timeout=30m]
                                                 [--format=text|json] [--all-findings]
        status     Latest deployment and its verification
        plan       What to exercise so a release  [--commit=SHA | --version=V | --deployment=ID]
                   clears sooner                 [--format=text|json]
        exception  Details for a fingerprint     deployangel exception FINGERPRINT
        check      Report a smoke test result    --name=NAME --status=pass|fail [--covers=a,b]
                                                 [--commit=SHA | --deployment=ID] [--details-url=URL]
        install    Add a Kamal deploy hook,       deployangel install kamal
                   bake the commit into an image, deployangel install docker
                   or set up coding agents        deployangel install agents
        mcp        Run the MCP server over stdio (for coding agents)

      With no target, verify, plan, and check use the current git HEAD commit.
      In GitHub Actions, GitLab CI, CircleCI, and Buildkite, release fills in the
      commit, a build label (e.g. run-123), and a link to the run automatically.
      In a Kamal hook, it registers Kamal's release (KAMAL_VERSION).
      Environment: DEPLOYANGEL_API_TOKEN (required), DEPLOYANGEL_URL (default #{Configuration::DEFAULT_ENDPOINT})

      Exit codes: 0 verified, 1 failed, 2 inconclusive, 3 still in progress / timed out,
                  4 deployment not found, 5 usage, auth, or network error,
                  6 initial check: no problems so far (NOT cleared), 7 initial check: warnings (NOT cleared)
    TEXT

    # Registers each Kamal deploy. It runs where `kamal deploy` runs, and
    # never fails a deploy that has already shipped.
    KAMAL_HOOK = <<~SH
      #!/bin/sh
      # Registers each deploy with DeployAngel, which then verifies it in
      # production. Needs a "CI deploys" token in DEPLOYANGEL_API_TOKEN where
      # you run `kamal deploy`. Added by `deployangel install kamal`.
      bundle exec deployangel release || true
    SH

    # Goes at the end of the Dockerfile's last stage: a value that changes
    # with every commit invalidates the cache of every layer after it.
    DOCKER_BUILD_HELP = <<~HELP.chomp
      Pass the commit when you build the image:

        docker build --build-arg GIT_SHA=$(git rev-parse HEAD) .
        fly deploy --build-arg GIT_SHA=$(git rev-parse HEAD)
        GitHub Actions (docker/build-push-action):
          build-args: GIT_SHA=${{ github.sha }}

      Kamal apps don't need this: DeployAngel reads Kamal's KAMAL_VERSION.
    HELP

    # The block `deployangel install agents` keeps in AGENTS.md (and CLAUDE.md
    # when it doesn't import AGENTS.md), replaced whole on each run.
    AGENTS_START = "<!-- deployangel:start -->"
    AGENTS_END = "<!-- deployangel:end -->"
    AGENT_INSTRUCTIONS = <<~MARKDOWN
      #{AGENTS_START}
      ## Production verification (DeployAngel)

      After deploying, or pushing a commit that deploys, wait for DeployAngel's
      verdict: call the `wait_for_verification` MCP tool with the commit and
      `until: "initial"`, calling again while it's in progress, or run
      `bundle exec deployangel verify --commit=<sha> --wait --until=initial`.

      - Exit 0 / verified: the release is cleared. Report the clearance line and
        anything DeployAngel is still watching, then move on.
      - Exit 6: no problems so far, but NOT cleared. Report "no problems so far, not
        yet cleared" and the expected clearance time. DeployAngel keeps verifying and
        alerts on failure.
      - Exit 7: warnings at the initial check. Report them and review the findings.
        The release is NOT cleared.
      - Exit 2 / inconclusive: the release is NOT verified. Do not claim success.
      - Exit 1 / failed: read the findings and exceptions (`get_exception`),
        investigate the likely cause, and propose a fix. Do not roll back or change
        production without explicit approval.
      - Exit 3: still verifying; run the command again.
      - Not cleared yet: call `get_exercise_plan` (or `bundle exec deployangel plan`).
        If its status is "exercisable" or "waiting_for_activity", say what it lists
        and offer to exercise it: read-only routes freely, routes marked mutating
        only with a test account or after asking. If the status is "warm_up",
        nothing run can clear it.
      #{AGENTS_END}
    MARKDOWN

    AGENTS_TOKEN_HELP = <<~HELP.chomp
      The MCP server and CLI need DEPLOYANGEL_API_TOKEN, a "CLI & coding agents" token
      from the app's Settings, in the environment your agent runs in (for example in
      an .envrc with direnv). Never put it in these files: they're meant to be committed.
      Codex reads .codex/config.toml only in projects you've marked as trusted.
    HELP

    DOCKERFILE_LINES = <<~DOCKERFILE
      # The commit this image runs, for DeployAngel. Build with --build-arg GIT_SHA=$(git rev-parse HEAD).
      ARG GIT_SHA
      ENV DEPLOYANGEL_REVISION=$GIT_SHA
    DOCKERFILE

    def initialize(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr, client: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now }, git_head: nil, root: Dir.pwd)
      @root = root
      @argv = argv.dup
      @env = env
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @client = client
      @sleeper = sleeper
      @clock = clock
      @git_head = git_head
    end

    def run
      command = @argv.shift
      case command
      when "release" then release
      when "verify" then verify
      when "status" then verify(status: true)
      when "plan" then plan
      when "exception" then exception
      when "check" then check
      when "install" then install
      when "mcp" then mcp
      when "version", "--version", "-v" then @stdout.puts(DeployAngel::VERSION) || 0
      when nil, "help", "--help", "-h" then @stdout.puts(HELP) || 0
      else usage_error("unknown command: #{command}")
      end
    rescue OptionParser::ParseError => e
      usage_error(e.message)
    rescue Client::Unauthorized => e
      @stderr.puts("deployangel: #{e.message}")
      USAGE_ERROR
    rescue Client::NotFound => e
      @stderr.puts("deployangel: #{e.message}")
      VerificationWaiter::NOT_FOUND
    rescue Client::Error => e
      @stderr.puts("deployangel: #{e.message}")
      USAGE_ERROR
    end

    private
      def release
        options = parse(commit: nil, version: nil, kind: nil, provider: nil, source_url: nil) do |o, opts|
          o.on("--commit=SHA") { |v| opts[:commit] = v }
          o.on("--version=VERSION") { |v| opts[:version] = v }
          o.on("--kind=KIND") { |v| opts[:kind] = v }
          o.on("--provider=PROVIDER") { |v| opts[:provider] = v }
          o.on("--url=URL") { |v| opts[:source_url] = v }
        end
        # Explicit options win, then the CI system, then git.
        if (ci = CiEnvironment.detect(@env))
          options[:commit] ||= ci.commit
          options[:version] ||= ci.version
          options[:provider] ||= ci.provider
          options[:source_url] ||= ci.source_url
        end
        options[:commit] ||= git_head
        return usage_error("release needs --commit or --version (no git repository or CI commit found)") unless options[:commit] || options[:version]

        deployment = client.register_deployment(**options)
        @stdout.puts("Registered deployment #{deployment["id"]} (#{deployment["version"] || deployment["commit"]}), verification #{deployment["state"]}")
        0
      end

      def verify(status: false)
        options = parse(until_mode: "verdict", timeout: 1800, wait: false, format: nil, all_findings: false) do |o, opts|
          o.on("--commit=SHA") { |v| opts[:commit] = v }
          o.on("--version=VERSION") { |v| opts[:version] = v }
          o.on("--deployment=ID") { |v| opts[:deployment_id] = v }
          o.on("--wait") { opts[:wait] = true }
          o.on("--until=MODE", VerificationWaiter::UNTIL_MODES) { |v| opts[:until_mode] = v }
          o.on("--timeout=DURATION") { |v| opts[:timeout] = parse_duration(v) }
          o.on("--format=FORMAT", %w[text json]) { |v| opts[:format] = v }
          o.on("--all-findings") { opts[:all_findings] = true }
        end
        target = status ? { latest: true } : target_from(options)
        return usage_error("no target: pass --commit, --version, or --deployment, or run inside a git repository") unless target

        waiter = VerificationWaiter.new(client: client, sleeper: @sleeper, clock: @clock,
          on_progress: ->(message) { @stderr.puts(message) if options[:wait] })
        outcome = waiter.wait(target, until_mode: options[:until_mode], timeout: options[:timeout], wait: options[:wait])
        if outcome.not_found
          @stderr.puts("deployangel: no deployment found for #{target.values.first}")
          step_summary("### DeployAngel: no deployment found for #{target.values.first}\n")
          return outcome.exit_code
        end

        document = options[:all_findings] ? client.verification(outcome.document.dig("deployment", "id"), all_findings: true) : outcome.document
        output(document, options[:format]) { Formatter.verification(document) }
        step_summary(Formatter.markdown(document))
        @stderr.puts("deployangel: timed out; verification is still in progress") if outcome.timed_out
        outcome.exit_code
      end

      # The release's exercise plan: what stands between it and clearance,
      # and what to exercise against production so it clears sooner.
      def plan
        options = parse(format: nil) do |o, opts|
          o.on("--commit=SHA") { |v| opts[:commit] = v }
          o.on("--version=VERSION") { |v| opts[:version] = v }
          o.on("--deployment=ID") { |v| opts[:deployment_id] = v }
          o.on("--format=FORMAT", %w[text json]) { |v| opts[:format] = v }
        end
        target = target_from(options)
        return usage_error("no target: pass --commit, --version, or --deployment, or run inside a git repository") unless target

        outcome = VerificationWaiter.new(client: client, sleeper: @sleeper, clock: @clock).wait(target, wait: false)
        if outcome.not_found
          @stderr.puts("deployangel: no deployment found for #{target.values.first}")
          return outcome.exit_code
        end

        document = outcome.document
        json = { "deployment" => document["deployment"], "exercise_plan" => document["exercise_plan"] }
        output(json, options[:format]) { Formatter.exercise_plan(document) }
        0
      end

      def exception
        fingerprint = @argv.shift or return usage_error("exception needs a FINGERPRINT")
        format = parse(format: nil) { |o, opts| o.on("--format=FORMAT", %w[text json]) { |v| opts[:format] = v } }[:format]
        details = client.exception(fingerprint)
        output(details, format) { Formatter.exception(details) }
        0
      end

      def check
        options = parse(name: nil, status: nil, covers: [], details_url: nil) do |o, opts|
          o.on("--name=NAME") { |v| opts[:name] = v }
          o.on("--status=STATUS", %w[pass fail]) { |v| opts[:status] = v }
          o.on("--covers=LIST") { |v| opts[:covers] = v.split(",").map(&:strip) }
          o.on("--details-url=URL") { |v| opts[:details_url] = v }
          o.on("--commit=SHA") { |v| opts[:commit] = v }
          o.on("--deployment=ID") { |v| opts[:deployment_id] = v }
        end
        return usage_error("check needs --name and --status=pass|fail") unless options[:name] && options[:status]

        commit = options[:commit] || (git_head || CiEnvironment.detect(@env)&.commit unless options[:deployment_id])
        reference = options[:deployment_id] || (commit && "commit:#{commit}")
        return usage_error("check needs --deployment or --commit, or a git repository") unless reference

        result = client.report_check(reference, name: options[:name], status: options[:status],
          covers: options[:covers], details_url: options[:details_url])
        @stdout.puts("Recorded #{options[:status]} check \"#{options[:name]}\" for deployment #{result["deployment_id"]}")
        0
      end

      def install
        case (target = @argv.shift)
        when "kamal" then install_kamal
        when "docker" then install_docker
        when "agents" then install_agents
        else usage_error("install needs a target: deployangel install kamal, docker, or agents")
        end
      end

      # Writes .kamal/hooks/post-deploy, or says what to add to a hook that
      # already exists, rather than overwriting it.
      def install_kamal
        relative = File.join(".kamal", "hooks", "post-deploy")
        path = File.join(@root, relative)
        if File.exist?(path)
          if File.read(path).include?("deployangel release")
            @stdout.puts("#{relative} already registers deploys with DeployAngel.")
          else
            @stdout.puts("#{relative} already exists. Add this line to it:", "", "  bundle exec deployangel release || true")
          end
          return 0
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, KAMAL_HOOK)
        File.chmod(0o755, path)
        @stdout.puts("Created #{relative}. Each `kamal deploy` now registers its release with DeployAngel.",
          "Set DEPLOYANGEL_API_TOKEN (a \"CI deploys\" token) wherever you run kamal deploy.")
        0
      end

      # Sets up Claude Code, Cursor, and Codex in this project: the MCP server
      # in each one's project config, and instructions to wait for a verdict
      # after deploying. Never overwrites what's there: an existing entry is
      # kept, and a file it can't read is left for you to edit.
      def install_agents
        command = %w[bundle exec deployangel mcp]
        lines = [
          install_json_mcp(".mcp.json", command, "Claude Code"),
          install_json_mcp(File.join(".cursor", "mcp.json"), command, "Cursor"),
          install_codex_mcp(command),
          *install_agent_instructions
        ]
        @stdout.puts(*lines, "", AGENTS_TOKEN_HELP)
        0
      end

      def install_json_mcp(relative, command, agent)
        path = File.join(@root, relative)
        config = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        raise JSON::ParserError, "not a JSON object" unless config.is_a?(Hash)

        servers = (config["mcpServers"] ||= {})
        return "#{relative} already has a deployangel MCP server (#{agent})." if servers.key?("deployangel")

        created = !File.exist?(path)
        servers["deployangel"] = { "command" => command.first, "args" => command.drop(1) }
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(config)}\n")
        "#{created ? "Created" : "Updated"} #{relative}: the DeployAngel MCP server for #{agent}."
      rescue JSON::ParserError
        "Couldn't read #{relative}, so it's unchanged. Add a \"deployangel\" server to its mcpServers: " \
          "command \"#{command.first}\", args #{command.drop(1).to_json}."
      end

      def install_codex_mcp(command)
        relative = File.join(".codex", "config.toml")
        path = File.join(@root, relative)
        existing = File.exist?(path) ? File.read(path) : nil
        return "#{relative} already has a deployangel MCP server (Codex)." if existing&.include?("[mcp_servers.deployangel]")

        table = <<~TOML
          [mcp_servers.deployangel]
          command = #{command.first.to_json}
          args = #{command.drop(1).to_json.gsub(",", ", ")}
          env_vars = ["DEPLOYANGEL_API_TOKEN", "DEPLOYANGEL_URL"]
        TOML
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, existing ? "#{existing.sub(/\n*\z/, "\n")}\n#{table}" : table)
        "#{existing ? "Updated" : "Created"} #{relative}: the DeployAngel MCP server for Codex."
      end

      # AGENTS.md serves Codex and Cursor. Claude Code reads CLAUDE.md, so it
      # gets the block too, unless it already imports AGENTS.md; a project
      # without one gets a CLAUDE.md that does.
      def install_agent_instructions
        lines = [ upsert_instructions("AGENTS.md") ]
        claude = File.join(@root, "CLAUDE.md")
        if !File.exist?(claude)
          File.write(claude, "@AGENTS.md\n")
          lines << "Created CLAUDE.md, which imports AGENTS.md for Claude Code."
        elsif !File.read(claude).match?(/^@AGENTS\.md\s*$/)
          lines << upsert_instructions("CLAUDE.md")
        end
        lines
      end

      def upsert_instructions(relative)
        path = File.join(@root, relative)
        unless File.exist?(path)
          File.write(path, AGENT_INSTRUCTIONS)
          return "Created #{relative} with instructions to wait for DeployAngel's verdict after deploying."
        end

        content = File.read(path)
        block = /#{Regexp.escape(AGENTS_START)}.*?#{Regexp.escape(AGENTS_END)}\n?/m
        if content.match?(block)
          updated = content.sub(block, AGENT_INSTRUCTIONS)
          return "#{relative} already has DeployAngel's instructions." if updated == content

          File.write(path, updated)
          "Updated DeployAngel's instructions in #{relative}."
        else
          File.write(path, "#{content.sub(/\n*\z/, "\n")}\n#{AGENT_INSTRUCTIONS}")
          "Added instructions to wait for DeployAngel's verdict after deploying to #{relative}."
        end
      end

      # Adds DEPLOYANGEL_REVISION, from a GIT_SHA build arg, to the Dockerfile.
      # It never edits CI workflows; it says what to pass instead.
      def install_docker
        path = File.join(@root, "Dockerfile")
        unless File.file?(path)
          @stderr.puts("deployangel: no Dockerfile in #{@root}; run this where your Dockerfile is")
          return USAGE_ERROR
        end

        content = File.read(path)
        if content.include?("DEPLOYANGEL_REVISION")
          @stdout.puts("Dockerfile already sets DEPLOYANGEL_REVISION.")
          return 0
        end

        File.write(path, with_revision(content))
        @stdout.puts("Added DEPLOYANGEL_REVISION to the Dockerfile's last stage. #{DOCKER_BUILD_HELP}")
        0
      end

      # Before the CMD and ENTRYPOINT lines that end the last stage, with any
      # comment just above them, or at the end if the stage doesn't end with
      # one. Continuation lines aren't instructions.
      def with_revision(content)
        lines = content.lines
        instructions = []
        continuing = false
        lines.each_with_index do |line, index|
          text = line.strip
          next if text.empty? || text.start_with?("#")

          instructions << [ index, text[/\A\w+/].to_s.upcase ] unless continuing
          continuing = text.end_with?("\\")
        end

        stage = instructions.drop(instructions.rindex { |_, word| word == "FROM" } || 0)
        trailing = stage.reverse.take_while { |_, word| %w[CMD ENTRYPOINT].include?(word) }
        if trailing.empty?
          lines[-1] = "#{lines[-1].chomp}\n" if lines.any?
          lines << "\n" unless lines.empty? || lines[-1].strip.empty?
          lines << DOCKERFILE_LINES
        else
          at = trailing.last.first
          at -= 1 while at.positive? && lines[at - 1].strip.start_with?("#")
          lines.insert(at, DOCKERFILE_LINES)
        end
        lines.join
      end

      def mcp
        require_relative "mcp"
        MCP::Server.new(client: client, input: @stdin, output: @stdout, error_output: @stderr,
          sleeper: @sleeper, clock: @clock, git_head: method(:git_head)).run
        0
      end

      def parse(defaults)
        options = defaults.dup
        OptionParser.new { |o| yield(o, options) }.parse!(@argv)
        options
      end

      def target_from(options)
        return { deployment_id: options[:deployment_id] } if options[:deployment_id]
        return { version: options[:version] } if options[:version]

        commit = options[:commit] || git_head || CiEnvironment.detect(@env)&.commit
        { commit: commit.downcase } if commit
      end

      def output(document, format = nil)
        format ||= @stdout.tty? ? "text" : "json"
        @stdout.puts(format == "json" ? JSON.pretty_generate(document) : yield)
      end

      # In GitHub Actions, the verdict also goes on the run's summary page.
      def step_summary(markdown)
        path = @env["GITHUB_STEP_SUMMARY"].to_s
        return if path.empty?

        File.open(path, "a") { |file| file.puts(markdown) }
      rescue SystemCallError => e
        @stderr.puts("deployangel: couldn't write the job summary (#{e.message})")
      end

      def parse_duration(value)
        match = value.to_s.match(/\A(\d+)(s|m|h)?\z/) or raise OptionParser::InvalidArgument, "--timeout=#{value}"
        match[1].to_i * { nil => 1, "s" => 1, "m" => 60, "h" => 3600 }.fetch(match[2])
      end

      def git_head
        return @git_head if @git_head
        return nil if @git_head == false

        output, status = Open3.capture2("git", "rev-parse", "HEAD", err: File::NULL)
        status.success? ? output.strip : nil
      rescue SystemCallError
        nil
      end

      def client
        @client ||= Client.new(token: @env["DEPLOYANGEL_API_TOKEN"],
          endpoint: @env["DEPLOYANGEL_URL"] || Configuration::DEFAULT_ENDPOINT)
      end

      def usage_error(message)
        @stderr.puts("deployangel: #{message}")
        @stderr.puts("Run `deployangel help` for usage.")
        USAGE_ERROR
      end
  end
end
