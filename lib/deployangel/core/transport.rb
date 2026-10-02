# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "zlib"
require "stringio"

module DeployAngel
  # Sends gzipped JSON to DeployAngel. Only ever called from the background
  # thread, never from a request.
  class Transport
    Result = Struct.new(:outcome, :status, :retry_after, :body) do
      def ok?
        outcome == :ok
      end
    end

    def initialize(config)
      @config = config
    end

    # :ok (2xx), :retry (network error or 5xx), or :drop (any other status,
    # including 429 rate limiting, which the agent honors by pausing).
    def post(path, body)
      uri = URI.join(@config.endpoint.end_with?("/") ? @config.endpoint : "#{@config.endpoint}/", path.delete_prefix("/"))
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@config.token}"
      request["Content-Type"] = "application/json"
      request["Content-Encoding"] = "gzip"
      request["User-Agent"] = "deployangel-ruby/#{DeployAngel::VERSION} ruby/#{RUBY_VERSION}"
      request.body = gzip(JSON.generate(body))

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: @config.open_timeout, read_timeout: @config.read_timeout,
        write_timeout: @config.read_timeout) { |http| http.request(request) }
      classify(response)
    rescue StandardError => e
      Result.new(:retry, nil, nil).tap { @config.logger&.debug("DeployAngel transport error: #{e.class}: #{e.message}") }
    end

    private
      def classify(response)
        status = response.code.to_i
        case status
        when 200..299 then Result.new(:ok, status, nil, parse_body(response.body))
        when 500..599 then Result.new(:retry, status, nil)
        else Result.new(:drop, status, (response["Retry-After"].to_i if status == 429))
        end
      end

      def parse_body(body)
        body.to_s.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      def gzip(string)
        io = StringIO.new
        writer = Zlib::GzipWriter.new(io)
        writer.write(string)
        writer.close
        io.string
      end
  end
end
