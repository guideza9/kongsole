module Kong
  # Finds the Kong service/routes/plugins/consumers that form a connection's
  # own entry path into its Admin API, and records their ids as an
  # `admin_path_fingerprint` -- the guard docs/DESIGN.md section 1.1 calls
  # "M0's most important thing": since the Admin API is fronted by Kong
  # itself, the tool's own entry path is a Kong entity the tool can see and
  # edit, so it must never be deletable through this tool and must never be
  # rendered into decK YAML.
  #
  # Algorithm (design doc section 1.1):
  #   1. connection.admin_url -> host + path
  #   2. find the Kong route matching that host/path
  #   3. walk route -> service; if service.url points at 127.0.0.1/localhost
  #      on the admin_listen port, this is the admin path
  #   4. mark every route on that service, every plugin attached to the
  #      service or those routes, and every consumer an ACL plugin on them
  #      allows
  class AdminPathGuard
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    Fingerprint = Struct.new(:service_id, :route_ids, :plugin_ids, :consumer_ids, keyword_init: true) do
      def to_h
        {
          "service_id" => service_id,
          "route_ids" => route_ids,
          "plugin_ids" => plugin_ids,
          "consumer_ids" => consumer_ids
        }
      end
    end

    # Whether `kong_id` (a service, route, plugin, or consumer id) is part of
    # a connection's own admin path. Used to block delete/YAML-render
    # everywhere that decision matters, so the check lives in one place.
    def self.admin_path?(fingerprint, kong_id)
      return false if fingerprint.blank? || kong_id.blank?

      ids = [
        fingerprint["service_id"],
        *fingerprint["route_ids"],
        *fingerprint["plugin_ids"],
        *fingerprint["consumer_ids"]
      ]
      ids.compact.include?(kong_id)
    end

    def initialize(client, connection)
      @client = client
      @connection = connection
    end

    def call
      host, path = admin_host_and_path
      route = find_matching_route(host, path)
      return empty_fingerprint.to_h unless route

      service = route["service"] && fetch_service(route["service"]["id"])
      return empty_fingerprint.to_h unless service && loopback_service?(service)

      routes = fetch_routes_for_service(service["id"])
      route_ids = routes.map { |r| r["id"] }
      plugin_ids = fetch_plugin_ids(service["id"], route_ids)
      allow_groups = fetch_acl_allow_groups(plugin_ids)
      consumer_ids = allow_groups.any? ? fetch_consumers_in_groups(allow_groups) : []

      Fingerprint.new(
        service_id: service["id"],
        route_ids: route_ids,
        plugin_ids: plugin_ids,
        consumer_ids: consumer_ids
      ).to_h
    end

    private

    def empty_fingerprint
      Fingerprint.new(service_id: nil, route_ids: [], plugin_ids: [], consumer_ids: [])
    end

    def admin_host_and_path
      uri = URI.parse(@connection.admin_url)
      [ uri.host, uri.path.presence || "/" ]
    end

    def find_matching_route(host, path)
      each_page("/routes") do |route|
        hosts = Array(route["hosts"])
        paths = Array(route["paths"])
        host_match = hosts.include?(host)
        path_match = paths.any? { |p| path.start_with?(p) }
        return route if host_match || (hosts.empty? && path_match)
      end
      nil
    end

    def fetch_service(id)
      parsed(@client.get("/services/#{id}"))
    rescue Kong::Client::EntityNotFound
      nil
    end

    def loopback_service?(service)
      uri = URI.parse(service_url(service))
      LOOPBACK_HOSTS.include?(uri.host)
    rescue URI::InvalidURIError
      false
    end

    def service_url(service)
      return service["url"] if service["url"].present?
      return nil unless service["protocol"] && service["host"]

      "#{service['protocol']}://#{service['host']}:#{service['port']}"
    end

    def fetch_routes_for_service(service_id)
      parsed(@client.get("/services/#{service_id}/routes"))["data"] || []
    end

    def fetch_plugin_ids(service_id, route_ids)
      ids = Array(parsed(@client.get("/services/#{service_id}/plugins"))["data"]).map { |p| p["id"] }
      route_ids.each do |route_id|
        ids += Array(parsed(@client.get("/routes/#{route_id}/plugins"))["data"]).map { |p| p["id"] }
      end
      ids
    end

    def fetch_acl_allow_groups(plugin_ids)
      groups = plugin_ids.flat_map do |plugin_id|
        plugin = parsed(@client.get("/plugins/#{plugin_id}"))
        next [] unless plugin["name"] == "acl"

        Array(plugin.dig("config", "allow"))
      end
      groups.uniq
    end

    def fetch_consumers_in_groups(groups)
      consumer_ids = []
      each_page("/acls") do |acl|
        consumer_ids << acl.dig("consumer", "id") if groups.include?(acl["group"])
      end
      consumer_ids.compact.uniq
    end

    def each_page(path)
      offset = nil
      loop do
        page = parsed(@client.get(path, params: offset ? { offset: offset } : {}))
        Array(page["data"]).each { |item| yield item }
        offset = page["offset"]
        break if offset.blank?
      end
    end

    def parsed(response)
      body = response.body
      body.is_a?(String) ? JSON.parse(body) : body
    end
  end
end
