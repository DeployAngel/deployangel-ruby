# frozen_string_literal: true

require "digest"
require "erb"
require "yaml"

module DeployAngel
  # What the application contains, sent once per process: the route table,
  # job classes, declared recurring schedules, critical flows, and file
  # digests. Paths and hashes only; source code never leaves the
  # application.
  #
  # Routes and job classes are the framework's to answer, so this base
  # reports none and DeployAngel::Rails::Metadata adds them. What no
  # framework owns is gathered here: the schedule files sidekiq-cron and
  # sidekiq-scheduler read, and the file digests.
  class Metadata
    # A Rails-style layout, which most Ruby apps share. An adapter for a
    # framework laid out differently overrides digest_globs.
    DIGEST_GLOBS = %w[app/**/* config/**/* lib/**/* db/migrate/**/* Gemfile.lock].freeze
    MAX_FILES = 20_000
    DIGEST_LENGTH = 16

    # environment names the deployment ("production"), which the schedulers
    # read to tell whether a job runs here. The agent already knows it, so
    # nothing in this class reaches for a framework to ask.
    def initialize(config:, root:, environment:)
      @config = config
      @root = root
      @environment = environment.to_s
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

    # The routes the app serves, as { "key", "controller", "action" }.
    def routes
      []
    end

    # The job classes the app defines, by name.
    def job_classes
      []
    end

    # The files digested to tell which routes a release changed, as globs
    # relative to the app's root. Only paths and hashes are sent.
    def digest_globs
      DIGEST_GLOBS
    end

    # Declared recurring jobs. Each source is read on its own, so a file that
    # can't be read leaves the others' schedules in place.
    def schedules
      sidekiq_cron_schedules + sidekiq_scheduler_schedules + whenever_schedules + configured_schedules
    end

    # config.recurring_jobs: work scheduled outside the app, by the name it
    # runs under. A schedule without a zone is read in the server's.
    def configured_schedules
      Array(@config.recurring_jobs).filter_map do |name, schedule|
        next if name.to_s.strip.empty? || schedule.to_s.strip.empty?

        { "key" => name.to_s, "class" => name.to_s, "schedule" => schedule.to_s, "source" => "config", "time_zone" => local_time_zone }
      end
    rescue StandardError
      []
    end

    WHENEVER_FILE = "config/schedule.rb"
    WHENEVER_JOB = /\A\s*(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)(?:\.set\(.*?\))?\.(?:perform_now|perform_later|perform_async|perform_inline)\b/m

    # The whenever gem's config/schedule.rb, which it turns into the server's
    # crontab on deploy. Read with whenever's own parser, so times come out
    # as cron reads them, in the server's zone. Rake tasks are recorded by
    # name (Tasks.install_rake); a runner that performs a job class is
    # matched by that class. Other commands can't be told apart, so they're
    # left to config.recurring_jobs and DeployAngel.task.
    def whenever_schedules
      path = File.join(@root, WHENEVER_FILE)
      return [] unless File.file?(path) && whenever_loaded?

      list = ::Whenever::JobList.new(file: path)
      chronic = list.instance_variable_get(:@chronic_options) || {}
      by_time = (list.instance_variable_get(:@jobs) || {}).values.flat_map(&:to_a)
      by_time.flat_map do |time, jobs|
        Array(jobs).flat_map { |job| whenever_entries(time, job, chronic) }
      end.uniq { |schedule| schedule["key"] }
    rescue StandardError, ScriptError
      []
    end

    def whenever_loaded?
      require "whenever"
      true
    rescue LoadError
      false
    end

    def whenever_entries(time, job, chronic)
      name = whenever_job_name(job) or return []
      crons = ::Whenever::Output::Cron.enumerate(time).flat_map do |each|
        ::Whenever::Output::Cron.enumerate(job.at, false).map do |at|
          ::Whenever::Output::Cron.new(each, nil, at, chronic_options: chronic).time_in_cron_syntax.to_s
        end
      end.uniq.reject { |cron| cron.empty? || cron == "@reboot" }
      crons.map do |cron|
        { "key" => crons.one? ? name : "#{name} (#{cron})", "class" => name, "schedule" => cron, "source" => "whenever",
          "time_zone" => local_time_zone }
      end
    end

    def whenever_job_name(job)
      template = job.instance_variable_get(:@template).to_s
      task = job.instance_variable_get(:@options)&.dig(:task).to_s.strip
      if template.match?(/\brake :task\b/)
        rake = task.split.first.to_s
        "#{Tasks::RAKE_PREFIX}#{rake}" unless rake.empty?
      elsif template.include?(":runner_command")
        task[WHENEVER_JOB, 1]
      end
    end

    # sidekiq-cron jobs from its schedule file (config/schedule.yml unless
    # configured otherwise), which it loads when Sidekiq starts, or from
    # the file in config.sidekiq_cron_schedule_file for an app that loads
    # them itself. Jobs created in code live only in Redis, which the agent
    # doesn't read.
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
      configured = @config.sidekiq_cron_schedule_file
      configured ||= ::Sidekiq::Cron.configuration.cron_schedule_file if ::Sidekiq::Cron.respond_to?(:configuration)
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
      config = config.merge(config.delete(@environment) || {}) if config.is_a?(Hash)
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
      job["rails_env"].nil? || job["rails_env"].to_s.gsub(/\s/, "").split(",").include?(@environment)
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

    # Built once per process, by the reporter: the metadata send and the
    # code fingerprint (Release.code_fingerprint) both read it.
    def file_manifest
      @file_manifest ||= begin
        if @config.file_digests
          paths = digest_globs.flat_map { |glob| Dir.glob(File.join(@root, glob)) }.select { |path| File.file?(path) }.uniq.sort
          truncated = paths.size > MAX_FILES
          files = paths.first(MAX_FILES).to_h do |path|
            [ path.delete_prefix(@root).delete_prefix("/"), Digest::SHA256.file(path).hexdigest[0, DIGEST_LENGTH] ]
          end
          hash = Digest::SHA256.hexdigest(files.map { |path, digest| "#{path}:#{digest}" }.join("\n"))
          { "hash" => hash, "count" => files.size, "truncated" => truncated, "files" => files }
        else
          { "hash" => nil, "count" => 0, "truncated" => false, "files" => {} }
        end
      rescue StandardError
        { "hash" => nil, "count" => 0, "truncated" => false, "files" => {} }
      end
    end
  end
end
