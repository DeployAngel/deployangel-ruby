# frozen_string_literal: true

RSpec.describe DeployAngel::MCP::Server do
  let(:clock) { FakeClock.new(Time.utc(2026, 9, 30, 14)) }
  let(:client) { FakeClient.new(documents: [ verdict_document(state: "observing"), verdict_document(state: "closed", verdict: "verified") ]) }
  let(:server) do
    described_class.new(client: client, output: StringIO.new, error_output: StringIO.new,
      sleeper: ->(seconds) { clock.advance(seconds) }, clock: clock, git_head: -> { "81ac27d0000" })
  end

  def request(method, params = {}, id: 1)
    server.handle({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  it "negotiates the protocol version and describes itself" do
    result = request("initialize", { "protocolVersion" => "2025-03-26" })["result"]

    expect(result["protocolVersion"]).to eq("2025-03-26")
    expect(result["serverInfo"]).to eq("name" => "deployangel", "version" => DeployAngel::VERSION)
    expect(result["instructions"]).to include("inconclusive means NOT verified")
    expect(request("initialize", { "protocolVersion" => "1999-01-01" }).dig("result", "protocolVersion")).to eq("2025-06-18")
  end

  it "lists register_deployment only for tokens with the deployments scope" do
    names = -> { request("tools/list").dig("result", "tools").map { |tool| tool["name"] } }
    expect(names.call).not_to include("register_deployment")

    client.scopes = %w[verifications:read deployments]
    server.instance_variable_set(:@scopes, nil)
    expect(names.call).to include("register_deployment", "wait_for_verification", "get_exception")
  end

  it "returns a release's exercise plan, and explains how to act on it" do
    client = FakeClient.new(documents: [ verdict_document(state: "observing").merge("exercise_plan" => exercise_plan) ])
    server = described_class.new(client: client, output: StringIO.new, error_output: StringIO.new, git_head: -> { "81ac27d0000" })
    tools = server.handle({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }).dig("result", "tools")
    expect(tools.find { |tool| tool["name"] == "get_exercise_plan" }["description"]).to include("test account or ask first")

    result = server.handle({ "jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
      "params" => { "name" => "get_exercise_plan", "arguments" => {} } })["result"]
    expect(result["structuredContent"].dig("exercise_plan", "status")).to eq("exercisable")
    expect(result["structuredContent"].dig("deployment", "version")).to eq("v184")
    expect(request("initialize")["result"]["instructions"]).to include("get_exercise_plan", "warm_up")
  end

  it "returns every tool's structured content as an object, as MCP requires, never a bare list" do
    client.scopes = %w[verifications:read deployments]
    calls = { "get_verification" => {}, "wait_for_verification" => { "timeout_seconds" => 1 }, "get_exercise_plan" => {},
              "list_deployments" => {}, "get_exception" => { "fingerprint" => "abc" }, "list_late_regressions" => {},
              "register_deployment" => { "commit" => "abc1234" } }
    expect(request("tools/list").dig("result", "tools").map { |tool| tool["name"] }).to match_array(calls.keys)

    calls.each do |name, arguments|
      result = request("tools/call", { "name" => name, "arguments" => arguments })["result"]
      expect(result["structuredContent"]).to be_a(Hash), "#{name} returned #{result["structuredContent"].class}"
    end
    expect(request("tools/call", { "name" => "list_deployments" }).dig("result", "structuredContent")).to eq("deployments" => [ { "id" => 42 } ])
  end

  it "waits for a verdict and returns structured content with the exit code's meaning" do
    result = request("tools/call", { "name" => "wait_for_verification", "arguments" => { "until" => "verdict" } })["result"]

    expect(result["isError"]).to be(false)
    expect(result["structuredContent"]).to include("exit_code" => 0, "meaning" => "verified: the release is cleared")
    expect(JSON.parse(result.dig("content", 0, "text")).dig("verification", "verification", "verdict")).to eq("verified")
    expect(client.calls.first).to eq([ :deployments, { commit: "81ac27d0000", version: nil, limit: 1 } ])
  end

  it "caps each wait at five minutes and reports in-progress results" do
    stuck = FakeClient.new(documents: [ verdict_document(state: "observing") ])
    server = described_class.new(client: stuck, output: StringIO.new, error_output: StringIO.new,
      sleeper: ->(seconds) { clock.advance(seconds) }, clock: clock)
    result = server.handle({ "id" => 2, "method" => "tools/call",
      "params" => { "name" => "wait_for_verification", "arguments" => { "latest" => true, "timeout_seconds" => 9_999 } } })

    expect(result.dig("result", "structuredContent")).to include("exit_code" => 3, "in_progress" => true)
    expect(clock.now).to eq(Time.utc(2026, 9, 30, 14, 5))
  end

  it "ignores notifications and rejects unknown methods and bad JSON" do
    expect(server.handle({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })).to be_nil
    expect(request("resources/list").dig("error", "code")).to eq(-32_601)
    expect(server.handle_line("{nope").dig("error", "code")).to eq(-32_700)
    expect(request("tools/call", { "name" => "rollback" }).dig("error", "code")).to eq(-32_602)
  end

  it "speaks one JSON message per line over stdio" do
    input = StringIO.new(%({"jsonrpc":"2.0","id":1,"method":"ping"}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n))
    output = StringIO.new
    described_class.new(client: client, input: input, output: output, error_output: StringIO.new).run

    expect(output.string.lines.map { |line| JSON.parse(line) }).to eq([ { "jsonrpc" => "2.0", "id" => 1, "result" => {} } ])
  end
end
