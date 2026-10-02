# frozen_string_literal: true

module DeployAngel
  # Finds a deployment and polls its verdict document until the requested
  # point: the 15-minute initial check, a verdict, or the end of watching.
  # Shared by the CLI and the MCP server.
  class VerificationWaiter
    Outcome = Struct.new(:document, :exit_code, :timed_out, :not_found, keyword_init: true)

    # Exit codes are the primary signal for agents and CI.
    EXIT_CODES = { "verified" => 0, "failed" => 1, "inconclusive" => 2 }.freeze
    TIMED_OUT = 3
    NOT_FOUND = 4
    INITIAL_OK = 6
    INITIAL_WARNINGS = 7
    UNTIL_MODES = %w[initial verdict closed].freeze
    PENDING_POLL = 15

    def initialize(client:, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.now }, on_progress: nil)
      @client = client
      @sleeper = sleeper
      @clock = clock
      @on_progress = on_progress
    end

    # target: { deployment_id: } | { version: } | { commit: } | { latest: true }
    def wait(target, until_mode: "verdict", timeout: 1800, wait: true)
      deadline = @clock.call + timeout
      last_state = nil
      loop do
        deployment = find(target)
        if deployment.nil?
          return Outcome.new(not_found: true, exit_code: NOT_FOUND) if !wait || @clock.call >= deadline

          progress("Waiting for deployment #{describe(target)} to be registered…") unless last_state == :pending_registration
          last_state = :pending_registration
          @sleeper.call([ PENDING_POLL, deadline - @clock.call ].min.clamp(1, PENDING_POLL))
          next
        end

        document = @client.verification(deployment["id"])
        state = document.dig("verification", "state")
        progress("#{document.dig("deployment", "version") || document.dig("deployment", "commit")}: #{state}") if state != last_state
        last_state = state

        code = self.class.exit_code(document, until_mode)
        return Outcome.new(document: document, exit_code: code) if code
        return Outcome.new(document: document, exit_code: TIMED_OUT) unless wait
        return Outcome.new(document: document, exit_code: TIMED_OUT, timed_out: true) if @clock.call >= deadline

        poll = (document["poll_after_seconds"] || 30).to_i.clamp(5, 60)
        @sleeper.call([ poll, deadline - @clock.call ].min.clamp(1, 60))
      end
    end

    # nil means "keep waiting". Failed always returns immediately.
    def self.exit_code(document, until_mode)
      verification = document["verification"] || {}
      verdict = verification["verdict"]
      return EXIT_CODES["failed"] if verdict == "failed"

      case until_mode
      when "closed"
        EXIT_CODES[verdict] if verdict && verification["state"] == "closed"
      when "initial"
        if verdict
          EXIT_CODES[verdict]
        elsif (check = verification["initial_check"])
          check["result"] == "warnings" ? INITIAL_WARNINGS : INITIAL_OK
        end
      else
        EXIT_CODES[verdict] if verdict
      end
    end

    private
      def find(target)
        if target[:deployment_id]
          { "id" => target[:deployment_id] }
        elsif target[:latest]
          @client.latest_deployment
        else
          @client.deployments(commit: target[:commit], version: target[:version], limit: 1).first
        end
      rescue Client::NotFound
        nil
      end

      def describe(target)
        target[:version] || target[:commit]&.slice(0, 12) || target[:deployment_id] || "latest"
      end

      def progress(message)
        @on_progress&.call(message)
      end
  end
end
