# frozen_string_literal: true

require "rails/railtie"

module DeployAngel
  module Rails
    class Railtie < ::Rails::Railtie
      initializer "deployangel.middleware" do |app|
        app.config.middleware.insert(0, DeployAngel::Rails::Http)
      end

      initializer "deployangel.jobs" do
        ActiveSupport.on_load(:active_job) { DeployAngel::Rails::ActiveJob.install }
        DeployAngel::Sidekiq.install
      end

      # Handled reports (Rails.error.handle / Rails.error.report) are shown for
      # context; only unhandled exceptions count toward verdicts.
      initializer "deployangel.error_reporter" do |app|
        app.executor.error_reporter&.subscribe(DeployAngel::Rails::ErrorSubscriber.new) if app.executor.respond_to?(:error_reporter)
      end

      config.after_initialize do |app|
        DeployAngel::Apartment.install if DeployAngel.configuration.exception_messages
        # The metadata goes in at start, before the reporter thread can run:
        # the code fingerprint is built from its file digests.
        metadata = DeployAngel::Rails::Metadata.new(app: app, config: DeployAngel.configuration, root: ::Rails.root.to_s, environment: ::Rails.env)
        DeployAngel.start(
          environment: ::Rails.env,
          root: ::Rails.root.to_s,
          framework: "rails",
          framework_version: ::Rails.version,
          logger: ::Rails.logger,
          metadata: metadata
        )
        # A rake task cron starts loads the app (its :environment
        # prerequisite) before it runs, so the hook is in place in time.
        DeployAngel::Tasks.install_rake(metadata.schedules) if DeployAngel.recording? && Railtie.rake_process?
      end

      def self.rake_process?
        defined?(::Rake.application) && ::Rake.application.top_level_tasks.any?
      rescue StandardError
        false
      end
    end
  end
end
