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
        lines = [ statement(document), status_line(document), *notes(document) ]
        problems = problems(document)
        if problems.any?
          lines << "Findings:"
          problems.each { |f| lines << "  #{f["status"].ljust(8)} #{finding_line(f)}" }
        end
        if (gathering = gathering_line(document))
          lines << "#{gathering} (--format=json for details)"
        end
        sections(document).each { |title, items| section(lines, title, items) }
        lines << document["dashboard_url"] if document["dashboard_url"]
        lines.compact.join("\n")
      end

      # The same document as GitHub-flavored Markdown, for a CI job's
      # summary page.
      def markdown(document)
        lines = [ "### DeployAngel: #{release_name(document)} #{outcome(document)}", "", statement(document).to_s,
                  "", status_line(document), *notes(document).map { |note| "\n#{note}" } ]
        problems = problems(document)
        if problems.any?
          lines.push("", "| Status | Finding |", "| --- | --- |")
          problems.each { |f| lines << "| #{f["status"]} | #{cell(finding_line(f))} |" }
        end
        if (gathering = gathering_line(document))
          lines.push("", gathering)
        end
        sections(document).each do |title, items|
          lines.push("", "**#{title}**", "")
          items.each { |item| lines << "- #{item}" }
        end
        lines.push("", "[Open in DeployAngel](#{document["dashboard_url"]})") if document["dashboard_url"]
        lines.compact.join("\n") + "\n"
      end

      def statement(document)
        (document["clearance"] || {})["statement"] || document["summary"]
      end

      def status_line(document)
        v = document["verification"] || {}
        [ "State: #{v["state"]}", ("Verdict: #{v["verdict"]}" if v["verdict"]),
          ("Confidence: #{v["confidence"]}" if v["confidence"]),
          ("Coverage: #{(v["coverage"] * 100).round}%" if v["coverage"]) ].compact.join(" · ")
      end

      def notes(document)
        v = document["verification"] || {}
        notes = []
        if (check = v["initial_check"]) && v["verdict"].nil?
          notes << "Initial check: #{check["result"].tr("_", " ")}. Not cleared yet."
        end
        notes << "Expected clearance: #{v["expected_clearance_at"]}" if v["expected_clearance_at"] && v["verdict"].nil?
        if (source = document.dig("deployment", "promoted_from"))
          outcome = { "verified" => "cleared", "failed" => "failed", "inconclusive" => "not cleared" }.fetch(source["verdict"], "still verifying")
          notes << "Promoted from #{source["environment"]} #{source["version"] || source["commit"].to_s[0, 7]} (#{outcome})"
        end
        notes
      end

      def problems(document)
        Array(document["findings"]).select { |f| %w[failing warning].include?(f["status"]) }
      end

      def gathering_line(document)
        gathering = Array(document["findings"]).count { |f| f["status"] == "insufficient_data" }
        "#{gathering} signal#{"s" unless gathering == 1} still gathering data" if gathering.positive?
      end

      # Titled lists that follow the findings, each item already a line.
      def sections(document)
        v = document["verification"] || {}
        clearance = document["clearance"] || {}
        changed = Array(document["rare_items_pending"]).select { |item| item["changed_in_release"] == "changed" }
        [
          [ "New exceptions", Array(document["exceptions"]).map do |e|
            "#{e["exception_class"]} in #{e["top_frame"]} (#{e["count"]}x)#{" #{e["sources"].keys.join(", ")}" if e["sources"].is_a?(Hash) && e["sources"].any?}"
          end ],
          [ "Missing evidence", v["verdict"] == "failed" ? [] : Array(clearance["missing_evidence"]) ],
          [ "Not observable", Array(clearance["not_observable"]).map { |item| "#{item["label"]} (#{item["reason"]})" } ],
          [ "Still watching", Array(clearance["still_watching"]).map { |e| "#{e["job_class"]} (expected by #{e["expected_by"]})" } ],
          [ "Critical flows", Array(document["critical_flows"]).map do |flow|
            "#{flow["name"]}: #{flow["status"].tr("_", " ")}#{" (changed in this release)" if flow["changed_in_release"]}"
          end ],
          [ "Changed but not yet exercised", changed.map { |item| item["key"] } ],
          [ "Late regressions", Array(document["late_regressions"]).map { |late| late["summary"] } ]
        ].reject { |_, items| items.empty? }
      end

      def release_name(document)
        deployment = document["deployment"] || {}
        deployment["version"] || deployment["commit"].to_s[0, 7]
      end

      def outcome(document)
        v = document["verification"] || {}
        case v["verdict"]
        when "verified" then "cleared"
        when "failed" then "failed"
        when "inconclusive" then "not cleared"
        else
          case v.dig("initial_check", "result")
          when "warnings" then "has warnings, not cleared yet"
          when nil then "is still being verified"
          else "has no problems so far, not cleared yet"
          end
        end
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
        elsif finding["signal"] == "missing_recurring_job"
          # Its value is the job's interval in seconds, not a rate.
          "#{label}: #{finding["status"] == "pass" ? "ran" : "didn't run"}, #{finding["threshold"]}"
        elsif finding["baseline_value"].nil? && finding["observed_value"].nil?
          "#{label}: #{finding["threshold"]}"
        else
          "#{label}: #{value(finding, finding["baseline_value"])} -> #{value(finding, finding["observed_value"])}" \
            "#{" (#{finding["observed_n"]} samples)" if finding["observed_n"]}"
        end
      end

      def section(lines, title, items)
        lines << "#{title}:"
        items.each { |item| lines << "  #{item}" }
      end

      def cell(text)
        text.gsub("|", "\\|")
      end

      def value(finding, raw)
        return "n/a" if raw.nil?
        return raw.to_i.to_s if COUNTS.include?(finding["signal"])

        DURATIONS.include?(finding["signal"]) ? "#{raw.to_f.round} ms" : "#{(raw.to_f * 100).round(2)}%"
      end
    end
  end
end
