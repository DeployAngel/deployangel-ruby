# frozen_string_literal: true

require "hanami"
require "deployangel/hanami"
require "hanami/slice/routing/resolver"

module Bookshelf
  # A custom resolver, as some apps configure, which DeployAngel's builds on.
  class Resolver < Hanami::Slice::Routing::Resolver
  end

  class App < Hanami::App
    config.root = File.expand_path("..", __dir__)
    config.router.resolver = Resolver
    # As in production, where Hanami renders exceptions as error pages.
    config.render_errors = true
    config.logger.stream = File::NULL
    DeployAngel::Hanami.install(self)
    DeployAngel::Hanami.install(self)
  end
end
