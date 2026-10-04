# frozen_string_literal: true

module DeployAngel
  module Rails
    # The Rails adapter: the route table from the router, job classes from
    # Active Job, and Solid Queue's recurring tasks. The schedule files
    # sidekiq-cron and sidekiq-scheduler read, and the file digests, are
    # gathered in DeployAngel::Metadata.
    class Metadata < ::DeployAngel::Metadata
      FORMAT_SUFFIX = "(.:format)"

      def initialize(app:, config:, root:, environment: nil)
        super(config: config, root: root, environment: environment || rails_environment)
        @app = app
      end

      # Rails names the deployment, but this can be built with Rails not
      # loaded (the bench does), and an unknown environment is better than a
      # constructor that raises.
      def rails_environment
        defined?(::Rails) && ::Rails.respond_to?(:env) ? ::Rails.env.to_s : ""
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

      # Solid Queue's schedule is Rails' own; the rest are read the same way
      # on every framework.
      def schedules
        solid_queue_schedules + super
      end

      # Solid Queue recurring tasks for the current environment.
      def solid_queue_schedules
        path = File.join(@root, "config", "recurring.yml")
        return [] unless File.file?(path)

        config = YAML.safe_load(ERB.new(File.read(path)).result, aliases: true) || {}
        tasks = config.key?(@environment) ? config[@environment] : config
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
    end
  end
end
