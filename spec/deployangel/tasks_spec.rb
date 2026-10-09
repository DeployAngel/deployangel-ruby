# frozen_string_literal: true

require "rake"

RSpec.describe DeployAngel::Tasks do
  let(:recorded) { [] }
  let(:exceptions) { [] }

  around do |example|
    capabilities = DeployAngel.capabilities.dup
    example.run
  ensure
    DeployAngel.instance_variable_set(:@capabilities, capabilities)
    described_class.instance_variable_set(:@rake_tasks, nil)
  end

  before do
    allow(DeployAngel.configuration).to receive(:logger).and_return(nil)
    allow(DeployAngel).to receive(:recording?).and_return(true)
    allow(DeployAngel).to receive(:record_job) { |**attributes| recorded << attributes }
    allow(DeployAngel).to receive(:record_exception) { |error, **options| exceptions << [ error.class, options ] }
  end

  it "records a block as a run of its name, as job work, and returns its value" do
    context = nil
    result = DeployAngel.task("invoices:send") { context = DeployAngel::ExecutionContext.current
                                                 :sent }

    expect(result).to eq(:sent)
    expect(context).to eq(DeployAngel::ExecutionContext::JOB)
    expect(DeployAngel::ExecutionContext.current).to be_nil
    expect(recorded.sole).to include(job_class: "invoices:send", failed: false)
    expect(recorded.sole[:duration_ms]).to be >= 0
    expect(DeployAngel.capabilities).to include("jobs")
  end

  it "records a failure and its exception, then re-raises it untouched" do
    expect { DeployAngel.task("nightly import") { raise ArgumentError, "bad row" } }.to raise_error(ArgumentError, "bad row")

    expect(recorded.sole).to include(job_class: "nightly import", failed: true)
    expect(exceptions.sole).to eq([ ArgumentError, { source: "job_class:nightly import" } ])
  end

  it "just runs the block when the agent isn't recording, or the name can't be used" do
    allow(DeployAngel).to receive(:recording?).and_return(false)
    expect(DeployAngel.task("invoices:send") { 1 }).to eq(1)

    allow(DeployAngel).to receive(:recording?).and_return(true)
    expect(DeployAngel.task("") { 2 }).to eq(2)
    expect(DeployAngel.task("x" * 201) { 3 }).to eq(3)
    expect(recorded).to be_empty
  end

  describe "rake tasks a schedule names" do
    let(:app) { Rake::Application.new }

    around do |example|
      previous = Rake.application
      Rake.application = app
      example.run
    ensure
      Rake.application = previous
    end

    it "records only those, by name, with no change to the task" do
      ran = []
      Rake::Task.define_task("invoices:send") { ran << :invoices }
      Rake::Task.define_task("db:migrate") { ran << :migrate }
      described_class.install_rake([ { "class" => "rake invoices:send" }, { "class" => "NightlyJob" } ])

      Rake::Task["invoices:send"].invoke
      Rake::Task["db:migrate"].invoke

      expect(ran).to eq(%i[invoices migrate])
      expect(recorded.map { |job| job[:job_class] }).to eq([ "rake invoices:send" ])
    end

    it "does nothing when no schedule names a rake task" do
      described_class.install_rake([ { "class" => "NightlyJob" } ])
      Rake::Task.define_task("invoices:send") {}
      Rake::Task["invoices:send"].invoke

      expect(recorded).to be_empty
    end
  end
end
