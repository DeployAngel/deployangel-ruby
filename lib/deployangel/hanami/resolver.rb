# frozen_string_literal: true

module DeployAngel
  module Hanami
    # Hanami's router doesn't record which route a request matched, only its
    # parameters. Its resolver, which turns each route's `to:` into an
    # endpoint as the routes are defined, is told the route's full pattern
    # (scopes' and slices' prefixes included), so this one wraps each
    # endpoint to note the pattern on the request, as Rails' router does.
    # It subclasses whatever resolver the app has configured.
    module Resolver
      ROUTE_PATTERN = "deployangel.route_pattern"

      def self.for(base)
        return base if base <= Tagging

        Class.new(base) do
          prepend Tagging

          def self.name = "DeployAngel::Hanami::Resolver(#{superclass.name})"
        end
      end

      module Tagging
        def call(path, endpoint)
          resolved = super
          pattern = path.to_s
          lambda do |env, *rest|
            env[ROUTE_PATTERN] = pattern
            resolved.call(env, *rest)
          end
        end
      end
    end
  end
end
