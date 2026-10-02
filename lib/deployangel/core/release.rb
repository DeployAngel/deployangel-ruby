# frozen_string_literal: true

module DeployAngel
  # Which release this process is running, resolved once at boot so that
  # telemetry can be attributed to a deployment.
  class Release < Struct.new(:version, :commit, :source)
    COMMIT_FORMAT = /\A[0-9a-f]{7,40}\z/

    # Order: explicit configuration, Heroku dyno metadata, the hosting
    # platform's own variables (Kamal, Render, Fly.io, Railway, Coolify, and
    # Dokku's GIT_REV), then a REVISION file.
    def self.resolve(config:, env: ENV, root: nil)
      if present?(config.release_version) || present?(config.revision)
        build(config.release_version, config.revision, "config")
      elsif present?(env["HEROKU_RELEASE_VERSION"]) || present?(env["HEROKU_SLUG_COMMIT"])
        build(env["HEROKU_RELEASE_VERSION"], env["HEROKU_SLUG_COMMIT"], "heroku_dyno_metadata")
      elsif present?(env["KAMAL_VERSION"])
        kamal(env["KAMAL_VERSION"])
      elsif present?(env["RENDER_GIT_COMMIT"])
        build(nil, env["RENDER_GIT_COMMIT"], "render")
      elsif (tag = fly_tag(env["FLY_IMAGE_REF"]))
        build(tag, nil, "fly")
      elsif present?(env["RAILWAY_GIT_COMMIT_SHA"]) || present?(env["RAILWAY_DEPLOYMENT_ID"])
        railway(env)
      elsif present?(env["SOURCE_COMMIT"]) && present?(env["COOLIFY_CONTAINER_NAME"] || env["COOLIFY_RESOURCE_UUID"])
        build(nil, env["SOURCE_COMMIT"], "coolify")
      # Dokku sets GIT_REV, but the name is generic, so the source says so.
      elsif present?(env["GIT_REV"])
        build(nil, env["GIT_REV"], "git_rev")
      elsif root && File.file?(revision_path = File.join(root, "REVISION"))
        build(nil, File.read(revision_path, 100), "revision_file")
      else
        new(nil, nil, "unknown")
      end
    end

    # Kamal sets KAMAL_VERSION in every app container: the git commit by
    # default, with "_uncommitted_<random>" added for a dirty working tree,
    # or a version you declared. A plain commit is reported as the commit,
    # so it matches deploys registered by commit; anything else is the
    # version, with the commit it starts with.
    def self.kamal(value)
      value = value.to_s.strip
      plain_commit = value.downcase.match?(COMMIT_FORMAT)
      build(plain_commit ? nil : value, value.split("_", 2).first, "kamal")
    end

    # Railway sets the commit for deploys from GitHub. Others, such as
    # `railway up`, only have a deployment ID, which identifies the release.
    def self.railway(env)
      if present?(env["RAILWAY_GIT_COMMIT_SHA"])
        build(nil, env["RAILWAY_GIT_COMMIT_SHA"], "railway")
      else
        build(env["RAILWAY_DEPLOYMENT_ID"], nil, "railway")
      end
    end

    # Fly.io tags each deploy's image ("registry.fly.io/shop:deployment-01H9…"),
    # and the tag identifies the release. Fly.io sets no commit; pass one in
    # with DEPLOYANGEL_REVISION for commit-level change tracking.
    def self.fly_tag(image_ref)
      name = image_ref.to_s.strip.split("@", 2).first.to_s.split("/").last.to_s
      tag = name.split(":", 2)[1].to_s.delete_prefix("deployment-")
      tag unless tag.empty?
    end

    # The cloud rejects malformed commits, which would drop every payload,
    # so anything that is not a hex SHA is left out.
    def self.build(version, commit, source)
      commit = commit.to_s.strip.downcase
      new(present?(version) ? version.to_s.strip[0, 100] : nil,
        commit.match?(COMMIT_FORMAT) ? commit : nil,
        source)
    end

    def self.present?(value)
      !value.to_s.strip.empty?
    end

    def unknown?
      version.nil? && commit.nil?
    end

    def to_protocol
      { "version" => version, "commit" => commit, "source" => source }
    end
  end
end
