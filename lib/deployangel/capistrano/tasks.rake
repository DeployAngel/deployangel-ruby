# frozen_string_literal: true

# Loaded by `require "deployangel/capistrano"`. Settings (config/deploy.rb):
#
#   set :deployangel_api_token, ENV["DEPLOYANGEL_API_TOKEN"]  # a "CI deploys" token
#   set :deployangel_version, -> { fetch(:release_timestamp) } # label; nil to use the commit
#   set :deployangel_wait, false       # or "initial" / "verdict" to wait after deploying
#   set :deployangel_wait_timeout, "15m"
#   set :deployangel_url, nil          # defaults to https://api.deployangel.com
#   set :deployangel_register, true    # false to turn the integration off (e.g. per stage)

namespace :load do
  task :defaults do
    set :deployangel_register, true
    set :deployangel_api_token, -> { ENV["DEPLOYANGEL_API_TOKEN"] }
    set :deployangel_version, -> { fetch(:release_timestamp) }
    set :deployangel_wait, false
    set :deployangel_wait_timeout, "15m"
    set :deployangel_url, -> { ENV["DEPLOYANGEL_URL"] }
  end
end

namespace :deployangel do
  desc "Register this release with DeployAngel so it gets a verdict"
  task :register do
    next unless fetch(:deployangel_register)

    run_locally do
      outcome, message = DeployAngel::Capistrano::Steps.register(token: fetch(:deployangel_api_token),
        commit: fetch(:current_revision), version: fetch(:deployangel_version), endpoint: fetch(:deployangel_url))
      outcome == :ok ? info(message) : warn(message)
    end
  end

  desc "Wait for DeployAngel's verdict on this release (set :deployangel_wait to enable)"
  task :verify do
    mode = fetch(:deployangel_wait)
    next unless fetch(:deployangel_register) && mode

    run_locally do
      outcome, message = DeployAngel::Capistrano::Steps.verify(token: fetch(:deployangel_api_token),
        commit: fetch(:current_revision), until_mode: mode.to_s, timeout: fetch(:deployangel_wait_timeout),
        endpoint: fetch(:deployangel_url))
      case outcome
      when :ok then info(message)
      when :warn then warn(message)
      else raise message
      end
    end
  end
end

after "deploy:published", "deployangel:register"
after "deploy:finished", "deployangel:verify"
