# frozen_string_literal: true

require_relative "deployangel/version"
require_relative "deployangel/configuration"
require_relative "deployangel/core/histogram"
require_relative "deployangel/core/fingerprint"
require_relative "deployangel/core/release"
require_relative "deployangel/core/instance"
require_relative "deployangel/core/aggregator"
require_relative "deployangel/core/protocol"
require_relative "deployangel/core/buffer"
require_relative "deployangel/core/transport"
require_relative "deployangel/agent"
require_relative "deployangel/fork_hook"

module DeployAngel
  # Web servers and job workers report from boot, so idle processes still
  # send heartbeats.
  EAGER_PROGRAMS = /puma|unicorn|passenger|falcon|pitchfork|thrust|rackup|sidekiq|jobs|solid.queue|good_job/

  class << self
    attr_reader :agent

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Called by the Railtie after the app boots. Web server processes start
    # reporting immediately, so idle processes still send heartbeats; other
    # processes (console, rake) only report after recording a request.
    def start(environment:, root: nil, framework: nil, framework_version: nil, logger: nil)
      configuration.logger = logger if logger
      @agent = Agent.new(config: configuration, environment: environment, root: root,
        framework: framework, framework_version: framework_version, eager: server_process?)
      install_exit_hook
      @agent
    rescue StandardError => e
      configuration.logger&.warn("DeployAngel failed to start: #{e.class}: #{e.message}")
      nil
    end

    def recording?
      agent&.active? || false
    end

    def record_request(**attributes)
      agent&.record_request(**attributes)
    end

    def record_job(**attributes)
      agent&.record_job(**attributes)
    end

    def record_exception(exception, **options)
      agent&.record_exception(exception, **options)
    end

    CHECKPOINT_NAME = /\A[a-z0-9][a-z0-9_.:-]{0,99}\z/i

    # Counts a business event, such as DeployAngel.checkpoint("order.fulfilled").
    # DeployAngel learns each checkpoint's normal rate and fails a release
    # after which it drops sharply or stops. Cheap and safe to call anywhere:
    # it never raises and never touches the network.
    def checkpoint(name, count: 1)
      name = name.to_s
      unless name.match?(CHECKPOINT_NAME) && count.is_a?(Integer) && count.positive?
        configuration.logger&.warn("DeployAngel ignored checkpoint #{name.inspect}: use letters, numbers, and . _ : - (max 100)") unless @warned_checkpoint
        @warned_checkpoint = true
        return
      end

      add_capability("checkpoints")
      agent&.record_checkpoint(name, count: count)
      nil
    rescue StandardError
      nil
    end

    def capabilities
      @capabilities ||= %w[http exceptions]
    end

    def add_capability(name)
      capabilities << name unless capabilities.include?(name)
    end

    def after_fork
      agent&.after_fork!
    end

    def shutdown
      agent&.shutdown
    end

    private
      def server_process?
        defined?(::Rails::Server) || File.basename($PROGRAM_NAME.to_s).match?(EAGER_PROGRAMS)
      end

      def install_exit_hook
        return if @exit_hook_installed

        @exit_hook_installed = true
        at_exit { DeployAngel.shutdown }
      end
  end
end

require_relative "deployangel/rails/http"
require_relative "deployangel/rails/active_job"
require_relative "deployangel/rails/error_subscriber"
require_relative "deployangel/rails/metadata"
require_relative "deployangel/sidekiq"
require_relative "deployangel/rails/railtie" if defined?(::Rails::Railtie)
