# frozen_string_literal: true

require "tmpdir"

RSpec.describe DeployAngel::Release do
  let(:config) { DeployAngel::Configuration.new({}) }

  it "prefers explicit configuration" do
    config.release_version = "v9"
    config.revision = "ABC1234"
    release = described_class.resolve(config: config, env: { "HEROKU_RELEASE_VERSION" => "v1" })

    expect(release.to_protocol).to eq("version" => "v9", "commit" => "abc1234", "source" => "config")
  end

  it "falls back to Heroku dyno metadata" do
    release = described_class.resolve(config: config,
      env: { "HEROKU_RELEASE_VERSION" => "v184", "HEROKU_SLUG_COMMIT" => "81ac27d0a1b2c3" })

    expect(release.to_protocol).to eq("version" => "v184", "commit" => "81ac27d0a1b2c3", "source" => "heroku_dyno_metadata")
  end

  describe "hosting platforms" do
    it "reports Kamal's default version, a plain commit, as the commit" do
      release = described_class.resolve(config: config, env: { "KAMAL_VERSION" => "81AC27D0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6" })

      expect(release.to_protocol).to eq("version" => nil, "commit" => "81ac27d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "source" => "kamal")
    end

    it "keeps a dirty-tree Kamal version whole, with the commit it starts with" do
      version = "81ac27d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6_uncommitted_9f8e7d6c5b4a3210"
      release = described_class.resolve(config: config, env: { "KAMAL_VERSION" => version })

      expect(release.to_protocol).to eq("version" => version, "commit" => "81ac27d0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6", "source" => "kamal")
    end

    it "reports a declared Kamal version as the version, with no commit" do
      release = described_class.resolve(config: config, env: { "KAMAL_VERSION" => "2026.10.01-1" })

      expect(release.to_protocol).to eq("version" => "2026.10.01-1", "commit" => nil, "source" => "kamal")
    end

    it "reads Render's commit" do
      release = described_class.resolve(config: config, env: { "RENDER_GIT_COMMIT" => "deadbeef1234567" })

      expect(release.to_protocol).to eq("version" => nil, "commit" => "deadbeef1234567", "source" => "render")
    end

    it "uses the Fly.io image tag, which is unique per deploy, as the version" do
      release = described_class.resolve(config: config,
        env: { "FLY_IMAGE_REF" => "registry.fly.io/shop:deployment-01H9RK9EYO9PGNBYAKGXSHV0PH" })

      expect(release.to_protocol).to eq("version" => "01H9RK9EYO9PGNBYAKGXSHV0PH", "commit" => nil, "source" => "fly")
      expect(described_class.resolve(config: config, env: { "FLY_IMAGE_REF" => "registry.fly.io/shop@sha256:abc" })).to be_unknown
    end

    it "reads Railway's commit, or its deployment ID for deploys that didn't come from GitHub" do
      expect(described_class.resolve(config: config, env: { "RAILWAY_GIT_COMMIT_SHA" => "cafe1234567", "RAILWAY_DEPLOYMENT_ID" => "d-1" }).to_protocol)
        .to eq("version" => nil, "commit" => "cafe1234567", "source" => "railway")
      expect(described_class.resolve(config: config, env: { "RAILWAY_DEPLOYMENT_ID" => "4f2c9e1a-7d3b-4c8e-9a1f-2b3c4d5e6f70" }).to_protocol)
        .to eq("version" => "4f2c9e1a-7d3b-4c8e-9a1f-2b3c4d5e6f70", "commit" => nil, "source" => "railway")
    end

    it "reads Coolify's SOURCE_COMMIT only inside a Coolify container" do
      coolify = described_class.resolve(config: config, env: { "SOURCE_COMMIT" => "beef1234567", "COOLIFY_CONTAINER_NAME" => "web-abc" })
      expect(coolify.to_protocol).to eq("version" => nil, "commit" => "beef1234567", "source" => "coolify")

      expect(described_class.resolve(config: config, env: { "SOURCE_COMMIT" => "beef1234567" })).to be_unknown
    end

    it "reads GIT_REV, which Dokku sets" do
      release = described_class.resolve(config: config, env: { "GIT_REV" => "f00d1234567" })

      expect(release.to_protocol).to eq("version" => nil, "commit" => "f00d1234567", "source" => "git_rev")
    end

    it "lets explicit configuration and Heroku win over platform variables" do
      config.revision = "abc1234"
      expect(described_class.resolve(config: config, env: { "KAMAL_VERSION" => "deadbeef123" }).source).to eq("config")

      heroku = described_class.resolve(config: DeployAngel::Configuration.new({}),
        env: { "HEROKU_RELEASE_VERSION" => "v12", "RENDER_GIT_COMMIT" => "deadbeef123" })
      expect(heroku.source).to eq("heroku_dyno_metadata")
    end
  end

  it "reads a REVISION file" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "REVISION"), "deadbeef123\n")
      release = described_class.resolve(config: config, env: {}, root: root)

      expect(release.commit).to eq("deadbeef123")
      expect(release.source).to eq("revision_file")
    end
  end

  it "drops a malformed commit rather than sending one the cloud would reject" do
    config.revision = "main"
    release = described_class.resolve(config: config, env: {})

    expect(release.commit).to be_nil
  end

  it "is unknown when nothing identifies the release" do
    expect(described_class.resolve(config: config, env: {})).to be_unknown
  end

  describe "ECS" do
    let(:env) { { "ECS_CONTAINER_METADATA_URI_V4" => "http://169.254.170.2/v4/abc" } }

    def resolve(metadata, root: nil)
      body = metadata && JSON.generate(metadata)
      described_class.resolve(config: config, env: env, root: root, http: ->(uri) { body if uri == env["ECS_CONTAINER_METADATA_URI_V4"] })
    end

    it "reads the release from the image tag: the commit when it looks like one, else the version" do
      expect(resolve({ "Image" => "123.dkr.ecr.us-east-1.amazonaws.com/shop:3F2A9C1E" }).to_protocol)
        .to eq("version" => nil, "commit" => "3f2a9c1e", "source" => "ecs")
      expect(resolve({ "Image" => "123.dkr.ecr.us-east-1.amazonaws.com/shop:v1.4.2" }).to_protocol)
        .to eq("version" => "v1.4.2", "commit" => nil, "source" => "ecs")
    end

    it "uses the image digest for a moving tag, or no tag" do
      digest = "sha256:#{"ab12" * 16}"
      expect(resolve({ "Image" => "shop:latest", "ImageID" => digest }).version).to eq("sha256:ab12ab12ab12")
      expect(resolve({ "Image" => "shop@#{digest}", "ImageID" => digest }).version).to eq("sha256:ab12ab12ab12")
    end

    it "is unknown when the metadata can't be read, and a REVISION file wins" do
      expect(resolve(nil)).to be_unknown
      Dir.mktmpdir do |root|
        File.write(File.join(root, "REVISION"), "81ac27d\n")
        expect(resolve({ "Image" => "shop:v2" }, root: root).to_protocol).to include("commit" => "81ac27d", "source" => "revision_file")
      end
    end
  end
end
