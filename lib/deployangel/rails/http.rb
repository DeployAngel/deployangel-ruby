# frozen_string_literal: true

module DeployAngel
  module Rails
    # Rack middleware at the top of the stack, so it sees the final status
    # after Rails renders exceptions. Records the matched route pattern,
    # never the raw path, which keeps IDs out of route keys.
    class Http
      FORMAT_SUFFIX = "(.:format)"

      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless DeployAngel.recording?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          status, headers, body = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
          record(env, 500, started, unhandled: true, exception: e)
          raise
        end
        # Rails renders some exceptions as 4xx (routing errors, RecordNotFound,
        # ParameterMissing); only those that end in a 5xx count as unhandled.
        exception = env["action_dispatch.exception"] if status.to_i >= 500
        record(env, status, started, unhandled: !exception.nil?, exception: exception)
        [ status, headers, body ]
      end

      private
        def record(env, status, started, unhandled:, exception: nil)
          route = route_key(env)
          # Unrouted successes are static files and similar; unrouted
          # errors (such as routing 404s) still count.
          return if route.nil? && status.to_i < 400

          key = route || "#{env["REQUEST_METHOD"]} unmatched"
          DeployAngel.record_exception(exception, source: "route:#{key}") if exception
          DeployAngel.record_request(
            route_key: key,
            status: status.to_i,
            duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0,
            unhandled: unhandled
          )
        rescue StandardError
          nil
        end

        def route_key(env)
          method = env["REQUEST_METHOD"]
          if (pattern = route_pattern(env))
            "#{method} #{pattern.delete_suffix(FORMAT_SUFFIX)}"
          elsif (params = env["action_dispatch.request.path_parameters"]) && params[:controller]
            "#{method} #{params[:controller]}##{params[:action]}"
          end
        end

        def route_pattern(env)
          env["action_dispatch.route_uri_pattern"] || env["action_dispatch.route"]&.path&.spec&.to_s
        end
    end
  end
end
