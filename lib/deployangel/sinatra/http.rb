# frozen_string_literal: true

module DeployAngel
  module Sinatra
    # The Sinatra adapter: route identity from the route Sinatra matched,
    # with the app's mount point, and the exceptions Sinatra renders itself.
    # Everything else about recording a request is in DeployAngel::Rack::Http.
    class Http < ::DeployAngel::Rack::Http
      def initialize(app, sinatra_app = nil)
        super(app)
        @sinatra_app = sinatra_app
      end

      private
        # Sinatra names the route it ran ("GET /books/:id"), the last one when
        # a route passes, but not the mount point (SCRIPT_NAME), which
        # Sinatra strips from the path it matches.
        def route_pattern(env)
          route = env["sinatra.route"] or return nil

          pattern = route.split(" ", 2).last
          mount = env["SCRIPT_NAME"].to_s.chomp("/")
          note_mount(mount) unless mount.empty?
          "#{mount}#{pattern}"
        end

        # Sinatra rescues an exception, renders its error page, and keeps the
        # exception here.
        def rendered_exception(env)
          env["sinatra.error"]
        end

        def note_mount(mount)
          DeployAngel::Sinatra.mounts[@sinatra_app] ||= mount if @sinatra_app
        rescue StandardError
          nil
        end
    end
  end
end
