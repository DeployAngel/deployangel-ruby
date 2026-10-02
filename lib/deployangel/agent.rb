# frozen_string_literal: true

module DeployAngel
  # The per-process runtime: records requests into the aggregator and sends
  # completed minutes from a background thread. Every public method fails
  # open; nothing here may raise into, or block, the customer's app.
  class Agent
    TELEMETRY_PATH = "/api/v1/telemetry"
    METADATA_PATH = "/api/v1/application_metadata"
    SHUTDOWN_TIMEOUT = 2
    DEFAULT_PAUSE = 60

    attr_reader :config, :release, :instance
    attr_writer :metadata

    def initialize(config:, environment:, root: nil, framework: nil, framework_version: nil,
                   env: ENV, transport: nil, clock: -> { Time.now.utc }, eager: false)
      @config = config
      @active = config.active?(environment)
      @release = Release.resolve(config: config, env: env, root: root)
      @runtime = Protocol.runtime(framework: framework, framework_version: framework_version)
      @transport = transport || Transport.new(config)
      @env = env
      @root = root
      @clock = clock
      @eager = eager
      @thread_mutex = Mutex.new
      @warned = {}
      reset_process_state
      warn_once(:unknown_release, "DeployAngel could not determine the release; set DEPLOYANGEL_REVISION " \
        "or enable Heroku dyno metadata. Telemetry will not be attributed to deployments.") if @active && @release.unknown?
      start_reporter if @active && eager
    end

    def active?
      @active
    end

    def record_request(route_key:, status:, duration_ms:, unhandled: false)
      return unless @active

      after_fork! if Process.pid != @pid
      start_reporter
      @aggregator.record(route_key: route_key, status: status, duration_ms: duration_ms, unhandled: unhandled)
    rescue StandardError => e
      warn_once(:record, "DeployAngel failed to record a request: #{e.class}: #{e.message}")
    end

    def record_job(job_class:, duration_ms:, failed: false, discarded: false, queue_latency_ms: nil)
      return unless @active

      after_fork! if Process.pid != @pid
      start_reporter
      @aggregator.record_job(job_class: job_class, duration_ms: duration_ms, failed: failed,
        discarded: discarded, queue_latency_ms: queue_latency_ms)
    rescue StandardError => e
      warn_once(:record_job, "DeployAngel failed to record a job: #{e.class}: #{e.message}")
    end

    def record_discard(job_class:)
      return unless @active

      @aggregator.record_discard(job_class: job_class)
    rescue StandardError => e
      warn_once(:record_discard, "DeployAngel failed to record a discarded job: #{e.class}: #{e.message}")
    end

    def record_checkpoint(name, count: 1)
      return unless @active

      after_fork! if Process.pid != @pid
      start_reporter
      @aggregator.record_checkpoint(name: name, count: count)
    rescue StandardError => e
      warn_once(:record_checkpoint, "DeployAngel failed to record a checkpoint: #{e.class}: #{e.message}")
    end

    SEEN = :@__deployangel_recorded

    # Records each exception object once, whichever instrumentation sees it
    # first (middleware, job events, or Rails.error).
    def record_exception(exception, source: nil, handled: false)
      return unless @active && exception.is_a?(Exception)
      return if exception.instance_variable_defined?(SEEN)

      exception.instance_variable_set(SEEN, true) unless exception.frozen?
      start_reporter
      @aggregator.record_exception(Fingerprint.for(exception, root: @root), source: source, handled: handled,
        backtrace: Fingerprint.backtrace(exception, root: @root))
    rescue StandardError => e
      warn_once(:record_exception, "DeployAngel failed to record an exception: #{e.class}: #{e.message}")
    end

    # Signals this process can observe, announced in every payload so the
    # cloud never claims to verify what the agent cannot see.
    def capabilities
      DeployAngel.capabilities
    end

    # Drains completed minutes into the buffer, encoded so unsent minutes stay
    # small while DeployAngel is unreachable, and sends what it can.
    def flush(include_current: false)
      return 0 unless @active

      @aggregator.drain(include_current: include_current, max_periods: config.max_queued_payloads).each do |period|
        @buffer.push(Transport.encode(Protocol.telemetry(period, instance: @instance, release: @release,
          runtime: @runtime, capabilities: capabilities)))
      end
      send_buffered
    rescue StandardError => e
      warn_once(:flush, "DeployAngel failed to flush telemetry: #{e.class}: #{e.message}")
      0
    end

    def start_reporter
      return unless @active
      return if @thread&.alive?

      @thread_mutex.synchronize do
        return if @thread&.alive?

        @stopping = false
        @thread = Thread.new { run_reporter }
        @thread.name = "deployangel-reporter"
        @thread.report_on_exception = false
      end
    end

    # Sends the in-progress minute too, bounded by a short timeout, because
    # deployments restart processes.
    def shutdown(timeout: SHUTDOWN_TIMEOUT)
      return unless @active

      @stopping = true
      @thread&.wakeup if @thread&.alive?
      finisher = Thread.new { flush(include_current: true) }
      finisher.join(timeout)
    rescue StandardError
      nil
    end

    # Threads do not survive fork, and the parent's identity and counts must
    # not be reused by the child.
    def after_fork!
      reset_process_state
      start_reporter if @active && @eager
    end

    # Sent once per process; retried on the next minute if it fails. File
    # digests are only uploaded when the cloud has not seen the manifest.
    def send_metadata
      return if @metadata_sent || @metadata.nil? || paused?

      base = { "protocol_version" => Protocol::VERSION, "instance" => @instance.to_protocol,
               "release" => @release.to_protocol, "runtime" => @runtime }.merge(@metadata.to_protocol)
      result = @transport.post(METADATA_PATH, base)
      return unless result.ok?

      if result.body.is_a?(Hash) && result.body["manifest_needed"]
        return unless @transport.post(METADATA_PATH, base.merge("files" => @metadata.files)).ok?
      end
      @metadata_sent = true
    rescue StandardError => e
      warn_once(:metadata, "DeployAngel failed to send application metadata: #{e.class}: #{e.message}")
    end

    private
      def reset_process_state
        @pid = Process.pid
        @instance = Instance.new(env: @env, now: @clock.call)
        @aggregator = Aggregator.new(max_routes: config.max_routes, clock: @clock)
        @buffer = Buffer.new(config.max_queued_payloads)
        @paused_until = nil
        @metadata_sent = false
        @thread = nil
        # Spread processes across the first seconds of each minute.
        @jitter = rand(1.0..10.0)
      end

      def run_reporter
        until @stopping
          sleep(seconds_until_next_flush)
          break if @stopping

          send_metadata
          flush
        end
      rescue StandardError => e
        warn_once(:reporter, "DeployAngel reporter stopped: #{e.class}: #{e.message}")
      end

      def seconds_until_next_flush
        now = @clock.call.to_f
        interval = config.flush_interval
        (interval - (now % interval)) + @jitter
      end

      def send_buffered
        sent = 0
        while (payload = @buffer.shift)
          if paused?
            @buffer.unshift(payload)
            break
          end

          result = @transport.post(TELEMETRY_PATH, payload)
          case result.outcome
          when :ok
            sent += 1
          when :retry
            @buffer.unshift(payload)
            break
          else
            handle_rejection(result)
          end
        end
        sent
      end

      def handle_rejection(result)
        case result.status
        when 429
          @paused_until = @clock.call + (result.retry_after.to_i.positive? ? result.retry_after : DEFAULT_PAUSE)
        when 401, 403
          warn_once(:auth, "DeployAngel rejected the token (HTTP #{result.status}); check DEPLOYANGEL_TOKEN " \
            "and that it has the telemetry scope.")
        else
          warn_once(:"rejected_#{result.status}", "DeployAngel rejected a telemetry payload (HTTP #{result.status}).")
        end
      end

      def paused?
        @paused_until && @clock.call < @paused_until
      end

      def warn_once(key, message)
        return if @warned[key]

        @warned[key] = true
        config.logger&.warn(message)
      end
  end
end
