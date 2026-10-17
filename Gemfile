# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
# Hanami 2.2 and Sinatra 3 run on Rack 2.
rack2 = ENV.fetch("HANAMI_VERSION", "").start_with?("2.") || ENV.fetch("SINATRA_VERSION", "").start_with?("3.")
gem "rack", rack2 ? ">= 2.2" : "~> 3.1"
# CI tests each supported Rails version; see .github/workflows/ci.yml.
gem "activejob", "~> #{ENV.fetch("ACTIVEJOB_VERSION", "8.1")}.0"
# Read by the agent when an app has config/schedule.rb (DeployAngel::Metadata).
gem "whenever", "~> 1.0", require: false
# Set to test the Hanami integration (spec/deployangel/hanami_spec.rb); CI
# runs the oldest and newest supported, and sets it empty on the other rows.
if (hanami = ENV["HANAMI_VERSION"].to_s).match?(/\A\d/)
  gem "hanami", "~> #{hanami}.0"
  gem "hanami-router", "~> #{hanami}.0"
  # Renamed for Hanami 3.
  gem hanami.start_with?("2.") ? "hanami-controller" : "hanami-action", "~> #{hanami}.0"
end
# Set to test the Sinatra integration (spec/deployangel/sinatra_spec.rb), as
# HANAMI_VERSION is.
if (sinatra = ENV["SINATRA_VERSION"].to_s).match?(/\A\d/)
  gem "sinatra", "~> #{sinatra}.0"
end
