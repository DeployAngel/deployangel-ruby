# frozen_string_literal: true

require_relative "../deployangel"
require_relative "hanami/resolver"
require_relative "hanami/http"
require_relative "hanami/metadata"

module DeployAngel
  # The Hanami integration, for Hanami 2.2 or later. Hanami has no Railtie,
  # so the app installs it where it's configured:
  #
  #   # config/app.rb
  #   require "hanami"
  #   require "deployangel/hanami"
  #
  #   module Shop
  #     class App < Hanami::App
  #       DeployAngel::Hanami.install(self)
  #     end
  #   end
  #
  # Inside this namespace a bare Hanami means DeployAngel::Hanami, so reach
  # for the framework itself as ::Hanami.
  module Hanami
    class << self
      # Names each request's route (through the router's resolver), records
      # requests (through the app's middleware), and starts the agent once
      # the app boots (its container is finalized, as config.ru's
      # hanami/boot does). Safe to call more than once.
      def install(app)
        @installed ||= []
        return app if @installed.include?(app)

        @installed << app
        config = app.config
        config.router.resolver = Resolver.for(config.router.resolver)
        config.middleware.use(Http, config)
        app.container.after(:finalize) { DeployAngel::Hanami.start(app) }
        DeployAngel::Sidekiq.install
        DeployAngel::QueueBacklog.install
        app
      rescue StandardError => e
        DeployAngel.configuration.logger&.warn("DeployAngel failed to install in Hanami: #{e.class}: #{e.message}")
        app
      end

      # Called as the app boots. The metadata goes in at start, before the
      # reporter thread can run: the code fingerprint is built from its file
      # digests.
      def start(app)
        root = app.root.to_s
        environment = ::Hanami.env.to_s
        DeployAngel.start(
          environment: environment,
          root: root,
          framework: "hanami",
          framework_version: (::Hanami::VERSION if defined?(::Hanami::VERSION)),
          logger: logger(app),
          metadata: Metadata.new(app: app, config: DeployAngel.configuration, root: root, environment: environment)
        )
      end

      private
        def logger(app)
          app["logger"] if app.key?("logger")
        rescue StandardError
          nil
        end
    end
  end
end
