# frozen_string_literal: true

require "socket"

RSpec.describe DeployAngel::Transport do
  # A minimal one-request HTTP server, so the real Net::HTTP path is tested.
  def with_server(status:, headers: {})
    server = TCPServer.new("127.0.0.1", 0)
    captured = {}
    thread = Thread.new do
      client = server.accept
      request_line = client.gets
      request_headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(": ", 2)
        request_headers[name.downcase] = value.strip
      end
      body = client.read(request_headers["content-length"].to_i)
      captured.merge!(request_line: request_line, headers: request_headers, body: body)
      extra = headers.map { |k, v| "#{k}: #{v}\r\n" }.join
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: 0\r\n#{extra}Connection: close\r\n\r\n")
      client.close
    end
    config = active_config.tap { |c| c.endpoint = "http://127.0.0.1:#{server.addr[1]}" }
    yield described_class.new(config), captured, thread
  ensure
    thread&.join(2)
    server&.close
  end

  it "posts gzipped JSON with the bearer token" do
    with_server(status: 202) do |transport, captured, thread|
      result = transport.post("/api/v1/telemetry", { "hello" => "world" })
      thread.join(2)

      expect(result.outcome).to eq(:ok)
      expect(captured[:request_line]).to start_with("POST /api/v1/telemetry")
      expect(captured[:headers]).to include("authorization" => "Bearer da_live_test", "content-encoding" => "gzip")
      expect(JSON.parse(Zlib.gunzip(captured[:body]))).to eq("hello" => "world")
    end
  end

  it "sends an encoded payload's bytes unchanged" do
    with_server(status: 202) do |transport, captured, thread|
      encoded = described_class.encode({ "hello" => "world" })
      transport.post("/api/v1/telemetry", encoded)
      thread.join(2)

      expect(captured[:body].b).to eq(encoded.bytes.b)
      expect(JSON.parse(Zlib.gunzip(captured[:body]))).to eq("hello" => "world")
    end
  end

  it "classifies responses" do
    with_server(status: 503) { |transport| expect(transport.post("/x", {}).outcome).to eq(:retry) }
    with_server(status: 422) { |transport| expect(transport.post("/x", {}).outcome).to eq(:drop) }
    with_server(status: 429, headers: { "Retry-After" => "30" }) do |transport|
      result = transport.post("/x", {})
      expect([ result.outcome, result.retry_after ]).to eq([ :drop, 30 ])
    end
  end

  it "treats connection failures as retryable" do
    config = active_config.tap { |c| c.endpoint = "http://127.0.0.1:1" }
    expect(described_class.new(config).post("/x", {}).outcome).to eq(:retry)
  end
end
