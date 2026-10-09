# frozen_string_literal: true

require "set"

module DeployAngel
  # Work that runs on a schedule but isn't a job, such as a rake task that
  # cron, Heroku Scheduler, or whenever starts. Recorded as a job run under
  # its name, with its duration and whether it raised, so DeployAngel can
  # expect it on schedule like any recurring job.
  module Tasks
    NAME = /\A[[:graph:]][[:print:]]{0,199}\z/
    RAKE_PREFIX = "rake "

    module_function

    def run(name)
      name = name.to_s
      return yield unless DeployAngel.recording? && valid?(name)

      DeployAngel.add_capability("jobs")
      previous = ExecutionContext.enter(ExecutionContext::JOB)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      failed = false
      begin
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
        failed = true
        DeployAngel.record_exception(e, source: "job_class:#{name}")
        raise
      ensure
        ExecutionContext.restore(previous)
        DeployAngel.record_job(job_class: name, duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0,
          failed: failed)
      end
    end

    def valid?(name)
      return true if name.match?(NAME)

      unless @warned
        DeployAngel.configuration.logger&.warn("DeployAngel didn't record task #{name.inspect}: use a name of up to 200 printable characters")
        @warned = true
      end
      false
    end

    # Records the rake tasks a schedule names ("rake invoices:send"), so a
    # task cron starts needs no code change. Only those tasks: others, like
    # db:migrate at deploy time, aren't recurring work.
    def install_rake(schedules)
      return unless defined?(::Rake::Task)

      names = Array(schedules).filter_map { |schedule| schedule["class"].to_s.delete_prefix(RAKE_PREFIX) if schedule["class"].to_s.start_with?(RAKE_PREFIX) }
      return if names.empty?

      @rake_tasks = names.to_set
      ::Rake::Task.prepend(RakeTask) unless ::Rake::Task <= RakeTask
    rescue StandardError
      nil
    end

    def scheduled_rake_task?(name)
      @rake_tasks&.include?(name) || false
    end

    module RakeTask
      def execute(args = nil)
        return super unless DeployAngel::Tasks.scheduled_rake_task?(name)

        DeployAngel::Tasks.run("#{DeployAngel::Tasks::RAKE_PREFIX}#{name}") { super }
      end
    end
  end
end
