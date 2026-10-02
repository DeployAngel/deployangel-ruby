# frozen_string_literal: true

require "digest"
require "erb"
require "yaml"

module DeployAngel
  module Rails
    # What the application contains, sent once per process: the route table,
    # job classes, declared recurring schedules, critical flows, and file
    # digests. Paths and hashes only; source code never leaves the
    # application.
    class Metadata
      DIGEST_GLOBS = %w[app/**/* config/**/* lib/**/* db/migrate/**/* Gemfile.lock].freeze
      MAX_FILES = 20_000
      DIGEST_LENGTH = 16
      FORMAT_SUFFIX = "(.:format)"

      def initialize(app:, config:, root:)
        @app = app
        @config = config
        @root = root
      end

      def to_protocol
        {
          "routes" => routes,
          "job_classes" => job_classes,
          "schedules" => schedules,
          "critical_flows" => @config.critical_flows.transform_keys(&:to_s).transform_values { |items| Array(items).map(&:to_s) },
          "file_manifest" => file_manifest.slice("hash", "count", "truncated")
        }
      end

      def files
        file_manifest["files"]
      end

      def routes
        @app.routes.routes.flat_map do |route|
          controller = route.defaults[:controller]
          next [] if controller.nil? || controller.start_with?("rails/", "active_storage/", "action_mailbox/")

          path = route.path.spec.to_s.delete_suffix(FORMAT_SUFFIX)
          route.verb.to_s.split("|").reject(&:empty?).map do |verb|
            { "key" => "#{verb} #{path}", "controller" => controller, "action" => route.defaults[:action].to_s }
          end
        end.uniq { |route| route["key"] }
      rescue StandardError
        []
      end

      def job_classes
        return [] unless defined?(::ActiveJob::Base)

        ::ActiveJob::Base.descendants.filter_map(&:name).reject { |name| name == "ApplicationJob" }.sort
      rescue StandardError
        []
      end

      # Solid Queue recurring tasks for the current environment.
      def schedules
        path = File.join(@root, "config", "recurring.yml")
        return [] unless File.file?(path)

        config = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
        tasks = config.key?(::Rails.env) ? config[::Rails.env] : config
        Array(tasks).filter_map do |key, task|
          next unless task.is_a?(Hash) && task["schedule"]

          { "key" => key.to_s, "class" => task["class"]&.to_s, "schedule" => task["schedule"].to_s, "source" => "solid_queue",
            "time_zone" => scheduler_time_zone }
        end
      rescue StandardError
        []
      end

      # The zone Solid Queue reads a schedule in when the schedule names
      # none: its own setting, config.time_zone by default. nil when that's
      # the system's local time or Solid Queue predates the setting, and
      # DeployAngel then doesn't assume one.
      def scheduler_time_zone
        ::SolidQueue.time_zone if defined?(::SolidQueue) && ::SolidQueue.respond_to?(:time_zone)
      rescue StandardError
        nil
      end

      def file_manifest
        @file_manifest ||= begin
          if @config.file_digests
            paths = DIGEST_GLOBS.flat_map { |glob| Dir.glob(File.join(@root, glob)) }.select { |path| File.file?(path) }.sort
            truncated = paths.size > MAX_FILES
            files = paths.first(MAX_FILES).to_h do |path|
              [ path.delete_prefix(@root).delete_prefix("/"), Digest::SHA256.file(path).hexdigest[0, DIGEST_LENGTH] ]
            end
            hash = Digest::SHA256.hexdigest(files.map { |path, digest| "#{path}:#{digest}" }.join("\n"))
            { "hash" => hash, "count" => files.size, "truncated" => truncated, "files" => files }
          else
            { "hash" => nil, "count" => 0, "truncated" => false, "files" => {} }
          end
        end
      rescue StandardError
        { "hash" => nil, "count" => 0, "truncated" => false, "files" => {} }
      end
    end
  end
end
