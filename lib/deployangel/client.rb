# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module DeployAngel
  # Read and registration API client for the CLI and MCP server (spec §27).
  # Unlike the agent's Transport, errors raise, because a person or coding
  # agent is waiting on the answer.
  class Client
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: nil)
        super(message)
        @status = status
      end
    end
    class NotFound < Error; end
    class Unauthorized < Error; end

    attr_reader :endpoint

    def initialize(token:, endpoint: Configuration::DEFAULT_ENDPOINT, timeout: 15)
      raise Unauthorized, "DEPLOYANGEL_API_TOKEN is not set" if token.to_s.empty?

      @token = token
      @endpoint = endpoint.to_s.chomp("/")
      @timeout = timeout
    end

    def token_info = get("/api/v1/token")
    def latest_deployment = get("/api/v1/deployments/latest")
    def deployments(**filters) = get("/api/v1/deployments", filters.compact)["deployments"]
    def exception(fingerprint) = get("/api/v1/exceptions/#{URI.encode_www_form_component(fingerprint)}")
    def late_regressions(**filters) = get("/api/v1/late_regressions", filters.compact)["late_regressions"]

    def verification(deployment_id, all_findings: false)
      get("/api/v1/deployments/#{deployment_id}/verification", all_findings ? { findings: "all" } : {})
    end

    def register_deployment(commit: nil, version: nil, kind: nil, provider: nil, source_url: nil)
      post("/api/v1/deployments", { commit: commit, version: version, kind: kind, provider: provider, source_url: source_url }.compact)
    end

    def report_check(deployment_ref, name:, status:, covers: [], details_url: nil)
      post("/api/v1/deployments/#{URI.encode_www_form_component(deployment_ref)}/checks",
        { name: name, status: status, covers: covers, details_url: details_url }.compact)
    end

    private
      def get(path, params = {})
        uri = URI("#{@endpoint}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?
        request(Net::HTTP::Get.new(uri))
      end

      def post(path, body)
        request = Net::HTTP::Post.new(URI("#{@endpoint}#{path}"))
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        request(request)
      end

      def request(request)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        request["User-Agent"] = "deployangel-cli/#{DeployAngel::VERSION}"
        uri = request.uri
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: @timeout, read_timeout: @timeout) { |http| http.request(request) }
        handle(response)
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach #{@endpoint}: #{e.class}: #{e.message}"
      end

      def handle(response)
        body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
        case response.code.to_i
        when 200..299 then body
        when 404 then raise NotFound.new(body["error"] || "not found", status: 404)
        when 401, 403 then raise Unauthorized.new(body["error"] || "unauthorized", status: response.code.to_i)
        else raise Error.new(body["error"] || "HTTP #{response.code}", status: response.code.to_i)
        end
      rescue JSON::ParserError
        raise Error.new("unexpected response (HTTP #{response.code})", status: response.code.to_i)
      end
  end
end
