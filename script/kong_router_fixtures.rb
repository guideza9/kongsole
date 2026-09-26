# script/kong_router_fixtures.rb
# R5.0: records what compose Kong actually does for the R5 tracer -- which
# route wins (ordering.json) and what a service receives (join.json) -- so the
# tracer's specs test against Kong, not against our reading of its docs.
#
#   ruby script/kong_router_fixtures.rb
#
# Local compose only (CLAUDE.md rule 7). Everything it creates carries the tag
# r5-router-check and is deleted at the end, even after a failure.
#
# How a forwarded request is seen without an echo server: each join case's
# service points back at Kong's own proxy (127.0.0.1:8000) and adds the header
# x-r5-sink:1 (request-transformer); the r5-sink route matches that header
# (plus hosts and "/", so it outranks every test route) and answers with
# request-termination echo -- the echoed request is what a real service
# would have received.
require "json"
require "net/http"
require "uri"

ADMIN = URI(ENV.fetch("KONG_ADMIN", "http://localhost:8001"))
PROXY = URI(ENV.fetch("KONG_PROXY", "http://localhost:8000"))
abort "local compose only" unless [ ADMIN, PROXY ].all? { |uri| %w[localhost 127.0.0.1].include?(uri.host) }
TAG = "r5-router-check"
OUT = File.expand_path("../spec/fixtures/kong_router", __dir__)

def admin(verb, path, body = nil)
  request = Net::HTTP.const_get(verb.to_s.capitalize).new(path, "Content-Type" => "application/json")
  request.body = body.to_json if body
  response = Net::HTTP.start(ADMIN.host, ADMIN.port) { |http| http.request(request) }
  raise "#{verb} #{path} -> #{response.code} #{response.body}" unless response.code.start_with?("2")
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
end

def proxy(verb, host, path)
  request = Net::HTTP.const_get(verb.to_s.capitalize).new(path, "Host" => host)
  response = Net::HTTP.start(PROXY.host, PROXY.port) { |http| http.request(request) }
  body = begin
    JSON.parse(response.body)
  rescue JSON::ParserError
    {}
  end
  [ response.code.to_i, body ]
end

def cleanup
  %w[plugins routes services upstreams].each do |collection|
    admin(:get, "/#{collection}?tags=#{TAG}&size=1000").fetch("data").each { |row| admin(:delete, "/#{collection}/#{row['id']}") }
  end
end

def route(name, service_id, **attrs)
  admin(:post, "/routes", { name: name, service: { id: service_id }, protocols: %w[http], tags: [ TAG ] }.merge(attrs))
end

def echo_on(route_id)
  admin(:post, "/plugins", name: "request-termination", route: { id: route_id }, config: { status_code: 200, echo: true }, tags: [ TAG ])
end

def loop_service(name, path)
  service = admin(:post, "/services", { name: name, protocol: "http", host: "127.0.0.1", port: 8000, tags: [ TAG ] }.merge(path ? { path: path } : {}))
  admin(:post, "/plugins", name: "request-transformer", service: { id: service["id"] }, config: { add: { headers: [ "x-r5-sink:1" ] } }, tags: [ TAG ])
  service
end

ORDER_CASES = [
  { name: "longer prefix wins", request: %w[GET /api/v1/x], routes: [ { name: "short", paths: %w[/api] }, { name: "long", paths: %w[/api/v1] } ] },
  { name: "a prefix is a plain string prefix", request: %w[GET /billingx], routes: [ { name: "billing", paths: %w[/billing] } ] },
  { name: "more conditions win", request: %w[GET /api], routes: [ { name: "paths-only", paths: %w[/api] }, { name: "with-method", paths: %w[/api], methods: %w[GET] } ] },
  { name: "regex against prefix", request: %w[GET /api/v2], routes: [ { name: "prefix", paths: %w[/api] }, { name: "regex", paths: [ "~/api/v[0-9]+$" ] } ] },
  { name: "higher regex_priority wins", request: %w[GET /api/v2], routes: [ { name: "rx-low", paths: [ "~/api/v\\d" ], regex_priority: 0 }, { name: "rx-high", paths: [ "~/api/v2" ], regex_priority: 5 } ] },
  { name: "exact host beats wildcard", host: "api.o6.r5.test", request: %w[GET /x], routes: [ { name: "wild", hosts: [ "*.o6.r5.test" ], paths: %w[/x] }, { name: "exact", hosts: [ "api.o6.r5.test" ], paths: %w[/x] } ] },
  { name: "older route wins a tie", request: %w[GET /tie], routes: [ { name: "first", paths: %w[/tie] }, { name: "second", paths: %w[/tie] } ] },
  { name: "a method the route does not allow", request: %w[POST /reads], routes: [ { name: "reads", paths: %w[/reads], methods: %w[GET] } ] },
  { name: "the best of a route's paths counts", request: %w[GET /api/v1/x], routes: [ { name: "many-paths", paths: %w[/a /api/v1] }, { name: "mid", paths: %w[/api] } ] }
].freeze

