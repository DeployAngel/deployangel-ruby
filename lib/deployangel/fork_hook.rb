# frozen_string_literal: true

module DeployAngel
  # Resets the agent in forked children (Puma cluster mode, Sidekiq swarm,
  # etc.) using Process._fork, available since Ruby 3.1.
  module ForkHook
    def _fork
      pid = super
      DeployAngel.after_fork if pid.zero?
      pid
    end
  end
end

Process.singleton_class.prepend(DeployAngel::ForkHook)
