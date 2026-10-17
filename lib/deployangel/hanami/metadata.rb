# frozen_string_literal: true

module DeployAngel
  module Hanami
    # The Hanami adapter: the route table, each route's action and the files
    # behind it, and Hanami's layout for the file digests. Schedules read on
    # every framework, and the digests themselves, are in
    # DeployAngel::Metadata.
    class Metadata < ::DeployAngel::Metadata
      DIGEST_GLOBS = %w[app/**/* slices/**/* config/**/* lib/**/* Gemfile.lock].freeze
      SKIPPED_METHODS = %w[HEAD OPTIONS].freeze

      def initialize(app:, config:, root:, environment:)
        super(config: config, root: root, environment: environment)
        @app = app
      end

      def digest_globs
        DIGEST_GLOBS
      end

      # The routes as `hanami routes` lists them: a second router, built
      # only to be inspected, whose endpoints are never resolved or called.
      def routes
        RouteTable.new(@app).routes.filter_map do |http_method, path, endpoint|
          next if SKIPPED_METHODS.include?(http_method)

          key = "#{http_method} #{path}"
          next if health_check_path?(path) || @config.ignored_route?(key)

          route = { "key" => key }
          route["controller"] = endpoint[:class_name] if endpoint[:class_name]
          files = endpoint[:files].filter_map { |file| app_relative(file) }.uniq
          route["files"] = files unless files.empty?
          route
        end.uniq { |route| route["key"] }
      rescue StandardError
        []
      end
    end

    # [http_method, path, endpoint] for each route, where endpoint is
    # { class_name:, files: }: the action class and its file, view, and
    # templates, or the file a lambda or Rack app is defined in.
    class RouteTable
      # Takes each route's definition from the router.
      class Inspector
        attr_reader :routes

        def initialize
          @routes = []
        end

        def add_route(route)
          @routes << route
        end

        def call(*) = ""
      end

      def initialize(app)
        @app = app
      end

      def routes
        require "hanami/slice/router"
        require "hanami/slice/routing/resolver"

        targets = {}
        inspector = Inspector.new
        resolver = Class.new(::Hanami::Slice::Routing::Resolver) do
          # Which slice each `to:` belongs to; nothing is resolved.
          define_method(:call) do |path, endpoint|
            targets[[ path.to_s, endpoint ]] ||= slice
            ->(*) {}
          end
        end
        options = { inspector: inspector, routes: @app.routes, resolver: resolver.new(slice: @app) }
        # Hanami 3's slice router needs the app's inflector; 2.2's takes none.
        options[:inflector] = @app.inflector if router_takes?(:inflector)
        ::Hanami::Slice::Router.new(**options) { nil }

        inspector.routes.map do |route|
          path = route.path.to_s
          [ route.http_method.to_s.upcase, path, endpoint(route.to, targets[[ path, route.to ]] || @app) ]
        end
      end

      private
        def router_takes?(keyword)
          ::Hanami::Slice::Router.instance_method(:initialize).parameters.any? { |type, name| %i[key keyreq].include?(type) && name == keyword }
        end

        def endpoint(to, slice)
          case to
          when String then action(to, slice)
          when Proc then { class_name: nil, files: [ to.source_location&.first ] }
          when Module then { class_name: to.name, files: [ source_file(to.name) ] }
          else { class_name: to.class.name, files: [ source_file(to.class.name) ] }
          end
        end

        # "books.show" in a slice is its Actions::Books::Show, in
        # app/actions/books/show.rb (slices/<name>/actions/... in a slice),
        # rendered by the view and templates at the same name.
        def action(key, slice)
          parts = key.split(".")
          name = [ slice.namespace.name, "Actions", *parts.map { |part| slice.inflector.camelize(part) } ].join("::")
          file = source_file(name)
          files = [ file ]
          if file&.include?("/actions/")
            files << file.sub("/actions/", "/views/")
            templates = File.dirname(file.sub("/actions/", "/templates/"))
            files.concat(Dir.glob(File.join(templates, "#{File.basename(file, ".rb")}.*")))
          end
          { class_name: name, files: files.compact.select { |path| File.file?(path) } }
        end

        # Loads the class (Zeitwerk autoloads it; nothing is instantiated),
        # since a constant not loaded yet has no source location.
        def source_file(name)
          return unless name

          Object.const_get(name)
          Object.const_source_location(name)&.first
        rescue NameError, StandardError
          nil
        end
    end
  end
end
