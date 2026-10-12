# frozen_string_literal: true

require "fileutils"
require "json"

module DeployAngel
  # Tokens `deployangel setup` saved for a project, so they never have to be
  # printed, pasted into a coding agent's chat, or kept in the environment:
  # .deployangel/credentials.json, readable only by its owner. The directory
  # carries its own .gitignore, so it stays out of git without touching the
  # project's.
  module Credentials
    DIR = ".deployangel"
    FILE = "credentials.json"

    module_function

    def path(root)
      File.join(root, DIR, FILE)
    end

    # From root or a parent directory, as git finds .git.
    def find(root)
      dir = File.expand_path(root)
      loop do
        candidate = path(dir)
        return candidate if File.file?(candidate)

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def read(root)
      file = find(root) or return {}
      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def write(root, data)
      dir = File.join(root, DIR)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".gitignore"), "*\n")
      file = path(root)
      File.open(file, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |io| io.write(JSON.pretty_generate(data)) }
      File.chmod(0o600, file)
      file
    end
  end
end
