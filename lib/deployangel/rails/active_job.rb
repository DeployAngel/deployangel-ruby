# frozen_string_literal: true

module DeployAngel
  module Rails
    # Instruments every ActiveJob adapter (Solid Queue, Sidekiq, GoodJob,
    # ...) through ActiveSupport::Notifications.
    #
    # Failures handled by retry_on or discard_on never surface on the
    # perform event, so enqueue_retry, discard, and retry_stopped mark the
    # job while it performs. Everything is then counted exactly once when
    # perform finishes.
    module ActiveJob
      STATE = :@__deployangel_job_state
      PREVIOUS_CONTEXT = :@__deployangel_previous_context

      # Marks the fiber as running a job for as long as perform.active_job
      # lasts, so checkpoints recorded by the job say so. ActiveSupport calls
      # finish from an ensure, so the previous context (an HTTP request, for
      # a job performed inline) comes back even when the job raises. It is
      # kept on the job, so only a perform that started here restores.
      module ContextListener
        module_function

        def start(_name, _id, payload)
          job = payload[:job]
          return unless job && DeployAngel.recording?

          job.instance_variable_set(PREVIOUS_CONTEXT, ExecutionContext.enter(ExecutionContext::JOB))
        rescue StandardError
          nil
        end

        def finish(_name, _id, payload)
          job = payload[:job]
          return unless job&.instance_variable_defined?(PREVIOUS_CONTEXT)

          ExecutionContext.restore(job.remove_instance_variable(PREVIOUS_CONTEXT))
        rescue StandardError
          nil
        end
      end

      module_function

      def install
        return if @installed || !defined?(::ActiveSupport::Notifications)

        @installed = true
        DeployAngel.add_capability("jobs")
        subscribe("perform_start.active_job") { |payload| state(payload)[:queue_latency_ms] = queue_latency_ms(payload[:job]) }
        subscribe("enqueue_retry.active_job") { |payload| state(payload).merge!(failed: true, error: payload[:error]) }
        subscribe("discard.active_job") { |payload| state(payload).merge!(failed: true, discarded: true, error: payload[:error]) }
        subscribe("retry_stopped.active_job") { |payload| state(payload).merge!(failed: true, discarded: true, error: payload[:error]) }
        ::ActiveSupport::Notifications.subscribe("perform.active_job", ContextListener)
        ::ActiveSupport::Notifications.subscribe("perform.active_job") { |event| record(event) }
      end

      def record(event)
        return unless DeployAngel.recording?

        job = event.payload[:job]
        state = job&.instance_variable_get(STATE) || {}
        error = event.payload[:exception_object] || state[:error]
        DeployAngel.record_exception(error, source: "job_class:#{job.class.name}") if error
        DeployAngel.record_job(
          job_class: job.class.name,
          duration_ms: event.duration,
          failed: state[:failed] || !event.payload[:exception_object].nil?,
          discarded: state[:discarded] || false,
          queue_latency_ms: state[:queue_latency_ms]
        )
      rescue StandardError
        nil
      end

      def subscribe(name)
        ::ActiveSupport::Notifications.subscribe(name) do |*, payload|
          yield payload if DeployAngel.recording? && payload[:job]
        rescue StandardError
          nil
        end
      end

      def state(payload)
        job = payload[:job]
        job.instance_variable_get(STATE) || job.instance_variable_set(STATE, {})
      end

      # From when the job became runnable: its scheduled time, else when it
      # was enqueued.
      def queue_latency_ms(job)
        runnable_at = job.scheduled_at || job.enqueued_at
        return unless runnable_at

        [ (Time.now - runnable_at) * 1000.0, 0 ].max
      end
    end
  end
end
