# frozen_string_literal: true

require "logger"

module DeployAngel
  # Settings come from environment variables by default and can be
  # overridden in code with DeployAngel.configure.
  class Configuration
    TRUE_VALUES = %w[1 true yes on].freeze
    DEFAULT_ENDPOINT = "https://api.deployangel.com"

    attr_accessor :token, :endpoint, :enabled, :environments, :release_version, :revision,
      :flush_interval, :open_timeout, :read_timeout, :max_queued_payloads, :max_routes, :logger,
      :file_digests, :critical_flows, :ignored_routes

    def initialize(env = ENV)
      @token = env["DEPLOYANGEL_TOKEN"]
      @endpoint = env["DEPLOYANGEL_URL"] || DEFAULT_ENDPOINT
      @enabled = parse_boolean(env["DEPLOYANGEL_ENABLED"])
      @environments = %w[production]
      @release_version = env["DEPLOYANGEL_RELEASE_VERSION"]
      @revision = env["DEPLOYANGEL_REVISION"]
      @flush_interval = 60
      @open_timeout = 2
      @read_timeout = 5
      @max_queued_payloads = 10
      @max_routes = 100
      @logger = Logger.new($stderr, level: Logger::WARN, progname: "deployangel")
      @file_digests = parse_boolean(env["DEPLOYANGEL_FILE_DIGESTS"]) != false
      @critical_flows = {}
      # Route keys as the dashboard shows them, such as "GET /healthz".
      @ignored_routes = []
    end

    # Reports only with a token. By default only in the listed
    # environments; DEPLOYANGEL_ENABLED forces it on or off.
    def active?(environment)
      return false if token.to_s.empty? || endpoint.to_s.empty?
      return enabled unless enabled.nil?

      environments.include?(environment.to_s)
    end

    # Whether requests to a route are left out. Rails answers HEAD with the
    # GET route, so ignoring "GET /healthz" ignores "HEAD /healthz" too.
    def ignored_route?(key)
      return false if ignored_routes.empty?

      ignored_routes.include?(key) || ignored_routes.include?(key.sub(/\AHEAD /, "GET "))
    end

    private
      def parse_boolean(value)
        return nil if value.nil? || value.strip.empty?

        TRUE_VALUES.include?(value.strip.downcase)
      end
  end
end
