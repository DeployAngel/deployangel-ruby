# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "rack", "~> 3.1"
# CI tests each supported Rails version; see .github/workflows/ci.yml.
gem "activejob", "~> #{ENV.fetch("ACTIVEJOB_VERSION", "8.1")}.0"
# Read by the agent when an app has config/schedule.rb (DeployAngel::Metadata).
gem "whenever", "~> 1.0", require: false
