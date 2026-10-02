# frozen_string_literal: true

require_relative "lib/deployangel/version"

Gem::Specification.new do |spec|
  spec.name = "deployangel"
  spec.version = DeployAngel::VERSION
  spec.authors = [ "Jordan Owens" ]
  spec.email = [ "jordan@deployangel.com" ]

  spec.summary = "DeployAngel agent for Rails: production verification for every deployment."
  spec.description = "Aggregates HTTP request behavior in-process and reports one small payload per " \
    "process per minute to DeployAngel, which verifies each deployment and tells you when it is " \
    "safe to stop watching it."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.homepage = "https://deployangel.com"
  spec.metadata = {
    "homepage_uri" => "https://deployangel.com",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "lib/**/*.rake", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = [ "deployangel" ]
  spec.require_paths = [ "lib" ]
end
