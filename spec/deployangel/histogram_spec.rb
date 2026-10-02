# frozen_string_literal: true

RSpec.describe DeployAngel::Histogram do
  it "uses the same buckets as the cloud (log1.1_ms_v1)" do
    expect(described_class.bucket_for(0.3)).to eq(0)
    expect(described_class.bucket_for(84)).to eq(47)
    expect(described_class.bucket_for(10**30)).to eq(described_class::MAX_BUCKET)
  end

  it "serializes sparse counts with the scheme" do
    histogram = described_class.new
    3.times { histogram.record(84) }
    histogram.record(1_000)

    expect(histogram.to_protocol).to eq("scheme" => "log1.1_ms_v1", "counts" => { "47" => 3, "73" => 1 })
  end
end
