# frozen_string_literal: true

module DeployAngel
  class CLI
    # Plain-text rendering of the verdict document for people. Everything
    # shown comes from the document; nothing is inferred here.
    module Formatter
      LABELS = {
        "http_5xx_rate" => "HTTP 5xx rate", "route_5xx_rate" => "Route 5xx rate", "p95_latency" => "p95 latency",
        "job_failure_rate" => "Job failure rate", "job_duration" => "Job duration p95", "queue_latency" => "Queue latency p95",
        "new_fingerprint" => "New exception", "fingerprint_amplification" => "Exception amplification",
        "missing_recurring_job" => "Recurring job", "first_use_failure" => "First-use failure", "external_check" => "External check",
        "checkpoint_rate" => "Checkpoint"
      }.freeze
      DURATIONS = %w[p95_latency job_duration queue_latency].freeze
      COUNTS = %w[new_fingerprint checkpoint_rate].freeze

      module_function

      def verification(document)
        v = document["verification"] || {}
        clearance = document["clearance"] || {}
        lines = [ clearance["statement"] || document["summary"] ]
        lines << [ "State: #{v["state"]}", ("Verdict: #{v["verdict"]}" if v["verdict"]),
                   ("Confidence: #{v["confidence"]}" if v["confidence"]),
                   ("Coverage: #{(v["coverage"] * 100).round}%" if v["coverage"]) ].compact.join(" · ")
        if (check = v["initial_check"]) && v["verdict"].nil?
          lines << "Initial check: #{check["result"].tr("_", " ")}. Not cleared yet."
        end
        lines << "Expected clearance: #{v["expected_clearance_at"]}" if v["expected_clearance_at"] && v["verdict"].nil?
        if (source = document.dig("deployment", "promoted_from"))
          outcome = { "verified" => "cleared", "failed" => "failed", "inconclusive" => "not cleared" }.fetch(source["verdict"], "still verifying")
          lines << "Promoted from #{source["environment"]} #{source["version"] || source["commit"].to_s[0, 7]} (#{outcome})"
        end

        findings = Array(document["findings"])
        problems = findings.select { |f| %w[failing warning].include?(f["status"]) }
        if problems.any?
          lines << "Findings:"
          problems.each { |f| lines << "  #{f["status"].ljust(8)} #{finding_line(f)}" }
        end
        gathering = findings.count { |f| f["status"] == "insufficient_data" }
        lines << "#{gathering} signal#{"s" unless gathering == 1} still gathering data (--format=json for details)" if gathering.positive?
        section(lines, "New exceptions", Array(document["exceptions"])) do |e|
          "#{e["exception_class"]} in #{e["top_frame"]} (#{e["count"]}x)#{" #{e["sources"].keys.join(", ")}" if e["sources"].is_a?(Hash) && e["sources"].any?}"
        end
        unless v["verdict"] == "failed"
          section(lines, "Missing evidence", Array(clearance["missing_evidence"])) { |item| item }
        end
        section(lines, "Not observable", Array(clearance["not_observable"])) { |item| "#{item["label"]} (#{item["reason"]})" }
        section(lines, "Still watching", Array(clearance["still_watching"])) { |e| "#{e["job_class"]} (expected by #{e["expected_by"]})" }
        section(lines, "Critical flows", Array(document["critical_flows"])) do |flow|
          "#{flow["name"]}: #{flow["status"].tr("_", " ")}#{" (changed in this release)" if flow["changed_in_release"]}"
        end
        changed = Array(document["rare_items_pending"]).select { |item| item["changed_in_release"] == "changed" }
        section(lines, "Changed but not yet exercised", changed) { |item| item["key"] }
        section(lines, "Late regressions", Array(document["late_regressions"])) { |late| late["summary"] }
        lines << document["dashboard_url"] if document["dashboard_url"]
        lines.compact.join("\n")
      end

      def exception(details)
        [ "#{details["exception_class"]}: #{details["message"]}",
          "Fingerprint #{details["fingerprint"]} · first seen #{details["first_seen_at"]} (#{details["first_seen_release"]})",
          "#{details["occurrences_last_24h"]} occurrences in the last 24 hours",
          *Array(details["backtrace"]).map { |frame| "  #{frame}" } ].join("\n")
      end

      def finding_line(finding)
        label = "#{LABELS.fetch(finding["signal"], finding["signal"])} on #{finding["scope"]}"
        if COUNTS.include?(finding["signal"])
          "#{label}: #{finding["observed_value"].to_i} occurrences"
        elsif finding["baseline_value"].nil? && finding["observed_value"].nil?
          "#{label}: #{finding["threshold"]}"
        else
          "#{label}: #{value(finding, finding["baseline_value"])} -> #{value(finding, finding["observed_value"])}" \
            "#{" (#{finding["observed_n"]} samples)" if finding["observed_n"]}"
        end
      end

      def section(lines, title, items)
        return if items.empty?

        lines << "#{title}:"
        items.each { |item| lines << "  #{yield(item)}" }
      end

      def value(finding, raw)
        return "n/a" if raw.nil?
        return raw.to_i.to_s if COUNTS.include?(finding["signal"])

        DURATIONS.include?(finding["signal"]) ? "#{raw.to_f.round} ms" : "#{(raw.to_f * 100).round(2)}%"
      end
    end
  end
end
