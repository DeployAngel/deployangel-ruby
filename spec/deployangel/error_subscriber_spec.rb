# frozen_string_literal: true

RSpec.describe DeployAngel::Rails::ErrorSubscriber do
  it "records handled reports and leaves unhandled ones to the request and job instrumentation" do
    recorded = []
    allow(DeployAngel).to receive(:record_exception) { |error, **options| recorded << [ error.message, options ] }

    described_class.new.report(RuntimeError.new("handled"), handled: true, severity: :warning, context: {})
    described_class.new.report(RuntimeError.new("unhandled"), handled: false, severity: :error, context: {})

    expect(recorded).to eq([ [ "handled", { handled: true } ] ])
  end
end
