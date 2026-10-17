# frozen_string_literal: true

module DeployAngel
  module Sinatra
    # The Sinatra adapter: the route table of every app that registered the
    # extension, with each route's file, and a typical Sinatra layout for the
    # file digests. Schedules read on every framework, and the digests
    # themselves, are in DeployAngel::Metadata.
    class Metadata < ::DeployAngel::Metadata
      DIGEST_GLOBS = %w[*.rb *.ru app/**/* lib/**/* config/**/* routes/**/* views/**/* models/**/* helpers/**/*
                        controllers/**/* db/migrate/**/* Gemfile.lock].freeze
      SKIPPED_METHODS = %w[HEAD OPTIONS].freeze

      def digest_globs
        DIGEST_GLOBS
      end

      def routes
        DeployAngel::Sinatra.apps.flat_map { |app| app_routes(app) }
          .uniq { |route| route["key"] }
      rescue StandardError
        []
      end

      private
        def app_routes(app)
          mount = DeployAngel::Sinatra.mounts[app].to_s
          app.routes.flat_map do |verb, signatures|
            next [] if SKIPPED_METHODS.include?(verb)

            signatures.filter_map do |pattern, *|
              path = pattern.to_s
              key = "#{verb} #{mount}#{path}"
              next if health_check_path?(path) || @config.ignored_route?(key)

              route = { "key" => key }
              files = Array(DeployAngel::Sinatra.route_files[[ verb, path ]]).filter_map { |file| app_relative(file) }.uniq
              route["files"] = files unless files.empty?
              route
            end
          end
        rescue StandardError
          []
        end

    end
  end
end
