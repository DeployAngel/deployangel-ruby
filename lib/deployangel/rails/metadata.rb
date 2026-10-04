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
          next [] if Http::HEALTH_CHECK_CONTROLLERS.include?(controller)

          path = route.path.spec.to_s.delete_suffix(FORMAT_SUFFIX)
          route.verb.to_s.split("|").reject(&:empty?).map do |verb|
            { "key" => "#{verb} #{path}", "controller" => controller, "action" => route.defaults[:action].to_s }
          end
        end.uniq { |route| route["key"] }.reject { |route| @config.ignored_route?(route["key"]) }
      rescue StandardError
        []
      end

      def job_classes
        return [] unless defined?(::ActiveJob::Base)

        ::ActiveJob::Base.descendants.filter_map(&:name).reject { |name| name == "ApplicationJob" }.sort
      rescue StandardError
        []
      end

      # Declared recurring jobs from Solid Queue, sidekiq-cron, and
      # sidekiq-scheduler. Each source is read on its own, so a file that
      # can't be read leaves the others' schedules in place.
      def schedules
        solid_queue_schedules + sidekiq_cron_schedules + sidekiq_scheduler_schedules
      end

      # Solid Queue recurring tasks for the current environment.
      def solid_queue_schedules
        path = File.join(@root, "config", "recurring.yml")
        return [] unless File.file?(path)

        config = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
        tasks = config.key?(::Rails.env) ? config[::Rails.env] : config
        Array(tasks).filter_map do |key, task|
          next unless task.is_a?(Hash) && task["schedule"]

          schedule = { "key" => key.to_s, "class" => task["class"]&.to_s, "schedule" => task["schedule"].to_s, "source" => "solid_queue",
            "time_zone" => scheduler_time_zone }
          schedule["runs_as"] = command_job_class if task["class"].nil? && task["command"]
          schedule
        end
      rescue StandardError
        []
      end

      # sidekiq-cron jobs from its schedule file (config/schedule.yml unless
      # configured otherwise), which it loads when Sidekiq starts. Jobs
      # created in code live only in Redis, which the agent doesn't read.
      def sidekiq_cron_schedules
        return [] unless defined?(::Sidekiq::Cron)

        path = yaml_path(sidekiq_cron_schedule_file) or return []
        jobs = load_yaml(path)
        jobs = jobs.map { |name, job| job.is_a?(Hash) ? job.merge("name" => name) : job } if jobs.is_a?(Hash)
        Array(jobs).filter_map do |job|
          next unless job.is_a?(Hash) && job["cron"] && job["status"].to_s != "disabled"

          { "key" => job["name"].to_s, "class" => (job["klass"] || job["class"])&.to_s, "schedule" => job["cron"].to_s,
            "source" => "sidekiq_cron", "time_zone" => local_time_zone }
        end
      rescue StandardError
        []
      end

      def sidekiq_cron_schedule_file
        configured = ::Sidekiq::Cron.configuration.cron_schedule_file if ::Sidekiq::Cron.respond_to?(:configuration)
        File.expand_path(configured || "config/schedule.yml", @root)
      rescue StandardError
        File.join(@root, "config", "schedule.yml")
      end

      # sidekiq-scheduler jobs from Sidekiq's config file, where it reads
      # them under :scheduler: :schedule: (or :schedule: in older versions).
      # A cron runs at set times; every and interval repeat from when the
      # scheduler starts, which a deploy restarts. One-off at and in jobs
      # aren't recurring, so they're left out.
      def sidekiq_scheduler_schedules
        return [] unless defined?(::SidekiqScheduler)

        path = sidekiq_config_file or return []
        config = normalize_keys(load_yaml(path) || {})
        config = config.merge(config.delete(::Rails.env.to_s) || {}) if config.is_a?(Hash)
        jobs = config.dig("scheduler", "schedule") || config["schedule"]
        return [] unless jobs.is_a?(Hash)

        jobs.filter_map do |name, job|
          next unless job.is_a?(Hash) && job["enabled"] != false && scheduled_in_this_environment?(job)

          type = %w[cron every at in interval].find { |key| Array(job[key]).first.to_s.strip != "" }
          next unless %w[cron every interval].include?(type)

          value = Array(job[type]).first.to_s
          schedule = { "key" => name.to_s, "class" => (job["class"] || name).to_s, "source" => "sidekiq_scheduler",
            "time_zone" => local_time_zone }
          type == "cron" ? schedule.merge("schedule" => value) : schedule.merge("schedule" => nil, "every" => value)
        end
      rescue StandardError
        []
      end

      # The file Sidekiq loads: the -C path in the Procfile's sidekiq
      # command, else config/sidekiq.yml.
      def sidekiq_config_file
        procfile = File.join(@root, "Procfile")
        named = File.read(procfile)[/\bsidekiq\b[^\n]*?\s(?:-C|--config)[\s=]+(\S+)/, 1] if File.file?(procfile)
        named ? yaml_path(File.expand_path(named, @root)) : yaml_path(File.join(@root, "config", "sidekiq.yml"))
      rescue StandardError
        nil
      end

      # sidekiq-scheduler skips a job whose rails_env doesn't list this one.
      def scheduled_in_this_environment?(job)
        job["rails_env"].nil? || job["rails_env"].to_s.gsub(/\s/, "").split(",").include?(::Rails.env.to_s)
      end

      # The zone sidekiq-cron and sidekiq-scheduler read a schedule in when it
      # names none: the process's local zone, as Fugit and rufus-scheduler
      # find it. nil if that can't be told.
      def local_time_zone
        ::EtOrbi.determine_local_tzone&.name if defined?(::EtOrbi)
      rescue StandardError
        nil
      end

      # The path, or the same name with .yaml if only that exists.
      def yaml_path(path)
        [ path, path.sub(/\.yml\z/, ".yaml") ].find { |candidate| File.file?(candidate) }
      end

      def load_yaml(path)
        YAML.safe_load(ERB.new(File.read(path), trim_mode: "-").result, permitted_classes: [ Symbol ], aliases: true)
      end

      # Sidekiq's config uses symbol keys (:scheduler:); compare them as
      # plain strings.
      def normalize_keys(object)
        case object
        when Hash then object.to_h { |key, value| [ key.to_s.delete_prefix(":"), normalize_keys(value) ] }
        when Array then object.map { |value| normalize_keys(value) }
        else object
        end
      end

      # A command task runs as a job of this class, so its runs show up in
      # job telemetry under that name.
      def command_job_class
        if defined?(::SolidQueue::RecurringTask) && ::SolidQueue::RecurringTask.respond_to?(:default_job_class)
          ::SolidQueue::RecurringTask.default_job_class&.name
        end || "SolidQueue::RecurringJob"
      rescue StandardError
        "SolidQueue::RecurringJob"
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
