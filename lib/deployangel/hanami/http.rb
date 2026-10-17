# frozen_string_literal: true

module DeployAngel
  module Hanami
    # The Hanami adapter: route identity from DeployAngel's resolver, and the
    # status Hanami renders a raised exception as. Everything else about
    # recording a request is in DeployAngel::Rack::Http.
    #
    # Hanami renders exceptions in middleware outside the app's own, so this
    # one sees each exception raised, before it's rendered. Hanami also
    # raises to say a route wasn't found, and renders that as a 404, so the
    # status comes from the same mapping Hanami uses.
    class Http < ::DeployAngel::Rack::Http
      def initialize(app, hanami_config = nil)
        super(app)
        @hanami_config = hanami_config
      end

      private
        def route_pattern(env)
          env[Resolver::ROUTE_PATTERN]
        end

        # config.render_error_responses, by the exception class's exact name,
        # as Hanami reads it. Without render_errors (development, tests),
        # the exception reaches the server, which answers 500.
        def raised_status(_env, exception)
          return 500 unless @hanami_config&.render_errors

          status = @hanami_config.render_error_responses[exception.class.name] || :internal_server_error
          ::Rack::Utils.status_code(status)
        rescue StandardError
          500
        end
    end
  end
end
