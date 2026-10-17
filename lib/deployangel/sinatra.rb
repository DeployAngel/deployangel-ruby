# frozen_string_literal: true

require_relative "../deployangel"
require_relative "sinatra/http"
require_relative "sinatra/metadata"

module DeployAngel
  # The Sinatra integration, for Sinatra 3.0 or later, as an extension:
  #
  #   require "sinatra/base"
  #   require "deployangel/sinatra"
  #
  #   class Bookshelf < Sinatra::Base
  #     register DeployAngel::Sinatra
  #     # routes after it, so their files are known
  #   end
  #
  # A classic app registers it at the top level, after `require "sinatra"`.
  # Inside this namespace a bare Sinatra means DeployAngel::Sinatra, so reach
  # for the framework itself as ::Sinatra.
  module Sinatra
    class << self
      # The apps that registered the extension, and each route's file, by
      # [verb, path]: Sinatra hands an extension each route's own block as
      # it's defined, while the route table holds only Sinatra's wrapper.
      def apps
        @apps ||= []
      end

      def route_files
        @route_files ||= {}
      end

      # Where each app was mounted (a map "/api" in config.ru), as its
      # requests show it, since the routes it declares don't include it.
      def mounts
        @mounts ||= {}
      end

      # Records the app's requests (through its middleware) and starts the
      # agent, once per process.
      def registered(app)
        return if apps.include?(app)

        apps << app
        app.use(Http, app)
        DeployAngel::Sidekiq.install
        DeployAngel::QueueBacklog.install
        start(app) unless DeployAngel.agent
      rescue StandardError => e
        DeployAngel.configuration.logger&.warn("DeployAngel failed to install in Sinatra: #{e.class}: #{e.message}")
      end

      def route_added(verb, path, block)
        file = block&.source_location&.first
        (route_files[[ verb.to_s, path.to_s ]] ||= []) << file if file
      rescue StandardError
        nil
      end

      # The metadata goes in at start, before the reporter thread can run:
      # the code fingerprint is built from its file digests. The working
      # directory is the app's root, as in most deploys.
      def start(app)
        root = Dir.pwd
        environment = app.environment.to_s
        DeployAngel.start(
          environment: environment,
          root: root,
          framework: "sinatra",
          framework_version: (::Sinatra::VERSION if defined?(::Sinatra::VERSION)),
          metadata: Metadata.new(config: DeployAngel.configuration, root: root, environment: environment)
        )
      end
    end
  end
end