JOIN_CASES = [
  # name, service path, route path, strip_path, path_handling, request path (+ preserve_host)
  [ "v0 strip, plain", "/s", "/tv0", true, "v0", "/tv0req" ],
  [ "v1 strip, plain", "/s", "/tv1", true, "v1", "/tv1req" ],
  [ "v0 keep, plain", "/s", "/fv0", false, "v0", "/fv0req" ],
  [ "v1 keep, plain", "/s", "/fv1", false, "v1", "/fv1req" ],
  [ "v0 strip, route slash", "/s", "/tv0/", true, "v0", "/tv0/req" ],
  [ "v1 strip, route slash", "/s", "/tv1/", true, "v1", "/tv1/req" ],
  [ "v0 strip, service slash", "/s/", "/tv0", true, "v0", "/tv0/req" ],
  [ "v1 strip, service slash", "/s/", "/tv1", true, "v1", "/tv1/req" ],
  [ "strip, nothing left, no service path", nil, "/notify", true, "v0", "/notify" ],
  [ "strip, nothing left, service path", "/api", "/notify", true, "v0", "/notify" ],
  [ "keep, no service path", nil, "/ledger", false, "v0", "/ledger/entries/9" ],
  [ "regex strip", "/v2", "~/reports/\\d{4}", true, "v0", "/reports/2026/q3" ],
  [ "query passed on", "/api", "/billing/v1", true, "v0", "/billing/v1/invoices/42?status=paid" ],
  [ "preserve_host on", "/api", "/ph", true, "v0", "/ph/x", true ]
].freeze

begin
  root = admin(:get, "/")
  cleanup

  sink_service = admin(:post, "/services", name: "r5-sink", url: "http://127.0.0.1:65535", tags: [ TAG ])
  sink = route("r5-sink", sink_service["id"], hosts: [ "127.0.0.1", "*.r5.test", "r5-up" ], headers: { "x-r5-sink" => [ "1" ] }, paths: %w[/], strip_path: false)
  echo_on(sink["id"])

  # Build every case first, then probe: Kong (DB mode) rebuilds its router
  # in the background, so a route is not live the moment the Admin API
  # answers 201. A canary created last says when the rebuild has caught up.
  ORDER_CASES.each_with_index do |kase, index|
    host = kase[:host] || "o#{index}.r5.test"
    target = admin(:post, "/services", name: "r5-order-#{index}", url: "http://127.0.0.1:65535", tags: [ TAG ])
    kase[:routes].each do |attrs|
      created = route("#{attrs[:name]}-#{index}", target["id"], **{ hosts: [ host ] }.merge(attrs.except(:name)))
      echo_on(created["id"])
      sleep 1.1 # Kong's created_at has one-second resolution; the tie case needs them apart
    end
  end

  JOIN_CASES.each_with_index do |(_, service_path, route_path, strip, handling, _, preserve), index|
    service = loop_service("r5-join-#{index}", service_path)
    route("r5-join-#{index}", service["id"], hosts: [ "j#{index}.r5.test" ], paths: [ route_path ], strip_path: strip,
      path_handling: handling, preserve_host: preserve || false)
  end

  canary_service = admin(:post, "/services", name: "r5-canary", url: "http://127.0.0.1:65535", tags: [ TAG ])
  echo_on(route("r5-canary", canary_service["id"], hosts: [ "canary.r5.test" ], paths: %w[/canary])["id"])
  deadline = Time.now + 60
  sleep 1 until proxy("GET", "canary.r5.test", "/canary").first == 200 || Time.now > deadline
  abort "router never picked up the canary route" if Time.now > deadline
  sleep 2 # the second node and any in-flight rebuild

  ordering = ORDER_CASES.each_with_index.map do |kase, index|
    host = kase[:host] || "o#{index}.r5.test"
    status, body = proxy(kase[:request][0], host, kase[:request][1])
    winner = body.dig("matched_route", "name")&.delete_suffix("-#{index}")
    { name: kase[:name], request: { method: kase[:request][0], host: host, path: kase[:request][1] },
      routes: kase[:routes], got: { status: status, route: winner } }
  end

  join = JOIN_CASES.each_with_index.map do |(name, service_path, route_path, strip, handling, request_path, preserve), index|
    host = "j#{index}.r5.test"
    status, body = proxy("GET", host, request_path)
    { name: name, service_path: service_path, route_path: route_path, strip_path: strip, path_handling: handling,
      preserve_host: preserve || false, request: { host: host, path: request_path },
      got: { status: status, path: body.dig("request", "path"), query: body.dig("request", "query"),
             host: body.dig("request", "headers", "host") } }
  end

  meta = { kong_version: root["version"], router_flavor: root.dig("configuration", "router_flavor"), recorded_at: Time.now.utc.iso8601 }
  File.write(File.join(OUT, "ordering.json"), JSON.pretty_generate(meta.merge(cases: ordering)) + "\n")
  File.write(File.join(OUT, "join.json"), JSON.pretty_generate(meta.merge(cases: join)) + "\n")
  puts "wrote #{ordering.size} ordering and #{join.size} join cases (Kong #{meta[:kong_version]}, #{meta[:router_flavor]})"
ensure
  cleanup
end
