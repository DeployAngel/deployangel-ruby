# frozen_string_literal: true

RSpec.describe DeployAngel::RunningJobs do
  let(:clock) { FakeClock.new(Time.utc(2026, 10, 15, 14, 0, 0)) }
  let(:running) { described_class.new(clock: clock) }

  it "counts each class's running jobs and the oldest one's age" do
    first = running.start("ImportJob")
    clock.advance(30)
    running.start("ImportJob")
    running.start("MailJob")

    expect(running.snapshot(clock.now + 15)).to eq("ImportJob" => [ 2, 45_000 ], "MailJob" => [ 1, 15_000 ])

    running.finish(first)
    expect(running.snapshot(clock.now)).to eq("ImportJob" => [ 1, 0 ], "MailJob" => [ 1, 0 ])
  end

  it "leaves out jobs started after the moment asked about" do
    running.start("ImportJob")

    expect(running.snapshot(clock.now - 1)).to eq({})
  end

  it "stops tracking new jobs past its limit, and finishing an untracked one is harmless" do
    stub_const("#{described_class}::MAX", 2)
    tokens = Array.new(3) { running.start("ImportJob") }

    expect(running.snapshot(clock.now)).to eq("ImportJob" => [ 2, 0 ])
    running.finish(tokens.last)
    running.finish(nil)
    expect(running.snapshot(clock.now)).to eq("ImportJob" => [ 2, 0 ])
  end
end
