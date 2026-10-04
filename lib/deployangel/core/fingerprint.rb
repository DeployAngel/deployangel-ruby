# frozen_string_literal: true

require "digest"

module DeployAngel
  # Exception fingerprint algorithm v1. Stable across deployments:
  # no line numbers, no messages, no gem versions, no absolute paths, and no
  # Ruby-version-specific label formatting.
  module Fingerprint
    VERSION = 1
    GEM_PATH = %r{/gems/([^/]+?)-\d[^/]*/(.+)\z}
    MESSAGE_PLACEHOLDERS = [
      [ /\b[\w.+-]+@[\w-]+\.[\w.-]+\b/, "<email>" ],
      [ /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i, "<uuid>" ],
      [ /\b0x[0-9a-f]+\b|\b[0-9a-f]{16,}\b/i, "<hex>" ],
      [ /(["'`]).*?\1/, "<string>" ],
      [ /\b\d+(\.\d+)?\b/, "<n>" ]
    ].freeze
    MAX_MESSAGE = 200
    MAX_BACKTRACE = 20

    module_function

    # message: false leaves the message out entirely. redactions are
    # [value, placeholder] pairs replaced first (Redaction).
    def for(exception, root:, message: true, redactions: [])
      frame = top_frame(exception, root: root)
      {
        "fingerprint" => Digest::SHA256.hexdigest([ "v#{VERSION}", exception.class.name, frame ].join("|"))[0, 32],
        "fingerprint_version" => VERSION,
        "exception_class" => exception.class.name,
        "message" => (normalize_message(exception.message, redactions) if message),
        "top_frame" => frame,
        "app_frame" => app_frame?(frame)
      }
    end

    # First application frame as "relative/path.rb#method", else the first
    # frame normalized as "gem/path/in/gem.rb#method".
    def top_frame(exception, root:)
      frames = locations(exception)
      app = frames.find { |path, _| app_path?(path, root) }
      path, label = app || frames.first
      return "unknown" unless path

      "#{normalize_path(path, root)}##{label}"
    end

    # Application frames only, relative to the root.
    def backtrace(exception, root:)
      locations(exception).select { |path, _| app_path?(path, root) }.first(MAX_BACKTRACE)
        .map { |path, label| "#{normalize_path(path, root)}##{label}" }
    end

    # Only quoted values, numbers, emails, UUIDs, and long hex are replaced;
    # unquoted words, such as a name in a message the app builds, are kept.
    def normalize_message(message, redactions = [])
      text = message.to_s.lines.first.to_s.strip
      redactions.each do |value, placeholder|
        text = text.gsub(/(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/i, placeholder)
      end
      MESSAGE_PLACEHOLDERS.each { |pattern, placeholder| text = text.gsub(pattern, placeholder) }
      text[0, MAX_MESSAGE]
    end

    def app_frame?(frame)
      frame.start_with?("app/", "lib/", "config/")
    end

    def locations(exception)
      if exception.backtrace_locations
        exception.backtrace_locations.map { |location| [ location.absolute_path || location.path, location.base_label ] }
      else
        Array(exception.backtrace).map do |line|
          path, _, label = line.partition(":in ")
          [ path.sub(/:\d+\z/, ""), label.delete("`'").split(/[#.]/).last.to_s.sub(/\A(block|rescue|ensure) (\(\d+ levels\) )?in /, "") ]
        end
      end
    end

    def app_path?(path, root)
      return false unless root && path&.start_with?(root)

      relative = path.delete_prefix(root).delete_prefix("/")
      !relative.start_with?("vendor/", "node_modules/", "tmp/")
    end

    def normalize_path(path, root)
      if root && path.start_with?(root)
        path.delete_prefix(root).delete_prefix("/")
      elsif (match = GEM_PATH.match(path))
        "#{match[1]}/#{match[2]}"
      else
        File.basename(path.to_s)
      end
    end
  end
end
