# frozen_string_literal: true

module DeployAngel
  # The jobs this process is running now, so each payload can say how long
  # the oldest of each class has been running: a job that hangs never
  # finishes, so it never shows up in the counts. Starting and finishing is
  # a hash update under a mutex.
  class RunningJobs
    # More than any process runs at once; past it, new jobs go untracked
    # rather than growing memory.
    MAX = 1_000

    def initialize(clock:)
      @clock = clock
      @jobs = {}.compare_by_identity
      @mutex = Mutex.new
    end

    # Returns the token to pass to #finish.
    def start(job_class)
      token = Object.new
      @mutex.synchronize { @jobs[token] = [ job_class.to_s, @clock.call ] if @jobs.size < MAX }
      token
    end

    def finish(token)
      @mutex.synchronize { @jobs.delete(token) }
    end

    # { job_class => [running, oldest_running_ms] } for jobs that started by
    # at and are still running.
    def snapshot(at)
      @mutex.synchronize do
        @jobs.each_value.with_object({}) do |(job_class, started_at), running|
          next if started_at > at

          age_ms = ((at - started_at) * 1000).round
          count, oldest = running[job_class]
          running[job_class] = [ count.to_i + 1, [ oldest.to_i, age_ms ].max ]
        end
      end
    end
  end
end
