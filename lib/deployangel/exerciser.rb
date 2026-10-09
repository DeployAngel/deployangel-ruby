# frozen_string_literal: true

require "net/http"
require "uri"

module DeployAngel
  # `deployangel exercise`: sends a release's exercise plan's read-only
  # requests to production from the customer's side, then records what it
  # sent, so the release page says which routes were exercised that way.
  # Only GET routes with no path parameters and not marked as changing data;
  # the rest are skipped and named, for the agent or a smoke test with a test
  # account. The requests count like any traffic through the app's agent.
  class Exerciser
    MAX_REQUESTS = 200
    INTERVAL = 0.2 # about 5 requests a second
    TIMEOUT = 10
    # Stop when the app isn't answering, rather than send the rest into it.
    MAX_CONSECUTIVE_ERRORS = 5
    # A route table can list pages an app doesn't serve, like the edit page
    # of a resource that has none. One answer like this is enough to know.
    NOT_SERVED = [ 404, 405, 410 ].freeze
    # Rails' :id and *path, Django's <int:pk>, FastAPI's {id}.
    PARAMETER = /\/[:*{<]/

    Target = Struct.new(:key, :path, :count)
    Result = Struct.new(:routes, :skipped, :sent, :unreachable, keyword_init: true)

    def initialize(base_url:, max_requests: MAX_REQUESTS, sleeper: ->(seconds) { sleep(seconds) }, requester: nil)
      @base = URI(base_url)
      @max_requests = max_requests
      @sleeper = sleeper
      @requester = requester || method(:get)
    end

    # What would be sent: [targets, skipped].
    def plan(exercise_plan)
      skipped = []
      targets = []
      Array(exercise_plan["items"]).each do |item|
        next unless item["kind"] == "route"

        method, path = item["key"].to_s.split(" ", 2)
        reason =
          if item["mutating"] || method != "GET" then "changes data"
          elsif path.nil? || path.match?(PARAMETER) then "needs a path parameter"
          end
        next skipped << { "key" => item["key"], "reason" => reason } if reason

        needed = item["runs_needed"] ? item["runs_needed"].to_i - item["runs"].to_i : 1
        targets << Target.new(item["key"], path, [ needed, 1 ].max)
      end
      spread_shortfall(targets, exercise_plan.dig("shortfall", "requests"))
      cap(targets)
      [ targets, skipped ]
    end

    # A route whose first request says it isn't served gets no more; its
    # share goes to the routes that answered.
    def run(exercise_plan)
      targets, skipped = plan(exercise_plan)
      @statuses = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      @sent = 0
      @errors_in_a_row = 0
      leftover = 0
      answered = []
      targets.each do |target|
        target.count.times do |i|
          break if unreachable?

          status = send_request(target)
          if i.zero? && NOT_SERVED.include?(status)
            leftover += target.count - 1
            break
          end
        end
        answered << target if @statuses[target.key].keys.intersect?(%w[2xx 3xx])
      end
      leftover.times { |i| send_request(answered[i % answered.size]) unless unreachable? } if answered.any?

      routes = targets.filter_map do |target|
        statuses = @statuses.fetch(target.key, nil) or next
        { "key" => target.key, "requests" => statuses.values.sum, "statuses" => statuses.to_h }
      end
      Result.new(routes: routes, skipped: skipped, sent: @sent, unreachable: unreachable?)
    end

    def url_for(path)
      uri = @base.dup
      uri.path = "#{@base.path.chomp("/")}#{path}"
      uri.query = nil
      uri.to_s
    end

    private
      def send_request(target)
        @sleeper.call(INTERVAL) if @sent.positive?
        status = @requester.call(url_for(target.path))
        @sent += 1
        kind = status ? "#{status / 100}xx" : "error"
        @statuses[target.key][kind] += 1
        @errors_in_a_row = kind == "error" ? @errors_in_a_row + 1 : 0
        status
      end

      def unreachable?
        @errors_in_a_row >= MAX_CONSECUTIVE_ERRORS
      end

      # Requests the release is short of overall, spread across the routes,
      # or sent to the home page when the plan names no route to send them to.
      def spread_shortfall(targets, requests)
        return unless requests

        extra = requests["need"].to_i - requests["have"].to_i - targets.sum(&:count)
        return unless extra.positive?

        targets << Target.new("GET /", "/", 0) if targets.empty?
        extra.times { |i| targets[i % targets.size].count += 1 }
      end

      def cap(targets)
        targets.max_by(&:count).count -= 1 while targets.sum(&:count) > @max_requests
      end

      # The status code, or nil when there was no answer. Redirects aren't
      # followed: the request already reached the app.
      def get(url)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "DeployAngel-Exercise/#{DeployAngel::VERSION} (+https://www.deployangel.com/docs#exercise)"
        request["Accept"] = "text/html,application/json;q=0.9,*/*;q=0.8"
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.request(request).code.to_i
        end
      rescue StandardError
        nil
      end
  end
end
