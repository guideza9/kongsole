require "faraday"
require "faraday/retry"

module Kong
  # Thin HTTP client for a Kong Gateway CE Admin API, reached through the
  # loopback route this tool manages itself (docs/DESIGN.md section 1).
  #
  # Because the Admin API sits behind Kong, a single HTTP status can mean six
  # materially different things depending on which layer produced it (basic-auth
  # plugin, ACL plugin, Kong's own router, the Admin API, rate-limiting, or the
  # loopback service being down). This client maps every case in the design
  # doc's section 1.4 table to its own exception class so callers -- and the UI
  # -- never collapse them into one generic "connection failed".
  #
  # The `Authorization` header is built by Faraday's basic-auth middleware and
  # is never touched by any log/instrumentation this client installs; see the
  # log-safety spec in spec/services/kong/client_spec.rb.
  class Client
    class Error < StandardError
      attr_reader :response

      def initialize(message, response: nil)
        super(message)
        @response = response
      end
    end

    # 401 + WWW-Authenticate, {"message":"Unauthorized"} -- basic-auth plugin: credential missing or wrong.
    class Unauthorized < Error; end
    # 403, {"message":"You cannot consume this service"} -- ACL plugin: consumer not in an allowed group.
    class Forbidden < Error; end
    # 404, {"message":"no Route matched with those values"} -- Kong's router: method not permitted
    # (the read-only route rejected a write) or the host/path is simply wrong. Never "not found".
    class RouteNotMatched < Error; end
    # 404, {"message":"Not found"} -- the Admin API itself: the entity genuinely does not exist.
    class EntityNotFound < Error; end
    # 429, {"message":"API rate limit exceeded"} -- rate-limiting plugin.
    class RateLimited < Error; end
    # 502/503, or a connection failure -- the loopback service (Admin API listener) is not up.
    class UpstreamUnavailable < Error; end
    # This machine could not reach the Admin API at all (DNS, refused, timeout,
    # TLS -- Kong::NetworkFailure): often not on the project's network, not
    # Kong being down. A subclass so every `rescue UpstreamUnavailable` still
    # catches it.
    class NetworkUnreachable < UpstreamUnavailable
      attr_reader :kind

      def initialize(message, kind:, response: nil)
        super(message, response: response)
        @kind = kind
      end
    end
    # Anything else: surfaced rather than silently swallowed.
    class UnexpectedResponse < Error; end

    DEFAULT_TIMEOUT = 5
    DEFAULT_OPEN_TIMEOUT = 3
    ROUTER_REJECTION_MESSAGE = "no Route matched with those values"

    # The connection this client talks to -- Kong::SchemaCache keys its copy by it.
    attr_reader :connection

    def initialize(connection:, secret: nil, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT)
      @connection = connection
      @secret = secret || connection.auth_secret
      @timeout = timeout
      @open_timeout = open_timeout
    end

    def get(path, params: {})
      request(:get, path, params: params)
    end

    def patch(path, body: {})
      request(:patch, path, body: body)
    end

    def post(path, body: {})
      request(:post, path, body: body)
    end

    def delete(path)
      request(:delete, path)
    end

    private

    def request(method, path, params: nil, body: nil)
      response = faraday.public_send(method) do |req|
        req.url(path)
        req.params.update(params) if params.present?
        if body
          req.headers["Content-Type"] = "application/json"
          req.body = body.to_json
        end
      end
      handle_response(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      # e.message is left out: it can carry a URL with userinfo.
      kind = Kong::NetworkFailure.classify(e)
      raise NetworkUnreachable.new("Kong Admin API unreachable at #{@connection.admin_url} (#{kind})", kind: kind)
    end

    def handle_response(response)
      case response.status
      when 200..299
        response
      when 401
        raise Unauthorized.new("credential rejected by basic-auth plugin", response: response)
      when 403
        raise Forbidden.new("consumer is not in an allowed ACL group", response: response)
      when 404
        if router_rejection?(response)
          raise RouteNotMatched.new(
            "no Kong route matched (method not permitted -- this credential likely can't write -- or wrong host/path)",
            response: response
          )
        else
          raise EntityNotFound.new("entity does not exist", response: response)
        end
      when 429
        raise RateLimited.new("Kong Admin API rate limit exceeded", response: response)
      when 502, 503
        raise UpstreamUnavailable.new("Kong Admin API upstream unavailable (loopback service down)", response: response)
      else
        raise UnexpectedResponse.new("unexpected Kong Admin API status #{response.status}", response: response)
      end
    end

    def router_rejection?(response)
      response_message(response) == ROUTER_REJECTION_MESSAGE
    end

    def response_message(response)
      body = parsed_body(response)
      body.is_a?(Hash) ? body["message"] : nil
    end

    def parsed_body(response)
      body = response.body
      return body unless body.is_a?(String)

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def faraday
      @faraday ||= Faraday.new(url: @connection.admin_url) do |f|
        if @connection.auth_type == "basic" && @secret.present?
          f.request :authorization, :basic, @connection.auth_username, @secret
        end
        f.request :retry, max: 2, interval: 0.2, interval_randomness: 0.2, backoff_factor: 2,
                           exceptions: [ Faraday::ConnectionFailed, Faraday::TimeoutError ]
        f.options.timeout = @timeout
        f.options.open_timeout = @open_timeout
        f.ssl.verify = @connection.verify_ssl
        f.ssl.ca_file = @connection.ca_bundle_path if @connection.ca_bundle_path.present?
        f.adapter Faraday.default_adapter
      end
    end
  end
end
