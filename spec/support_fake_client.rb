# frozen_string_literal: true

# Scripted stand-in for DeployAngel::Client: each verification call returns
# the next document in the list, then keeps returning the last one.
class FakeClient
  attr_reader :calls
  attr_accessor :deployments_list, :scopes

  def initialize(documents: [], deployments_list: [ { "id" => 42 } ], scopes: %w[verifications:read])
    @documents = documents
    @deployments_list = deployments_list
    @scopes = scopes
    @calls = []
  end

  def token_info = (@calls << [ :token_info ]) && { "scopes" => scopes }
  def latest_deployment = (@calls << [ :latest ]) && deployments_list.first || raise(DeployAngel::Client::NotFound, "not found")

  def deployments(**filters)
    @calls << [ :deployments, filters ]
    deployments_list
  end

  def verification(id, all_findings: false)
    @calls << [ :verification, id ]
    @documents.size > 1 ? @documents.shift : @documents.first
  end

  def register_deployment(**attributes)
    @calls << [ :register, attributes ]
    { "id" => 43, "version" => attributes[:version], "commit" => attributes[:commit], "state" => "pending" }
  end

  def report_check(reference, **attributes)
    @calls << [ :check, reference, attributes ]
    { "id" => 1, "status" => attributes[:status], "deployment_id" => 42 }
  end

  def exception(fingerprint) = { "fingerprint" => fingerprint, "exception_class" => "NoMethodError", "backtrace" => [] }
  def late_regressions(**) = []
end

# An exercise plan as the server returns it for a quiet app's release.
def exercise_plan(status: "exercisable")
  { "status" => status, "summary" => "Not cleared yet. Exercising these items against production would let it clear sooner.",
    "shortfall" => { "rule" => "low_volume", "requests" => { "have" => 12, "need" => 30 },
                     "routes_run_3_times" => { "have" => 1, "need" => 3, "of" => 3 } },
    "items" => [
      { "kind" => "route", "key" => "GET /orders/:id", "reason" => "normally_active", "runs" => 1, "runs_needed" => 3, "mutating" => false,
        "needed" => true },
      { "kind" => "route", "key" => "POST /password_resets", "reason" => "changed_in_release", "runs" => 0, "mutating" => true, "needed" => false },
      { "kind" => "job_class", "key" => "InvoiceMailer", "reason" => "normally_active", "runs" => 0, "triggered_by" => "app_behavior",
        "needed" => true }
    ],
    "report_with" => %(deployangel check --name="exercise plan" --status=pass --covers="GET /orders/:id,POST /password_resets,InvoiceMailer") }
end

def verdict_document(state:, verdict: nil, initial_check: nil, poll: 60)
  { "schema_version" => 1, "deployment" => { "id" => 42, "version" => "v184" },
    "verification" => { "state" => state, "verdict" => verdict, "initial_check" => initial_check, "confidence" => "high", "coverage" => 1.0 },
    "clearance" => { "statement" => "v184 #{verdict || "not cleared yet"}", "missing_evidence" => [], "not_observable" => [], "still_watching" => [] },
    "findings" => [], "poll_after_seconds" => poll, "dashboard_url" => "https://app.deployangel.com/apps/1/deployments/42" }
end
