# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Measure the agent's overhead (APP_ROOT=path digests that app's files)"
task :bench do
  ruby "bench/overhead.rb", *ENV.fetch("APP_ROOT", nil)
end
