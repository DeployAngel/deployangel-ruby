# frozen_string_literal: true

require "json"

module DeployAngel
  module MCP
    # A Model Context Protocol server over stdio (JSON-RPC 2.0, one message
    # per line) so coding agents can ask whether their release passed
    # production. stdout carries only protocol messages.
    #
    # The tools are read-only with respect to production: nothing here rolls
    # back, restarts, or changes customer infrastructure.
    class Server
      PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
      MAX_WAIT_SECONDS = 300

      INSTRUCTIONS = <<~TEXT.freeze
        DeployAngel verifies deployments in production. After deploying, call wait_for_verification
        with until "initial" (about 15 minutes) or "verdict". Verdicts: verified means cleared, so you may
        report the release as successful. inconclusive means NOT verified: never report it as success.
        failed means production regressed: read the findings and exceptions and investigate.
        Findings are deterministic evidence; any "investigation" field is AI inference. These tools cannot
        change production. Do not roll back or change production without explicit approval.
        If a release isn't cleared yet, get_exercise_plan says what to exercise against production so it
        clears sooner. Only act on status "exercisable" or "waiting_for_activity"; for "warm_up" or
        "no_baseline" nothing you run can clear it. Exercise routes marked mutating only with a test account
        or after asking. Report what you ran with the plan's report_with command (deployangel check).
      TEXT

      TARGET_PROPERTIES = {
        "commit" => { "type" => "string", "description" => "Commit SHA (prefix of 7+ characters is fine)." },
        "version" => { "type" => "string", "description" => "Release version, e.g. v184." },
        "deployment_id" => { "type" => "string", "description" => "DeployAngel deployment ID." },
        "latest" => { "type" => "boolean", "description" => "Use the most recent deployment." }
      }.freeze

      ERROR_CODES = { parse: -32_700, invalid: -32_600, method: -32_601, params: -32_602, internal: -32_603 }.freeze

      def initialize(client:, input: $stdin, output: $stdout, error_output: $stderr,
                     sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now }, git_head: -> {})
        @client = client
        @input = input
        @output = output
        @error_output = error_output
        @sleeper = sleeper
        @clock = clock
        @git_head = git_head
      end

      def run
        @input.each_line do |line|
          next if line.strip.empty?

          response = handle_line(line)
          next unless response

          @output.puts(JSON.generate(response))
          @output.flush
        end
      end

      def handle_line(line)
        message = JSON.parse(line)
        return error_response(nil, :invalid, "expected a JSON object") unless message.is_a?(Hash)

        handle(message)
      rescue JSON::ParserError
        error_response(nil, :parse, "invalid JSON")
      end

      def handle(message)
        id = message["id"]
        method = message["method"]
        return nil if id.nil? # notifications, including notifications/initialized

        case method
        when "initialize" then result(id, initialize_result(message.dig("params", "protocolVersion")))
        when "ping" then result(id, {})
        when "tools/list" then result(id, { "tools" => tools })
        when "tools/call" then result(id, call_tool(message.dig("params", "name"), message.dig("params", "arguments") || {}))
        else error_response(id, :method, "method not found: #{method}")
        end
      rescue ArgumentError => e
        error_response(id, :params, e.message)
      rescue StandardError => e
        @error_output.puts("deployangel mcp: #{e.class}: #{e.message}")
        error_response(id, :internal, "internal error")
      end

      def tools
        list = [
          tool("get_verification", "Current verdict document for a deployment: state, verdict, confidence, coverage, " \
            "findings, new exceptions, clearance report, and what is still watched. Defaults to the current git HEAD.",
            TARGET_PROPERTIES),
          tool("wait_for_verification", "Wait for a deployment's verification. until=initial returns at the 15-minute " \
            "initial check (\"no problems so far\" is NOT clearance); until=verdict waits for verified, failed, or " \
            "inconclusive. Returns the in-progress document if timeout_seconds (max 300) is reached; call again " \
            "while it is still in progress. Inconclusive means not verified.",
            TARGET_PROPERTIES.merge(
              "until" => { "type" => "string", "enum" => %w[initial verdict], "default" => "initial" },
              "timeout_seconds" => { "type" => "integer", "minimum" => 1, "maximum" => MAX_WAIT_SECONDS, "default" => MAX_WAIT_SECONDS }
            )),
          tool("get_exercise_plan", "What stands between a release and clearance, and what to exercise against " \
            "production so it clears sooner: normally active routes short of their runs, routes this release changed " \
            "that haven't run, and critical flows. Routes marked mutating change data: use a test account or ask first. " \
            "Your requests count as ordinary traffic; report what you ran with report_with. Defaults to the current git HEAD.",
            TARGET_PROPERTIES),
          tool("list_deployments", "Recent deployments with their verification state and verdict.",
            { "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10 } }),
          tool("get_exception", "Sanitized details and the application stack trace for an exception fingerprint.",
            { "fingerprint" => { "type" => "string" } }, required: %w[fingerprint]),
          tool("list_late_regressions", "Failures found after a release was cleared, on paths the clearance did not cover.",
            { "since" => { "type" => "string", "description" => "ISO 8601 time" },
              "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10 } })
        ]
        if scopes.include?("deployments")
          list << tool("register_deployment", "Register a deployment so it is verified (manual and CI deploys).",
            { "commit" => { "type" => "string" }, "version" => { "type" => "string" },
              "kind" => { "type" => "string", "enum" => %w[code config rollback promotion] } })
        end
        list
      end

      private
        def initialize_result(requested)
          {
            "protocolVersion" => PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
            "capabilities" => { "tools" => { "listChanged" => false } },
            "serverInfo" => { "name" => "deployangel", "version" => DeployAngel::VERSION },
            "instructions" => INSTRUCTIONS
          }
        end

        def call_tool(name, arguments)
          content =
            case name
            when "get_verification" then waiter.wait(target(arguments), wait: false).then { |o| verification_content(o) }
            when "wait_for_verification" then wait_content(arguments)
            when "get_exercise_plan" then waiter.wait(target(arguments), wait: false).then { |o| plan_content(o) }
            when "list_deployments" then @client.deployments(limit: arguments.fetch("limit", 10))
            when "get_exception" then @client.exception(arguments.fetch("fingerprint") { raise ArgumentError, "fingerprint is required" })
            when "list_late_regressions" then @client.late_regressions(since: arguments["since"], limit: arguments.fetch("limit", 10))
            when "register_deployment"
              raise ArgumentError, "register_deployment is not available for this token" unless scopes.include?("deployments")

              @client.register_deployment(commit: arguments["commit"], version: arguments["version"], kind: arguments["kind"])
            else raise ArgumentError, "unknown tool: #{name}"
            end
          { "content" => [ { "type" => "text", "text" => JSON.pretty_generate(content) } ],
            "structuredContent" => content, "isError" => false }
        rescue Client::Error => e
          { "content" => [ { "type" => "text", "text" => "DeployAngel API error: #{e.message}" } ], "isError" => true }
        end

        def wait_content(arguments)
          until_mode = arguments.fetch("until", "initial")
          raise ArgumentError, "until must be initial or verdict" unless %w[initial verdict].include?(until_mode)

          timeout = arguments.fetch("timeout_seconds", MAX_WAIT_SECONDS).to_i.clamp(1, MAX_WAIT_SECONDS)
          verification_content(waiter.wait(target(arguments), until_mode: until_mode, timeout: timeout))
        end

        def verification_content(outcome)
          return { "found" => false, "note" => "No matching deployment is registered yet." } if outcome.not_found

          { "exit_code" => outcome.exit_code, "meaning" => meaning(outcome.exit_code),
            "in_progress" => outcome.exit_code == VerificationWaiter::TIMED_OUT, "verification" => outcome.document }
        end

        def plan_content(outcome)
          return { "found" => false, "note" => "No matching deployment is registered yet." } if outcome.not_found

          { "deployment" => outcome.document["deployment"],
            "exercise_plan" => outcome.document["exercise_plan"] ||
              { "note" => "This DeployAngel server doesn't return exercise plans yet." } }
        end

        def meaning(code)
          {
            0 => "verified: the release is cleared",
            1 => "failed: production regressed",
            2 => "inconclusive: NOT verified; do not report success",
            3 => "still in progress; call wait_for_verification again",
            6 => "initial check: no problems so far, NOT cleared yet",
            7 => "initial check: warnings present, NOT cleared"
          }.fetch(code, "unknown")
        end

        def target(arguments)
          return { deployment_id: arguments["deployment_id"].to_s } if arguments["deployment_id"]
          return { version: arguments["version"].to_s } if arguments["version"]
          return { commit: arguments["commit"].to_s.downcase } if arguments["commit"]
          return { latest: true } if arguments["latest"]

          head = @git_head.call
          head ? { commit: head.downcase } : { latest: true }
        end

        def waiter
          VerificationWaiter.new(client: @client, sleeper: @sleeper, clock: @clock)
        end

        def scopes
          @scopes ||= Array(@client.token_info["scopes"])
        rescue Client::Error
          []
        end

        def tool(name, description, properties, required: [])
          { "name" => name, "description" => description,
            "inputSchema" => { "type" => "object", "properties" => properties, "required" => required } }
        end

        def result(id, payload)
          { "jsonrpc" => "2.0", "id" => id, "result" => payload }
        end

        def error_response(id, kind, message)
          { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => ERROR_CODES.fetch(kind), "message" => message } }
        end
    end
  end
end
