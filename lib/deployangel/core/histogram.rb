# frozen_string_literal: true

module DeployAngel
  # Sparse log-scale latency histogram, scheme log1.1_ms_v1 (Agent Protocol
  # v1). The agent only counts; percentiles are computed in the cloud after
  # merging every process, because percentiles cannot be averaged.
  class Histogram
    SCHEME = "log1.1_ms_v1"
    LOG_GAMMA = Math.log(1.1)
    MAX_BUCKET = 400

    def self.bucket_for(milliseconds)
      return 0 if milliseconds < 1

      (Math.log(milliseconds) / LOG_GAMMA).ceil.clamp(0, MAX_BUCKET)
    end

    def initialize
      @counts = Hash.new(0)
    end

    def record(milliseconds)
      @counts[self.class.bucket_for(milliseconds)] += 1
    end

    def merge!(other)
      other.counts.each { |bucket, count| @counts[bucket] += count }
      self
    end

    def count
      @counts.values.sum
    end

    def to_protocol
      { "scheme" => SCHEME, "counts" => @counts.sort.to_h.transform_keys(&:to_s) }
    end

    protected
      attr_reader :counts
  end
end
