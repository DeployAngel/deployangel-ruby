# frozen_string_literal: true

require "time"
require_relative "configuration"
require_relative "metadata"
require_relative "rails/metadata"
require_relative "core/release"

module DeployAngel
  # `deployangel doctor`: what this checkout will report, and what
  # DeployAngel has seen of the app so far (GET /api/v1/setup), as checks
  # with what to do about each. It runs without booting the app, so it
  # reads only the schedules kept in files.
  class Doctor
    # status is ok, warn, error, or info. Only errors fail the command.
    Check = Struct.new(:status, :message, :fix, keyword_init: true) do
      def to_h = { "status" => status.to_s, "message" => message, "fix" => fix }.compact
    end

    SOURCES = { "solid_queue" => "Solid Queue", "sidekiq_cron" => "sidekiq-cron", "sidekiq_scheduler" => "sidekiq-scheduler",
                "whenever" => "whenever", "good_job" => "GoodJob", "config" => "agent config" }.freeze
    TOKEN_HELP = "Set DEPLOYANGEL_API_TOKEN (a \"CLI & coding agents\" token from the app's Settings) or DEPLOYANGEL_TOKEN " \
                 "(the app's agent token), then run this again."
    MAX_HOSTS = 5

    attr_reader :setup

    # client is nil when no token is set; the local checks still run.
    def initialize(root:, client:, env: {})
      @root = root
      @client = client
      @env = env
    end

    def checks
      @checks ||= begin
        @setup, server = server_checks
        [ *agent_checks, here_check, schedule_check, *server, release_check, *comparison_checks ].compact
      end
    end

    def failed?
      checks.any? { |check| check.status == :error }
    end

    def to_h
      { "checks" => checks.map(&:to_h), "setup" => setup }
    end

    private
      def agent_checks
        lock = read("Gemfile.lock") or return []
        version = lock[/^    deployangel \(([^)]+)\)/, 1]
        return [ Check.new(status: :ok, message: "Agent: deployangel #{version} in Gemfile.lock") ] if version

        [ Check.new(status: :error, message: "The agent isn't in the bundle", fix: "Add gem \"deployangel\" to the Gemfile and run bundle install.") ]
      end

      def schedule_check
        counts = local_schedules.group_by { |schedule| schedule["source"] }.map { |source, list| "#{SOURCES.fetch(source, source)} #{list.size}" }
        later = [ ("GoodJob's cron" if read("Gemfile.lock").to_s.include?(" good_job (")), "config.recurring_jobs" ].compact
        note = "#{later.join(" and ")} #{later.one? ? "is" : "are"} read when the app runs."
        if counts.any?
          Check.new(status: :ok, message: "#{count(local_schedules.size, "scheduled job")} in this checkout (#{counts.join(", ")}). #{note}")
        else
          Check.new(status: :info, message: "No scheduled jobs in this checkout's schedule files. #{note}")
        end
      end

      # The token's app and what DeployAngel has seen of it.
      def server_checks
        return [ nil, [ Check.new(status: :warn, message: "No token, so only this checkout was checked", fix: TOKEN_HELP) ] ] unless @client

        setup = @client.setup
        checks = [ app_check(setup), agent_check(setup), metadata_check(setup), *gap_checks(setup), progress_check(setup) ]
        [ setup, checks.compact ]
      rescue Client::Unauthorized => e
        [ nil, [ Check.new(status: :error, message: "DeployAngel rejected the token (#{e.message})", fix: TOKEN_HELP) ] ]
      rescue Client::NotFound
        [ nil, [ Check.new(status: :warn, message: "This DeployAngel server doesn't support doctor yet; only this checkout was checked") ] ]
      rescue Client::Error => e
        [ nil, [ Check.new(status: :error, message: "Couldn't reach DeployAngel: #{e.message}") ] ]
      end

      def app_check(setup)
        app = setup["app"] || {}
        Check.new(status: :ok, message: "App: #{app["name"]} (#{app["environment"]})")
      end

      def agent_check(setup)
        agent = setup["agent"] || {}
        processes = Array(agent["processes"])
        if agent["reporting"]
          releases = processes.map { |process| process["release"] }.uniq
          release = releases.compact.one? && releases.size == 1 ? ", release #{releases.first}" : ""
          from = processes.any? ? " from #{hosts(processes)}" : ""
          Check.new(status: :ok, message: "Agent reporting#{from}#{release}")
        elsif agent["last_received_at"]
          Check.new(status: :warn, message: "The agent last reported #{time(agent["last_received_at"])}, and nothing since",
            fix: "Check the app is running, and that DEPLOYANGEL_TOKEN is still set on its processes.")
        else
          Check.new(status: :warn, message: "The agent hasn't reported yet",
            fix: "Deploy with DEPLOYANGEL_TOKEN set to the app's agent token (Settings, Tokens: \"Deployed application\").")
        end
      end

      def metadata_check(setup)
        metadata = setup["metadata"] or return
        jobs = Array(setup["scheduled_jobs"])
        problems = jobs.select { |job| %w[overdue failed].include?(job["status"]) }
        problem_text = problems.any? ? ", #{problems.size} needing attention (#{problems.first(3).map { |job| "#{job["label"]} #{job["status"]}" }.join(", ")})" : ""
        Check.new(status: problems.any? ? :warn : :ok,
          message: "Reported: #{count(metadata["routes"], "route")}, #{count(metadata["job_classes"], "job class", "job classes")}, " \
                   "#{count(metadata["schedules"], "scheduled job")}#{problem_text}",
          fix: ("See them on the app page, under Scheduled jobs." if problems.any?))
      end

      def gap_checks(setup)
        Array(setup["gaps"]).map { |gap| Check.new(status: :warn, message: gap["title"], fix: gap["fix"]) }
      end

      def progress_check(setup)
        deployments = setup["deployments"] || {}
        latest = deployments["latest"]
        message = if setup["warm_up_ends_at"]
          "Learning what's normal for this app until #{time(setup["warm_up_ends_at"])}; deploys before then are checked, not cleared"
        elsif latest
          "#{count(deployments["count"], "deploy")} so far; the latest, #{latest["label"]}, is #{latest["verdict"] || latest["state"]}"
        elsif setup.dig("agent", "last_received_at")
          "No deploys yet: your next deploy gets the first verdict"
        end
        message && Check.new(status: :info, message: message)
      end

      # Run where the app runs (`heroku run`, a container shell), the release
      # this process would report. On a developer machine it would only be
      # the checkout's git HEAD, which says nothing about production, so
      # it's left out there.
      def here_check
        release = Release.resolve(config: Configuration.new(@env), env: @env, root: @root)
        if release.unknown?
          return unless where_the_app_runs?

          Check.new(status: :warn, message: "Here, the agent can't tell which release is running",
            fix: "Set DEPLOYANGEL_REVISION to the deployed commit, or see https://deployangel.com/docs#containers.")
        elsif release.source != "git_head"
          Check.new(status: :ok, message: "Here, the agent would report release #{release.version || release.commit} (from #{release.source})")
        end
      rescue StandardError
        nil
      end

      def where_the_app_runs?
        !@env["DEPLOYANGEL_TOKEN"].to_s.empty? && @env["DEPLOYANGEL_API_TOKEN"].to_s.empty?
      end

      # How production will know the release, judged from what's reporting
      # once anything is, and from this checkout's deploy files before then.
      def release_check
        return if Array(setup&.dig("agent", "processes")).any?

        if file?("config/deploy.yml")
          Check.new(status: :ok, message: "Kamal deploys: the agent reads the release from KAMAL_VERSION")
        elsif file?("render.yaml")
          Check.new(status: :ok, message: "Render deploys: the agent reads the commit from RENDER_GIT_COMMIT")
        elsif read(".do/app.yaml").to_s.include?("DEPLOYANGEL_REVISION")
          Check.new(status: :ok, message: "The DigitalOcean app spec passes the commit in DEPLOYANGEL_REVISION")
        elsif (dockerfile = read("Dockerfile"))
          if dockerfile.include?("DEPLOYANGEL_REVISION")
            Check.new(status: :ok, message: "The Dockerfile passes the commit in DEPLOYANGEL_REVISION")
          else
            # Platforms can pass it another way, so this is advice until the
            # agent reports: then the release it names settles it.
            Check.new(status: :info, message: "The Dockerfile doesn't set DEPLOYANGEL_REVISION; unless your platform passes the commit, " \
              "releases won't be named by commit",
              fix: "Run `deployangel install docker`, then build with --build-arg GIT_SHA=$(git rev-parse HEAD).")
          end
        elsif file?("Capfile")
          Check.new(status: :ok, message: "Capistrano deploys: the agent reads the REVISION file Capistrano writes")
        elsif file?("Procfile") || file?("app.json")
          Check.new(status: :info, message: "On Heroku, turn on dyno metadata so the agent knows the commit",
            fix: "heroku labs:enable runtime-dyno-metadata && heroku labs:enable runtime-dyno-build-metadata")
        end
      end

      # Schedules in this checkout that the running agent hasn't reported:
      # not deployed yet, or an agent too old to read them.
      def comparison_checks
        reported = setup&.dig("metadata", "schedules") or return []
        return [] unless local_schedules.size > reported

        [ Check.new(status: :warn, message: "This checkout declares #{count(local_schedules.size, "scheduled job")}; the running agent reported #{reported}",
          fix: "Deploy this code, or update the agent: whenever schedules need deployangel 0.1.22 or later, GoodJob's 0.1.23.") ]
      end

      def local_schedules
        @local_schedules ||= begin
          config = Configuration.new({})
          metadata = if file?("config/application.rb")
            Rails::Metadata.new(app: nil, config: config, root: @root, environment: "production")
          else
            DeployAngel::Metadata.new(config: config, root: @root, environment: "production")
          end
          metadata.schedules
        rescue StandardError, ScriptError
          []
        end
      end

      def hosts(processes)
        names = processes.map { |process| process["processes"].to_i > 1 ? "#{process["host"]} ×#{process["processes"]}" : process["host"] }
        total = processes.sum { |process| process["processes"].to_i }
        listed = names.first(MAX_HOSTS).join(", ")
        listed += ", and others" if names.size > MAX_HOSTS
        "#{count(total, "process", "processes")} (#{listed})"
      end

      def time(iso)
        Time.iso8601(iso).utc.strftime("%b %-d, %H:%M UTC")
      rescue ArgumentError, TypeError
        iso.to_s
      end

      def count(number, singular, plural = "#{singular}s")
        "#{number.to_i} #{number.to_i == 1 ? singular : plural}"
      end

      def file?(relative) = File.file?(File.join(@root, relative))

      def read(relative)
        path = File.join(@root, relative)
        File.read(path) if File.file?(path)
      rescue SystemCallError
        nil
      end
  end
end
