# frozen_string_literal: true

module DeployAngel
  # Builds Agent Protocol v1 telemetry payloads. Only mergeable values are
  # sent: counts and histograms, never percentiles or rates.
  module Protocol
    VERSION = 1
    module_function

    def telemetry(period, instance:, release:, runtime:, capabilities: %w[http])
      {
        "protocol_version" => VERSION,
        "agent" => { "name" => "deployangel-ruby", "version" => DeployAngel::VERSION },
        "runtime" => runtime,
        "instance" => instance.to_protocol,
        "release" => release.to_protocol,
        "capabilities" => capabilities,
        "period" => { "started_at" => period.started_at.iso8601, "duration_seconds" => Aggregator::PERIOD_SECONDS },
        "http" => {
          "requests" => period.requests,
          "status_counts" => period.status_counts.to_h,
          "unhandled_exceptions" => period.unhandled_exceptions,
          "latency_histogram" => period.histogram.to_protocol
        },
        "routes" => period.routes.map do |key, route|
          {
            "key" => key,
            "requests" => route.requests,
            "status_counts" => route.status_counts.to_h,
            "latency_histogram" => route.histogram.to_protocol
          }
        end,
        "exceptions" => period.exceptions.values.map { |e| e.merge("sources" => e["sources"].to_h).compact },
        "exceptions_truncated" => period.exceptions_truncated,
        "jobs" => job_stats(period.jobs),
        "job_classes" => period.job_classes.map { |key, stats| { "key" => key }.merge(job_stats(stats)) },
        "checkpoints" => period.checkpoints.map { |key, count| { "key" => key, "count" => count } }
      }
    end

    def job_stats(stats)
      {
        "processed" => stats.processed,
        "failed" => stats.failed,
        "discarded" => stats.discarded,
        "duration_histogram" => stats.duration.to_protocol,
        "queue_latency_histogram" => stats.queue_latency.to_protocol
      }
    end

    def runtime(framework: nil, framework_version: nil)
      {
        "language" => "ruby",
        "language_version" => RUBY_VERSION,
        "framework" => framework,
        "framework_version" => framework_version
      }.compact
    end
  end
end
