# frozen_string_literal: true

module DeployAngel
  # Server middleware for native Sidekiq jobs (Sidekiq::Job without
  # ActiveJob). ActiveJob jobs on Sidekiq are recorded by the ActiveJob
  # instrumentation instead, so they are skipped here to avoid double counts.
  module Sidekiq
    ACTIVE_JOB_WRAPPERS = %w[
      Sidekiq::ActiveJob::Wrapper
      ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper
    ].freeze

    class ServerMiddleware
      def call(_job_instance, job, _queue)
        return yield if ACTIVE_JOB_WRAPPERS.include?(job["class"]) || !DeployAngel.recording?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        latency = DeployAngel::Sidekiq.queue_latency_ms(job)
        previous_context = ExecutionContext.enter(ExecutionContext::JOB)
        begin
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
          DeployAngel.record_exception(e, source: "job_class:#{job["class"]}")
          record(job, started, latency, failed: true)
          raise
        ensure
          ExecutionContext.restore(previous_context)
        end
        record(job, started, latency, failed: false)
      end

      private
        def record(job, started, latency, failed:)
          DeployAngel.record_job(job_class: job["class"], failed: failed, queue_latency_ms: latency,
            duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0)
        rescue StandardError
          nil
        end
    end

    module_function

    def install
      return if @installed || !defined?(::Sidekiq) || !::Sidekiq.respond_to?(:configure_server)

      @installed = true
      DeployAngel.add_capability("jobs")
      ::Sidekiq.configure_server do |config|
        config.server_middleware { |chain| chain.add(ServerMiddleware) }
        # Jobs that exhausted their retries are discarded.
        config.death_handlers << ->(job, _error) { record_death(job) } if config.respond_to?(:death_handlers)
      end
    end

    # A dead job was already counted as a failed attempt by the middleware;
    # this only records that it will not run again.
    def record_death(job)
      return if ACTIVE_JOB_WRAPPERS.include?(job["class"]) || !DeployAngel.agent

      DeployAngel.agent.record_discard(job_class: job["class"])
    rescue StandardError
      nil
    end

    # Sidekiq 8 stores epoch milliseconds; earlier versions store seconds.
    def queue_latency_ms(job)
      enqueued = job["enqueued_at"]
      return unless enqueued.is_a?(Numeric)

      enqueued_ms = enqueued > 100_000_000_000 ? enqueued : enqueued * 1000.0
      [ (Time.now.to_f * 1000.0) - enqueued_ms, 0 ].max
    end
  end
end
