# frozen_string_literal: true

module DeployAngel
  module Rails
    # The Rails adapter: route identity from Action Dispatch, and the
    # exceptions Rails renders itself. Everything else about recording a
    # request is in DeployAngel::Rack::Http.
    class Http < ::DeployAngel::Rack::Http
      FORMAT_SUFFIX = "(.:format)"
      # Health checks: Rails' own (/up by default), OkComputer, health_check,
      # and rails-healthcheck, wherever they're mounted. A lambda or a
      # mounted Rack app at a conventional path is left out by the Rack
      # adapter's HEALTH_CHECK_PATHS.
      HEALTH_CHECK_CONTROLLERS = %w[rails/health ok_computer/ok_computer health_check/health_check healthcheck/healthchecks].freeze

      private
        def route_pattern(env)
          pattern = env["action_dispatch.route_uri_pattern"] || env["action_dispatch.route"]&.path&.spec&.to_s
          pattern&.delete_suffix(FORMAT_SUFFIX)
        end

        # Rails renders some exceptions as 4xx (routing errors,
        # RecordNotFound, ParameterMissing), which is why only a 5xx asks.
        def rendered_exception(env)
          env["action_dispatch.exception"]
        end

        # A controller at a health-check path may be a real page, so only
        # controllerless routes (a lambda or a mounted Rack app) are judged by
        # their path, by its last segment as in 0.1.8. A controller decides
        # anything else, so Rails needs none of the Rack base's placeholder
        # rule.
        def health_check?(env)
          controller = controller_name(env)
          return HEALTH_CHECK_CONTROLLERS.include?(controller) if controller

          pattern = route_pattern(env) or return false
          HEALTH_CHECK_PATHS.include?(pattern.split("/").last)
        end

        # The matched pattern, else the controller and action, which a route
        # reached without one still has.
        def route_key(env)
          super || begin
            controller = controller_name(env)
            "#{env["REQUEST_METHOD"]} #{controller}##{env["action_dispatch.request.path_parameters"][:action]}" if controller
          end
        end

        def controller_name(env)
          env["action_dispatch.request.path_parameters"]&.dig(:controller)
        end
    end
  end
end
