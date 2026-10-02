# frozen_string_literal: true

# Measures what the agent costs a production app: time and allocations added
# to each request, the worst-case memory it can hold, the reporter thread's
# work each minute, and the one-time file digest pass.
#
#   bundle exec ruby bench/overhead.rb [APP_ROOT]
#
# APP_ROOT is the Rails app whose files to digest (default: this gem).
# Nothing is sent anywhere; a fake transport stands in for DeployAngel.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "deployangel"
require "rack"
require "rack/mock"
require "json"
require "zlib"
require "objspace"

ROOT = File.expand_path("..", __dir__)
DIGEST_ROOT = File.expand_path(ARGV[0] || ROOT)
ROUNDS = 7
ITERATIONS = 200_000
ERROR_STATUSES = [ 400, 401, 403, 404, 409, 422, 429, 500, 502, 503 ].freeze

class BenchTransport
  def initialize(outcome)
    @result = DeployAngel::Transport::Result.new(outcome, outcome == :ok ? 202 : 503, nil)
  end

  def post(_path, _body)
    @result
  end
end

module BenchErrors; end

def config
  DeployAngel::Configuration.new({}).tap do |c|
    c.token = "da_live_bench"
    c.endpoint = "http://deployangel.invalid"
    c.revision = "0000000"
    c.logger = nil
  end
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def median(values)
  values.sort[values.size / 2]
end

def kib(bytes)
  format("%.0f KiB", bytes / 1024.0)
end

def retained_bytes
  3.times { GC.start(full_mark: true, immediate_sweep: true) }
  before = ObjectSpace.memsize_of_all
  yield
  3.times { GC.start(full_mark: true, immediate_sweep: true) }
  ObjectSpace.memsize_of_all - before
end

# Nanoseconds and allocated objects per call of app over a cycle of envs.
def measure(app, envs)
  count = envs.size
  times = []
  allocations = []
  ROUNDS.times do
    i = 0
    allocated = GC.stat(:total_allocated_objects)
    started = monotonic
    while i < ITERATIONS
      app.call(envs[i % count])
      i += 1
    end
    times << (monotonic - started) * 1e9 / ITERATIONS
    allocations << (GC.stat(:total_allocated_objects) - allocated).fdiv(ITERATIONS)
  end
  [ median(times), median(allocations) ]
end

def raise_from(depth, error_class, message)
  depth.zero? ? raise(error_class, message) : raise_from(depth - 1, error_class, message)
end

def exception(error_class, message = "Couldn't find User with 'id'=42 for alice@example.com")
  raise_from(25, error_class, message)
rescue StandardError => e
  e
end

def error_class(name)
  BenchErrors.const_defined?(name) ? BenchErrors.const_get(name) : BenchErrors.const_set(name, Class.new(StandardError))
end

def duration_for(bucket)
  1.1**(bucket - 0.5)
end

# Histogram buckets each route and job class uses. Realistic: every duration
# from under 1 ms to 60 s for requests and to 1 hour for jobs. Ceiling: all
# 401 buckets, which no app reaches (the top bucket is about 10^16 ms).
SCENARIOS = {
  "realistic worst case" => { request_buckets: DeployAngel::Histogram.bucket_for(60_000), job_buckets: DeployAngel::Histogram.bucket_for(3_600_000) },
  "theoretical ceiling" => { request_buckets: DeployAngel::Histogram::MAX_BUCKET, job_buckets: DeployAngel::Histogram::MAX_BUCKET }
}.freeze

# Every per-minute list at its cap: 100 routes, 100 job classes, 100
# checkpoints, and 20 exceptions with backtraces.
def fill_worst_case_minute(agent, minute, request_buckets:, job_buckets:)
  100.times do |r|
    route = "GET /bench/resource_#{r}/:id"
    (0..request_buckets).each { |b| agent.record_request(route_key: route, status: 200, duration_ms: duration_for(b)) }
    ERROR_STATUSES.each { |status| agent.record_request(route_key: route, status: status, duration_ms: 5) }
  end
  100.times do |j|
    (0..job_buckets).each do |b|
      agent.record_job(job_class: "Bench#{j}Job", duration_ms: duration_for(b), queue_latency_ms: duration_for(b), failed: b.zero?)
    end
  end
  100.times { |c| agent.record_checkpoint("bench.checkpoint_#{c}") }
  20.times do |e|
    error = exception(error_class("Minute#{minute}Error#{e}"), "x" * 300)
    agent.record_exception(error, source: "route:GET /bench/resource_#{e}/:id")
  end
end

