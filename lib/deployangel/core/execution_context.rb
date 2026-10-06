# frozen_string_literal: true

module DeployAngel
  # The unit of work the current fiber is running: HTTP while the request
  # middleware handles a request, JOB while job instrumentation runs a job,
  # and nil otherwise (console, rake tasks, boot, a thread of the app's own).
  # Checkpoints read it to say where they were recorded.
  #
  # Thread.current[] is fiber-local, like Rails' isolated execution state, so
  # requests served concurrently in threads (Puma) or fibers (Falcon) each
  # see their own. Every integration restores the previous value when its
  # unit ends, even when it raises, so the innermost unit wins when they nest
  # (a job performed inline during a request), and nothing leaks into the
  # next request a reused thread serves.
  module ExecutionContext
    KEY = :__deployangel_execution_context
    HTTP = :http
    JOB = :job

    module_function

    def current
      Thread.current[KEY]
    end

    # Returns the previous context, to hand back to restore.
    def enter(kind)
      previous = Thread.current[KEY]
      Thread.current[KEY] = kind
      previous
    end

    def restore(previous)
      Thread.current[KEY] = previous
    end
  end
end
