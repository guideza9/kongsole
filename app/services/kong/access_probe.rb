module Kong
  # Determines whether a connection's credential can write to the Admin API,
  # without any side effect, by sending a write-method request at an id that
  # cannot exist (docs/DESIGN.md section 3, "Probe สิทธิ์").
  #
  # - `no Route matched` (Kong's router rejecting the method) => read-only credential.
  # - `Not found` (the Admin API answering) => the request reached the Admin API => read-write.
  class AccessProbe
    PROBE_PATH = "/routes/00000000-0000-0000-0000-000000000000"

    def initialize(client)
      @client = client
    end

    def call
      @client.patch(PROBE_PATH, body: {})
      "rw"
    rescue Kong::Client::EntityNotFound
      "rw"
    rescue Kong::Client::RouteNotMatched
      "ro"
    end
  end
end
