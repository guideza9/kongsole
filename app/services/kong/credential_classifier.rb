module Kong
  # Classifies a connection's credential as `personal` or `shared` by reading
  # the Kong consumer's own tags (docs/DESIGN.md section 2): since the Admin
  # API is Kong itself, the tool can read its own consumer's tags directly.
  #
  # A team tags shared consumers (e.g. `kong-admin`, `deploy`) with
  # `shared-credential` once; absence of the tag means personal. When the tag
  # can't be read at all (consumer lookup denied, network error), falls back
  # to the connection's configured `shared_usernames` list from connections.yml.
  class CredentialClassifier
    SHARED_TAG = "shared-credential"

    def initialize(client, connection)
      @client = client
      @connection = connection
    end

    def call
      response = @client.get("/consumers/#{@connection.auth_username}")
      tags = Array(parsed(response)["tags"])
      tags.include?(SHARED_TAG) ? "shared" : "personal"
    rescue Kong::Client::Error
      fallback
    end

    private

    def fallback
      Array(@connection.shared_usernames).include?(@connection.auth_username) ? "shared" : "personal"
    end

    def parsed(response)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end
  end
end
