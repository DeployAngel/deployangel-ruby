# frozen_string_literal: true

module DeployAngel
  # Reads how many jobs are ready to run and waiting in the job backend's
  # queues. Only job worker processes read it, once a minute from the
  # reporter thread as they send telemetry, never in a request or job. Every
  # worker sees the same queues, and the cloud keeps the largest reading.
  module QueueBacklog
    module_function

    # Solid Queue runs each worker in its own process, forked by the
    # supervisor, so it's marked as each one starts.
    def install
      return if @installed || !defined?(::SolidQueue) || !::SolidQueue.respond_to?(:on_worker_start)

      @installed = true
      ::SolidQueue.on_worker_start { worker!(:solid_queue) }
    rescue StandardError
      nil
    end

    # Called where the backend says this process works its queues: Sidekiq's
    # server configuration, or a Solid Queue worker starting.
    def worker!(backend)
      @backend = backend
    end

    def backend
      @backend
    end

    # Jobs waiting, or nil when this process doesn't work a queue it can read.
    def read
      case @backend
      when :sidekiq then sidekiq
      when :solid_queue then solid_queue
      end
    rescue StandardError, LoadError
      nil
    end

    # One pipelined call for every queue's length.
    def sidekiq
      require "sidekiq/api"
      ::Sidekiq::Stats.new.enqueued
    end

    # Ready executions only: scheduled and blocked jobs aren't waiting on a
    # worker. The connection goes straight back to the pool.
    def solid_queue
      model = ::SolidQueue::ReadyExecution
      model.connection_pool.with_connection { model.count }
    end
  end
end
