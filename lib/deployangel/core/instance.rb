# frozen_string_literal: true

require "securerandom"
require "socket"

module DeployAngel
  # One OS process. The random suffix is regenerated after fork, so a forked
  # child never reuses its parent's identity (spec §4).
  class Instance
    attr_reader :id, :host, :pid, :process_type, :started_at

    def initialize(env: ENV, now: Time.now.utc)
      @host = env["DYNO"] || Socket.gethostname
      @pid = Process.pid
      @process_type = env["DYNO"]&.split(".")&.first
      @id = "#{@host}:#{@pid}:#{SecureRandom.hex(3)}"
      @started_at = now
    end

    def to_protocol
      {
        "id" => id,
        "host" => host,
        "pid" => pid,
        "process_type" => process_type,
        "started_at" => started_at.iso8601
      }.compact
    end
  end
end
