# frozen_string_literal: true

require "set"

module DeployAngel
  # Accumulates request behavior into one-minute periods inside the process.
  # Recording is a few hash updates under a mutex; nothing here touches the
  # network.
  class Aggregator
    OTHER_ROUTE = "__other__"
    PERIOD_SECONDS = 60
    MAX_EXCEPTIONS = 20
    MAX_BACKTRACES = 5
    MAX_CHECKPOINTS = 100

    RouteStats = Struct.new(:requests, :status_counts, :histogram) do
      def self.empty
        new(0, Hash.new(0), Histogram.new)
      end
    end

    JobStats = Struct.new(:processed, :failed, :discarded, :duration, :queue_latency) do
      def self.empty
        new(0, 0, 0, Histogram.new, Histogram.new)
      end

      def record(failed, discarded, duration_ms, queue_latency_ms)
        self.processed += 1
        self.failed += 1 if failed
        self.discarded += 1 if discarded
        duration.record(duration_ms)
        queue_latency.record(queue_latency_ms) if queue_latency_ms
      end

      def record_discard
        self.discarded += 1
      end
    end

    class Period
      attr_reader :started_at, :requests, :status_counts, :unhandled_exceptions, :histogram, :routes,
        :jobs, :job_classes, :exceptions, :exceptions_truncated, :checkpoints

      def initialize(started_at)
        @started_at = started_at
        @requests = 0
        @status_counts = Hash.new(0)
        @unhandled_exceptions = 0
        @histogram = Histogram.new
        @routes = {}
        @jobs = JobStats.empty
        @job_classes = {}
        @exceptions = {}
        @exceptions_truncated = 0
        @checkpoints = Hash.new(0)
      end

      # Up to 100 names per period; the rest are counted together.
      def record_checkpoint(name, count)
        key = @checkpoints.key?(name) || @checkpoints.size < MAX_CHECKPOINTS - 1 ? name : OTHER_ROUTE
        @checkpoints[key] += count
      end

      # Up to 20 fingerprints per period; the rest are only counted.
      def record_exception(details, source, handled, backtrace)
        entry = @exceptions[details["fingerprint"]]
        unless entry
          if @exceptions.size >= MAX_EXCEPTIONS
            @exceptions_truncated += 1
            return
          end

          entry = @exceptions[details["fingerprint"]] = details.merge("count" => 0, "handled_count" => 0, "sources" => Hash.new(0))
        end
        handled ? entry["handled_count"] += 1 : entry["count"] += 1
        entry["sources"][source] += 1 if source
        entry["backtrace"] ||= backtrace if backtrace
      end

      def record_job(job_class, failed, discarded, duration_ms, queue_latency_ms, max_classes)
        @jobs.record(failed, discarded, duration_ms, queue_latency_ms)
        key = @job_classes.key?(job_class) || @job_classes.size < max_classes - 1 ? job_class : OTHER_ROUTE
        (@job_classes[key] ||= JobStats.empty).record(failed, discarded, duration_ms, queue_latency_ms)
      end

      def record_discard(job_class, max_classes)
        @jobs.record_discard
        key = @job_classes.key?(job_class) || @job_classes.size < max_classes - 1 ? job_class : OTHER_ROUTE
        (@job_classes[key] ||= JobStats.empty).record_discard
      end

      def record(route_key, status, duration_ms, unhandled, max_routes)
        @requests += 1
        @status_counts[status.to_s] += 1 if status >= 400
        @unhandled_exceptions += 1 if unhandled
        @histogram.record(duration_ms)

        key = @routes.key?(route_key) || @routes.size < max_routes - 1 ? route_key : OTHER_ROUTE
        route = (@routes[key] ||= RouteStats.empty)
        route.requests += 1
        route.status_counts[status.to_s] += 1 if status >= 400
        route.histogram.record(duration_ms)
      end
    end

    def initialize(max_routes: 100, clock: -> { Time.now.utc })
      @max_routes = max_routes
      @clock = clock
      @periods = {}
      @seen_fingerprints = Set.new
      @last_drained_at = period_start(@clock.call) - PERIOD_SECONDS
      @mutex = Mutex.new
    end

    def record(route_key:, status:, duration_ms:, unhandled: false)
      started_at = period_start(@clock.call)
      @mutex.synchronize do
        (@periods[started_at] ||= Period.new(started_at))
          .record(route_key, status.to_i, duration_ms, unhandled, @max_routes)
      end
    end

    # failed: the attempt raised (or was retried or discarded by the job);
    # discarded: the job will not run again.
    def record_job(job_class:, duration_ms:, failed: false, discarded: false, queue_latency_ms: nil)
      started_at = period_start(@clock.call)
      @mutex.synchronize do
        (@periods[started_at] ||= Period.new(started_at))
          .record_job(job_class.to_s, failed, discarded, duration_ms, queue_latency_ms, @max_routes)
      end
    end

    # A job that will not run again, recorded without another attempt (for
    # example a Sidekiq job that exhausted its retries).
    def record_discard(job_class:)
      started_at = period_start(@clock.call)
      @mutex.synchronize { (@periods[started_at] ||= Period.new(started_at)).record_discard(job_class.to_s, @max_routes) }
    end

    def record_checkpoint(name:, count: 1)
      started_at = period_start(@clock.call)
      @mutex.synchronize { (@periods[started_at] ||= Period.new(started_at)).record_checkpoint(name, count) }
    end

    # A representative backtrace is kept only the first time this process
    # sees a fingerprint, and at most 5 per period.
    def record_exception(details, source: nil, handled: false, backtrace: nil)
      started_at = period_start(@clock.call)
      @mutex.synchronize do
        period = (@periods[started_at] ||= Period.new(started_at))
        new_here = @seen_fingerprints.add?(details["fingerprint"])
        keep_trace = new_here && period.exceptions.count { |_, e| e["backtrace"] } < MAX_BACKTRACES
        period.record_exception(details, source, handled, keep_trace ? backtrace : nil)
      end
    end

    # Completed periods, oldest first. Minutes with no requests are returned
    # as empty periods, so idle processes still report their release.
    # include_current also closes the in-progress minute (used at shutdown).
    def drain(include_current: false, max_periods: 10)
      current = period_start(@clock.call)
      last = include_current ? current : current - PERIOD_SECONDS

      @mutex.synchronize do
        first = [ @last_drained_at + PERIOD_SECONDS, last - (max_periods - 1) * PERIOD_SECONDS ].max
        drained = (first.to_i..last.to_i).step(PERIOD_SECONDS).map do |seconds|
          started_at = Time.at(seconds).utc
          @periods.delete(started_at) || Period.new(started_at)
        end
        @periods.delete_if { |started_at, _| started_at <= last }
        @last_drained_at = last if drained.any?
        drained
      end
    end

    private
      def period_start(time)
        Time.at(time.to_i - (time.to_i % PERIOD_SECONDS)).utc
      end
  end
end
