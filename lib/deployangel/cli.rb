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
        exception  Details for a fingerprint     deployangel exception FINGERPRINT
        check      Report a smoke test result    --name=NAME --status=pass|fail [--covers=a,b]
                                                 [--commit=SHA | --deployment=ID] [--details-url=URL]
        install    Add a deploy hook             deployangel install kamal
        mcp        Run the MCP server over stdio (for coding agents)

      With no target, verify and check use the current git HEAD commit.
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

      # Writes .kamal/hooks/post-deploy, or says what to add to a hook that
      # already exists, rather than overwriting it.
      def install
        target = @argv.shift
        return usage_error("install needs a target: deployangel install kamal") unless target == "kamal"

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