def route_envs
  Array.new(100) do |r|
    Rack::MockRequest.env_for("/bench/resource_#{r}/42", method: "GET")
      .merge("action_dispatch.route_uri_pattern" => "/bench/resource_#{r}/:id(.:format)")
  end
end

def report(title)
  puts
  puts title
  puts "-" * title.size
  yield
end

puts "deployangel #{DeployAngel::VERSION}, ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})" \
  "#{" YJIT" if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?}"

report("Per request") do
  envs = route_envs
  app = ->(_env) { [ 200, {}, [ "ok" ] ] }
  bare_ns, bare_allocs = measure(app, envs)

  agent = DeployAngel::Agent.new(config: config, environment: "production", root: ROOT, transport: BenchTransport.new(:ok))
  DeployAngel.instance_variable_set(:@agent, agent)
  wrapped_ns, wrapped_allocs = measure(DeployAngel::Rails::Http.new(app), envs)

  overhead_us = (wrapped_ns - bare_ns) / 1000.0
  puts format("added time:        %.1f µs per request (median of %d rounds of %d)", overhead_us, ROUNDS, ITERATIONS)
  puts format("added allocations: %.1f objects per request", wrapped_allocs - bare_allocs)
  [ 20, 100 ].each do |ms|
    puts format("on a %d ms request: %.3f%% slower", ms, overhead_us / (ms * 1000.0) * 100)
  end
  [ 50, 500 ].each do |rps|
    puts format("at %d req/s in one process: %.2f%% of one core", rps, overhead_us * rps / 1e6 * 100)
  end

  errors = Array.new(ITERATIONS / 10) { exception(error_class("PerRequestError")) }
  started = monotonic
  errors.each { |e| agent.record_exception(e, source: "route:GET /bench/resource_0/:id") }
  puts format("each exception:    %.1f µs more (fingerprint and sanitized message)", (monotonic - started) * 1e6 / errors.size)
  DeployAngel.instance_variable_set(:@agent, nil)
end

report("Memory, every list at its cap") do
  limit = config.max_queued_payloads
  SCENARIOS.each do |name, buckets|
    now = Time.utc(2026, 1, 1)
    agent = nil
    one_minute = retained_bytes do
      agent = DeployAngel::Agent.new(config: config, environment: "production", root: ROOT,
        transport: BenchTransport.new(:retry), clock: -> { now })
      fill_worst_case_minute(agent, 0, **buckets)
    end
    unreachable = one_minute + retained_bytes do
      # DeployAngel unreachable, so finished minutes pile up in the buffer.
      limit.times do |minute|
        now += 60
        agent.flush
        fill_worst_case_minute(agent, minute + 1, **buckets)
      end
    end
    buffer = agent.instance_variable_get(:@buffer)
    gzipped = buffer.shift.bytes
    puts "#{name}:"
    puts "  the minute in progress:                         #{kib(one_minute)}"
    puts "  DeployAngel unreachable (#{buffer.size + 1} unsent minutes too): #{kib(unreachable)}"
    puts "  one minute's payload on the wire:               #{kib(Zlib.gunzip(gzipped).bytesize)} JSON, #{kib(gzipped.bytesize)} gzipped"
  end
end

report("Reporter thread, each minute") do
  now = Time.utc(2026, 1, 1)
  agent = DeployAngel::Agent.new(config: config, environment: "production", root: ROOT,
    transport: BenchTransport.new(:ok), clock: -> { now })
  fill_worst_case_minute(agent, 0, **SCENARIOS.fetch("realistic worst case"))
  now += 60
  period = agent.instance_variable_get(:@aggregator).drain.last
  times = Array.new(ROUNDS) do
    started = monotonic
    payload = DeployAngel::Protocol.telemetry(period, instance: agent.instance, release: agent.release, runtime: {})
    Zlib.gzip(JSON.generate(payload))
    monotonic - started
  end
  puts format("building, encoding, and gzipping a realistic worst-case minute: %.1f ms", median(times) * 1000)
end

report("File digests, once per process") do
  metadata = nil
  files = nil
  seconds = nil
  bytes = retained_bytes do
    metadata = DeployAngel::Rails::Metadata.new(app: nil, config: config, root: DIGEST_ROOT)
    started = monotonic
    files = metadata.files
    seconds = monotonic - started
  end
  puts "root: #{DIGEST_ROOT}"
  puts format("%d files hashed in %.0f ms (%.2f ms per 100 files)", files.size, seconds * 1000, seconds * 1000 / [ files.size, 1 ].max * 100)
  puts "manifest kept in memory: #{kib(bytes)}"
end
