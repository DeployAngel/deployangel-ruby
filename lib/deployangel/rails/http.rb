# frozen_string_literal: true

module DeployAngel
  module Rails
    # Rack middleware at the top of the stack, so it sees the final status
    # after Rails renders exceptions. Records the matched route pattern,
    # never the raw path, which keeps IDs out of route keys.
    class Http
      FORMAT_SUFFIX = "(.:format)"
      # Health checks: Rails' own (/up by default), OkComputer, health_check,
      # and rails-healthcheck, wherever they're mounted. Load balancers and
      # uptime monitors call them all the time and they answer fast, so
      # counting them would make any app look busy and healthy. Others can
      # be left out with config.ignored_routes.
      HEALTH_CHECK_CONTROLLERS = %w[rails/health ok_computer/ok_computer health_check/health_check healthcheck/healthchecks].freeze
      # Health checks served by a lambda or a mounted Rack app rather than a
      # controller, at a conventional path such as /healthz.
      HEALTH_CHECK_PATHS = %w[up health healthz healthcheck health_check livez readyz statusz ping].freeze

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
          return if health_check?(env)

          route = route_key(env)
          return if route && DeployAngel.configuration.ignored_route?(route)
          # Unrouted successes are static files and similar; unrouted
          # errors (such as routing 404s) are still recorded.
          return if route.nil? && status.to_i < 400

          key = route || "#{env["REQUEST_METHOD"]} unmatched"
          DeployAngel.record_exception(exception, source: "route:#{key}") if exception
          DeployAngel.record_request(
            route_key: key,
            status: status.to_i,
            duration_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0,
            unhandled: unhandled,
            # A 4xx no route matched is mostly bots probing paths like
            # /wp-admin, or middleware turning requests away. It stays
            # visible under "unmatched", but out of the app's totals, so it
            # doesn't add to the evidence or dilute real pages' latency. An
            # unrouted 5xx still counts: something broke.
            in_totals: !route.nil? || status.to_i >= 500
          )
        rescue StandardError
          nil
        end

        # A controller at a health-check path may be a real page, so only
        # controllerless routes are judged by their path.
        def health_check?(env)
          controller = env["action_dispatch.request.path_parameters"]&.dig(:controller)
          return HEALTH_CHECK_CONTROLLERS.include?(controller) if controller

          pattern = route_pattern(env) or return false
          HEALTH_CHECK_PATHS.include?(pattern.delete_suffix(FORMAT_SUFFIX).split("/").last)
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
