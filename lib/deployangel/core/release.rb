# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module DeployAngel
  # Which release this process is running, resolved once at boot so that
  # telemetry can be attributed to a deployment.
  class Release < Struct.new(:version, :commit, :source)
    COMMIT_FORMAT = /\A[0-9a-f]{7,40}\z/

    # Tags that move from build to build, so they can't identify a release.
    MOVING_TAGS = %w[latest main master production prod staging stable release].freeze

    # Look for .git this many directories above the app's root, for an app
    # that lives in a subdirectory of its repository.
    GIT_PARENT_LEVELS = 3

    # Order: explicit configuration, Heroku dyno metadata, the hosting
    # platform's own variables (Kamal, Render, Fly.io, Railway, Coolify, and
    # Dokku's GIT_REV), a REVISION file, a git checkout, then ECS container
    # metadata. When none of them names the release, the agent falls back to
    # a fingerprint of the app's code (code_fingerprint), computed later.
    def self.resolve(config:, env: ENV, root: nil, http: method(:fetch_metadata))
      if present?(config.release_version) || present?(config.revision)
        build(config.release_version, config.revision, "config")
      elsif present?(env["HEROKU_RELEASE_VERSION"]) || present?(heroku_commit(env))
        build(env["HEROKU_RELEASE_VERSION"], heroku_commit(env), "heroku_dyno_metadata")
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
      elsif root && (commit = git_head(root))
        build(nil, commit, "git_head")
      elsif present?(env["ECS_CONTAINER_METADATA_URI_V4"]) && (release = ecs(http.call(env["ECS_CONTAINER_METADATA_URI_V4"])))
        release
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

    # A server deployed by `git pull` (or Fabric, or Ansible) runs from a
    # checkout, where HEAD names the commit. Read from the repository's
    # files, never by running git. Nil if anything is missing or unreadable.
    def self.git_head(root)
      git_dir = find_git_dir(File.expand_path(root)) or return
      common_dir = git_dir
      commondir = File.join(git_dir, "commondir")
      common_dir = File.expand_path(File.read(commondir, 1024).strip, git_dir) if File.file?(commondir)

      head = File.read(File.join(git_dir, "HEAD"), 200).to_s.strip
      ref = head.delete_prefix("ref:").strip if head.start_with?("ref:")
      commit = ref ? read_ref(ref, git_dir, common_dir) : head
      commit = commit.to_s.strip.downcase
      commit if commit.match?(COMMIT_FORMAT)
    rescue StandardError
      nil
    end

    # .git is a directory, or for a worktree or submodule, a file naming the
    # real one ("gitdir: ../.git/worktrees/shop").
    def self.find_git_dir(dir)
      (GIT_PARENT_LEVELS + 1).times do
        git = File.join(dir, ".git")
        return File.directory?(git) ? git : linked_git_dir(git) if File.exist?(git)

        parent = File.dirname(dir)
        return if parent == dir

        dir = parent
      end
      nil
    end

    def self.linked_git_dir(file)
      path = File.read(file, 1024).to_s[/\Agitdir:\s*(.+)$/, 1]&.strip
      File.expand_path(path, File.dirname(file)) if present?(path)
    end

    # A branch's commit is in its ref file, in the worktree's own git dir or
    # the common one, or else in packed-refs. Refs come from a file on disk,
    # so anything outside refs/ is ignored rather than read.
    def self.read_ref(ref, git_dir, common_dir)
      return unless ref.start_with?("refs/") && !ref.include?("..")

      [ git_dir, common_dir ].uniq.each do |dir|
        path = File.join(dir, ref)
        return File.read(path, 100) if File.file?(path)
      end

      packed = File.join(common_dir, "packed-refs")
      return unless File.file?(packed)

      File.foreach(packed) do |line|
        next if line.start_with?("#", "^")

        commit, name = line.split(" ", 2)
        return commit if name.to_s.strip == ref
      end
      nil
    end

    # The release of an app that names it no other way: the hash of the file
    # digests the agent already sends (Metadata#file_manifest), so the same
    # code gives the same release. None when digests are off or truncated.
    def self.code_fingerprint(manifest)
      return unless manifest.is_a?(Hash) && !manifest["truncated"] && manifest["count"].to_i.positive?

      hash = manifest["hash"].to_s
      build("code:#{hash[0, 12]}", nil, "code_fingerprint") if hash.match?(/\A\h{12}/)
    end

    # ECS (Fargate, and EC2 with a recent agent) serves each container's
    # metadata at ECS_CONTAINER_METADATA_URI_V4. The image tag identifies the
    # release, and is the commit when it looks like one. A moving tag such
    # as "latest" can't, so the image digest does instead.
    def self.ecs(body)
      data = JSON.parse(body.to_s)
      return unless data.is_a?(Hash)

      tag = data["Image"].to_s.split("@", 2).first.to_s.split("/").last.to_s.split(":", 2)[1].to_s.strip
      if tag.downcase.match?(COMMIT_FORMAT)
        build(nil, tag, "ecs")
      elsif present?(tag) && !MOVING_TAGS.include?(tag.downcase)
        build(tag, nil, "ecs")
      elsif (digest = data["ImageID"].to_s[/\Asha256:(\h{12})/, 1])
        build("sha256:#{digest}", nil, "ecs")
      end
    rescue JSON::ParserError
      nil
    end

    # One request at boot to the container's own metadata endpoint, which
    # is local, so the timeouts are short. Nil on any failure.
    def self.fetch_metadata(uri)
      uri = URI.parse(uri)
      Net::HTTP.start(uri.host, uri.port, open_timeout: 0.5, read_timeout: 1) do |http|
        response = http.get(uri.request_uri)
        response.body if response.is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      nil
    end

    # The cloud rejects malformed commits, which would drop every payload,
    # so anything that is not a hex SHA is left out.
    def self.build(version, commit, source)
      commit = commit.to_s.strip.downcase
      new(present?(version) ? version.to_s.strip[0, 100] : nil,
        commit.match?(COMMIT_FORMAT) ? commit : nil,
        source)
    end

    # HEROKU_BUILD_COMMIT (runtime-dyno-build-metadata) replaces the
    # deprecated HEROKU_SLUG_COMMIT (runtime-dyno-metadata).
    def self.heroku_commit(env)
      present?(env["HEROKU_BUILD_COMMIT"]) ? env["HEROKU_BUILD_COMMIT"] : env["HEROKU_SLUG_COMMIT"]
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
