# frozen_string_literal: true

require_relative "core/release"

module DeployAngel
  # Recognizes common CI systems from their environment variables so
  # `deployangel release` needs no arguments there: the commit, a build
  # label, the provider, and a link back to the run. Inside a Kamal hook,
  # the release is Kamal's, linked to the CI run when Kamal runs in CI.
  class CiEnvironment < Struct.new(:provider, :commit, :version, :source_url)
    def self.detect(env = ENV)
      ci = detect_ci(env)
      return ci unless present?(env["KAMAL_VERSION"])

      release = Release.kamal(env["KAMAL_VERSION"])
      new("kamal", release.commit, release.version, ci&.source_url)
    end

    def self.detect_ci(env)
      if env["GITHUB_ACTIONS"] == "true"
        run_url = "#{env["GITHUB_SERVER_URL"]}/#{env["GITHUB_REPOSITORY"]}/actions/runs/#{env["GITHUB_RUN_ID"]}" if env["GITHUB_RUN_ID"]
        new("github_actions", env["GITHUB_SHA"], label("run", env["GITHUB_RUN_NUMBER"]), run_url)
      elsif env["GITLAB_CI"] == "true"
        new("gitlab_ci", env["CI_COMMIT_SHA"], label("pipeline", env["CI_PIPELINE_IID"]), env["CI_PIPELINE_URL"])
      elsif env["CIRCLECI"] == "true"
        new("circleci", env["CIRCLE_SHA1"], label("build", env["CIRCLE_BUILD_NUM"]), env["CIRCLE_BUILD_URL"])
      elsif env["BUILDKITE"] == "true"
        new("buildkite", env["BUILDKITE_COMMIT"], label("build", env["BUILDKITE_BUILD_NUMBER"]), env["BUILDKITE_BUILD_URL"])
      end
    end

    def self.label(prefix, number)
      "#{prefix}-#{number}" unless number.to_s.strip.empty?
    end

    def self.present?(value)
      !value.to_s.strip.empty?
    end

    # Only https links are kept; the cloud rejects anything else.
    def source_url
      url = self[:source_url].to_s
      url.start_with?("https://") ? url : nil
    end
  end
end
