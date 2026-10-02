# frozen_string_literal: true

RSpec.describe DeployAngel::CiEnvironment do
  it "reads GitHub Actions' commit, run number, and run link" do
    ci = described_class.detect("GITHUB_ACTIONS" => "true", "GITHUB_SHA" => "abc1234def", "GITHUB_RUN_NUMBER" => "123",
      "GITHUB_RUN_ID" => "9876", "GITHUB_SERVER_URL" => "https://github.com", "GITHUB_REPOSITORY" => "acme/shop")

    expect(ci.to_h).to eq(provider: "github_actions", commit: "abc1234def", version: "run-123",
      source_url: "https://github.com/acme/shop/actions/runs/9876")
  end

  it "registers Kamal's release from a Kamal hook, linked to the CI run when there is one" do
    kamal = described_class.detect("KAMAL_VERSION" => "abc1234def", "KAMAL_COMMAND" => "deploy")
    expect(kamal.to_h).to eq(provider: "kamal", commit: "abc1234def", version: nil, source_url: nil)

    in_ci = described_class.detect("KAMAL_VERSION" => "2026.10.01", "GITHUB_ACTIONS" => "true", "GITHUB_SHA" => "abc1234def",
      "GITHUB_RUN_ID" => "9876", "GITHUB_SERVER_URL" => "https://github.com", "GITHUB_REPOSITORY" => "acme/shop")
    expect(in_ci.to_h).to eq(provider: "kamal", commit: nil, version: "2026.10.01",
      source_url: "https://github.com/acme/shop/actions/runs/9876")
  end

  it "recognizes GitLab CI, CircleCI, and Buildkite, and nothing outside CI" do
    expect(described_class.detect("GITLAB_CI" => "true", "CI_COMMIT_SHA" => "a1", "CI_PIPELINE_IID" => "45").version).to eq("pipeline-45")
    expect(described_class.detect("CIRCLECI" => "true", "CIRCLE_SHA1" => "b2", "CIRCLE_BUILD_NUM" => "67").provider).to eq("circleci")
    expect(described_class.detect("BUILDKITE" => "true", "BUILDKITE_COMMIT" => "c3", "BUILDKITE_BUILD_URL" => "http://insecure").source_url).to be_nil
    expect(described_class.detect({})).to be_nil
  end
end
