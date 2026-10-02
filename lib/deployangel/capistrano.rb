# frozen_string_literal: true

# Capistrano integration. Add to the Capfile:
#
#   require "deployangel/capistrano"
#
# After each deploy is published, the release is registered with
# DeployAngel from the machine running `cap`, which needs a "CI deploys"
# token in DEPLOYANGEL_API_TOKEN. See lib/deployangel/capistrano/tasks.rake
# for the settings.
require_relative "capistrano/steps"

load File.expand_path("capistrano/tasks.rake", __dir__)
