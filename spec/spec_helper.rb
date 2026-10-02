# frozen_string_literal: true

require "deployangel"
require "deployangel/cli"
require "deployangel/mcp"
require "stringio"
require_relative "support_fake_client"
require "rack"
require "rack/mock"

# Test-only convenience; the gem itself does not depend on ActiveSupport.
class Array
  def sole
    raise "expected exactly one element, got #{size}" unless size == 1

    first
  end
end

class FakeTransport
  attr_reader :posts
  attr_accessor :results

  def initialize(results = [])
    @posts = []
    @results = results
  end

  # Records payloads as Hashes, decoding the ones the agent queues encoded.
  def post(path, body)
    body = JSON.parse(Zlib.gunzip(body.bytes)) if body.is_a?(DeployAngel::Transport::Encoded)
    @posts << [ path, body ]
    @results.shift || DeployAngel::Transport::Result.new(:ok, 202, nil)
  end
end

class FakeClock
  attr_accessor :now

  def initialize(now)
    @now = now
  end

  def call
    @now
  end

  def advance(seconds)
    @now += seconds
  end
end

module TestHelpers
  def active_config
    DeployAngel::Configuration.new({}).tap do |config|
      config.token = "da_live_test"
      config.endpoint = "http://deployangel.test"
      config.revision = "81ac27d"
      config.release_version = "v184"
      config.logger = nil
    end
  end
end

RSpec.configure do |config|
  config.include TestHelpers
  config.disable_monkey_patching!
  config.order = :random
end
