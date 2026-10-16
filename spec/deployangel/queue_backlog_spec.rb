# frozen_string_literal: true

RSpec.describe DeployAngel::QueueBacklog do
  after do
    described_class.instance_variable_set(:@backend, nil)
    described_class.instance_variable_set(:@installed, nil)
  end

  it "reads nothing in a process that doesn't work a queue" do
    expect(described_class.read).to be_nil
  end

  it "reads Sidekiq's enqueued jobs in a Sidekiq server" do
    stats = Class.new { def enqueued = 42 }
    stub_const("Sidekiq::Stats", stats)
    allow(described_class).to receive(:require).with("sidekiq/api").and_return(true)
    described_class.worker!(:sidekiq)

    expect(described_class.read).to eq(42)
  end

  it "counts Solid Queue's ready executions in a worker it marked as it started" do
    hooks = []
    stub_const("SolidQueue", Module.new { define_singleton_method(:on_worker_start) { |&block| hooks << block } })
    pool = double(with_connection: nil)
    allow(pool).to receive(:with_connection).and_yield
    stub_const("SolidQueue::ReadyExecution", double(connection_pool: pool, count: 7))

    described_class.install
    expect(described_class.read).to be_nil
    hooks.each { |hook| hook.call(:worker) }

    expect(described_class.read).to eq(7)
  end

  it "reads nil rather than raise when the backend can't be read" do
    stub_const("Sidekiq::Stats", Class.new { def enqueued = raise("Redis down") })
    allow(described_class).to receive(:require).with("sidekiq/api").and_return(true)
    described_class.worker!(:sidekiq)

    expect(described_class.read).to be_nil
  end
end
