module Kong
  # Runs the full "log into a connection" pipeline from docs/DESIGN.md
  # section 3: authenticate, probe write access, classify the credential,
  # locate and mark the admin path, and record the outcome -- never
  # collapsing a rejection into one generic "couldn't connect".
  class ConnectionLogin
    Result = Struct.new(:success, :error, :error_class, :connection, keyword_init: true) do
      def success?
        !!success
      end
    end

    def initialize(connection:, username:, secret:, operator: nil)
      @connection = connection
      @username = username
      @secret = secret
      @operator = operator
    end

    def call
      @connection.auth_username = @username
      client = Kong::Client.new(connection: @connection, secret: @secret)

      root = parsed(client.get("/"))
      @connection.kong_version = root["version"]
      @connection.mode = root.dig("configuration", "role") || root.dig("configuration", "database")
      # docs/DESIGN.md section 15 M4's plugin catalog: `enabled_in_cluster`
      # is the actually-creatable subset (loaded on this Kong node) --
      # `available_on_server` is everything the binary ships with, most of
      # which isn't loaded and would 400 on create. Stored verbatim so both
      # stay available without a second Kong call.
      @connection.plugins_available = root["plugins"] || {}

      @connection.access_level = Kong::AccessProbe.new(client).call
      @connection.credential_kind = Kong::CredentialClassifier.new(client, @connection).call
      @connection.admin_path_fingerprint = Kong::AdminPathGuard.new(client, @connection).call

      if @connection.shared_credential? && @operator.blank?
        return failure("this is a shared credential -- an operator name is required before it can be used")
      end

      persist_secret_if_stored
      @connection.last_connected_at = Time.current
      @connection.last_status = "ok"
      @connection.save!

      Result.new(success: true, connection: @connection)
    rescue Kong::Client::Error => e
      @connection.last_status = status_label(e)
      @connection.save!(validate: false)
      failure(e.message, error_class: e.class)
    end

    private

    def failure(message, error_class: nil)
      Result.new(success: false, error: message, error_class: error_class, connection: @connection)
    end

    def status_label(error)
      {
        Kong::Client::Unauthorized => "unauthorized",
        Kong::Client::Forbidden => "forbidden",
        Kong::Client::RouteNotMatched => "route_not_matched",
        Kong::Client::EntityNotFound => "not_found",
        Kong::Client::RateLimited => "rate_limited",
        Kong::Client::UpstreamUnavailable => "unavailable"
      }.fetch(error.class, "error")
    end

    def persist_secret_if_stored
      return unless @connection.credential_mode == "stored"

      @connection.auth_secret = @secret
    end

    def parsed(response)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end
  end
end
