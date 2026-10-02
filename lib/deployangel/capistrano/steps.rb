# frozen_string_literal: true

require "stringio"
require_relative "../cli"

module DeployAngel
  module Capistrano
    # What the Capistrano tasks do, kept free of Capistrano so it can be
    # tested on its own. Each step runs the CLI in-process and returns
    # [outcome, message], where outcome is :ok, :warn, or :fail.
    module Steps
      # Exit codes that let a deploy continue for each --until mode.
      PASSING = { "initial" => [ 0, 6 ], "verdict" => [ 0 ], "closed" => [ 0 ] }.freeze
      # Not a pass, but not a reason to fail the deploy either: warnings at
      # the initial check, not cleared, or still in progress.
      WARNING = [ 2, 3, 7 ].freeze

      module_function

      # Registration never fails a deploy: DeployAngel being unreachable or
      # misconfigured shouldn't stop a release from shipping.
      def register(token:, commit:, version: nil, endpoint: nil, output: StringIO.new, **cli)
        return [ :warn, "DeployAngel: DEPLOYANGEL_API_TOKEN is not set; release not registered" ] if blank?(token)
        return [ :warn, "DeployAngel: no commit for this release; not registered" ] if blank?(commit)

        argv = [ "release", "--commit=#{commit}", "--provider=capistrano" ]
        argv << "--version=#{version}" unless blank?(version)
        code = run(argv, token: token, endpoint: endpoint, output: output, **cli)
        code.zero? ? [ :ok, output.string.strip ] : [ :warn, "DeployAngel: could not register the release (exit #{code}): #{output.string.strip}" ]
      end

      # Waits for the release's verification. Fails the deploy only when
      # DeployAngel found a problem (exit 1).
      def verify(token:, commit:, until_mode:, timeout:, endpoint: nil, output: StringIO.new, **cli)
        return [ :warn, "DeployAngel: DEPLOYANGEL_API_TOKEN is not set; not waiting for a verdict" ] if blank?(token)

        argv = [ "verify", "--commit=#{commit}", "--wait", "--until=#{until_mode}", "--timeout=#{timeout}", "--format=text" ]
        code = run(argv, token: token, endpoint: endpoint, output: output, **cli)
        summary = output.string.strip
        if PASSING.fetch(until_mode, [ 0 ]).include?(code)
          [ :ok, summary ]
        elsif WARNING.include?(code) || code != 1
          [ :warn, "DeployAngel: #{summary}" ]
        else
          [ :fail, "DeployAngel: release failed verification\n#{summary}" ]
        end
      end

      # cli: options passed through to DeployAngel::CLI (tests inject a client).
      def run(argv, token:, endpoint:, output:, **cli)
        env = { "DEPLOYANGEL_API_TOKEN" => token }
        env["DEPLOYANGEL_URL"] = endpoint unless blank?(endpoint)
        DeployAngel::CLI.new(argv, env: env, stdout: output, stderr: output, **cli).run
      end

      def blank?(value)
        value.to_s.strip.empty?
      end
    end
  end
end
