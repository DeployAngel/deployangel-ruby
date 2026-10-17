# frozen_string_literal: true

module DeployAngel
  # Rack adapters. Inside this namespace a bare Rack means DeployAngel::Rack,
  # so reach for the Rack gem itself as ::Rack.
  module Rack
    # The base for a framework's request middleware, not a middleware to use
    # on its own: without an adapter naming routes, every successful request
    # is unrouted and skipped, and only errors are recorded, as "unmatched".
    # An adapter subclasses it, answers route_pattern (and rendered_exception
    # if the framework renders exceptions itself), and is inserted at the top
    # of the stack, so it sees the final status after the framework's own
    # error pages. A framework that renders exceptions outside its app
    # middleware instead answers raised_status. DeployAngel::Rails::Http and
    # DeployAngel::Hanami::Http are the adapters.
    #
    # A request is only counted against a route pattern the framework
    # matched, never the raw path, which keeps IDs out of route keys.
    class Http
      # Health checks served by a lambda or a mounted Rack app at a
      # conventional path. Load balancers and uptime monitors call them all
      # the time and they answer fast, so counting them would make any app
      # look busy and healthy. Others can be left out with
      # config.ignored_routes.
      HEALTH_CHECK_PATHS = %w[up health healthz healthcheck health_check livez readyz statusz ping].freeze

      def initialize(app)
        @app = app
      end

      # Set on a request once a DeployAngel middleware records it. Apps nest
      # (a Sinatra app used as another's middleware, or mounted inside
      # Rails), so a request can pass through more than one; only the
      # outermost records it.
      RECORDED = "deployangel.recorded"

      def call(env)
        return @app.call(env) if !DeployAngel.recording? || env[RECORDED]

        env[RECORDED] = true
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Redaction.request_host = env["HTTP_HOST"]
        # Checkpoints recorded from here until the app returns count as
        # recorded in a request.
        previous_context = ExecutionContext.enter(ExecutionContext::HTTP)
        begin
          status, headers, body = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException -- recorded, then re-raised untouched
          # A framework that renders exceptions outside this middleware turns
          # some into a 4xx; only one that ends in a 5xx is unhandled.
          status = raised_status(env, e)
          record(env, status, started, unhandled: status >= 500, exception: (e if status >= 500))
          raise
        ensure
          ExecutionContext.restore(previous_context)
        end
        # A framework that renders an exception itself swallows it before it
        # reaches this middleware, and renders some as 4xx; only those that
        # end in a 5xx count as unhandled.
        exception = rendered_exception(env) if status.to_i >= 500
        record(env, status, started, unhandled: !exception.nil?, exception: exception)
        [ status, headers, body ]
      end

      private
        # The route the framework matched, as a pattern with placeholders
        # ("/users/:id"), or nil when nothing matched. Placeholders may be
        # spelled :name, *name, or {name}; health_check? reads them, and
        # otherwise the pattern is only ever compared with itself.
        def route_pattern(env)
          nil
        end

        # An exception the framework caught and rendered itself, or nil. Only
        # asked for on a 5xx.
        def rendered_exception(env)
          nil
        end

        # The status a raised exception will be rendered as, by a framework
        # that renders it after this middleware. 500 unless an adapter knows.
        def raised_status(_env, _exception)
          500
        end

        def route_key(env)
          pattern = route_pattern(env) or return nil

          "#{env["REQUEST_METHOD"]} #{pattern}"
        end

        # A static route ending in a health-check name, such as "/healthz" or
        # "/api/livez". A route with a placeholder, such as
        # "/patients/:id/health", is a real page about something, so it's
        # recorded.
        def health_check?(env)
          pattern = route_pattern(env) or return false

          segments = pattern.split("/").reject(&:empty?)
          HEALTH_CHECK_PATHS.include?(segments.last) && segments.none? { |segment| placeholder?(segment) }
        end

        def placeholder?(segment)
          segment.start_with?(":", "*") || segment.include?("{")
        end

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
    end
  end
end
