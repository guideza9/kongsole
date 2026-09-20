#!/bin/sh
# Bootstraps the Kong-fronts-its-own-Admin-API loopback pattern from
# docs/DESIGN.md section 1.3, directly against Kong's local Admin API.
#
# This runs once, sharing kong-1's network namespace (network_mode:
# "service:kong-1" in docker-compose.yml), so it can reach 127.0.0.1:8001 --
# the same loopback the `admin-api` service itself will point at -- exactly
# the way a real bootstrap (Helm/declarative config, per section 1.6) would.
# Because kong-1 and kong-2 share one Postgres-backed config store, this
# only needs to run once: kong-2 sees the same entities immediately.
#
# Idempotent: safe to run again on every `docker compose up`.
set -e

ADMIN=http://127.0.0.1:8001
DEV_PASSWORD=devpassword # local compose stack only -- never a real credential

wait_for_admin() {
  echo "waiting for Kong Admin API at $ADMIN ..."
  until curl -sf "$ADMIN/status" > /dev/null 2>&1; do
    sleep 1
  done
}

exists() {
  curl -sf "$ADMIN$1" > /dev/null 2>&1
}

wait_for_admin

if ! exists "/services/admin-api"; then
  echo "creating service: admin-api (loopback to 127.0.0.1:8001)"
  curl -sf -X POST "$ADMIN/services" \
    -d "name=admin-api" -d "url=http://127.0.0.1:8001" -d "tags[]=kong-admin-path" > /dev/null
fi

if ! exists "/routes/admin-api-rw"; then
  echo "creating route: admin-api-rw (kong-admin.internal, all methods)"
  curl -sf -X POST "$ADMIN/services/admin-api/routes" \
    -d "name=admin-api-rw" -d "hosts[]=kong-admin.internal" -d "tags[]=kong-admin-path" > /dev/null
fi

if ! exists "/routes/admin-api-ro"; then
  echo "creating route: admin-api-ro (kong-admin-ro.internal, GET/HEAD only)"
  curl -sf -X POST "$ADMIN/services/admin-api/routes" \
    -d "name=admin-api-ro" -d "hosts[]=kong-admin-ro.internal" \
    -d "methods[]=GET" -d "methods[]=HEAD" -d "tags[]=kong-admin-path" > /dev/null
fi

ensure_plugin_on_route() {
  route="$1"; plugin="$2"; shift 2
  if ! curl -sf "$ADMIN/routes/$route/plugins" | grep -q "\"name\":\"$plugin\""; then
    echo "attaching plugin: $plugin -> route $route"
    curl -sf -X POST "$ADMIN/routes/$route/plugins" -d "name=$plugin" "$@" > /dev/null
  fi
}

ensure_plugin_on_route admin-api-rw basic-auth -d "config.hide_credentials=true"
ensure_plugin_on_route admin-api-rw acl -d "config.allow[]=kong-admin-rw"
ensure_plugin_on_route admin-api-ro basic-auth -d "config.hide_credentials=true"
ensure_plugin_on_route admin-api-ro acl -d "config.allow[]=kong-admin-ro"

ensure_consumer() {
  username="$1"; group="$2"; kind="$3"

  if ! exists "/consumers/$username"; then
    echo "creating consumer: $username ($kind, group $group)"
    if [ "$kind" = "shared" ]; then
      curl -sf -X POST "$ADMIN/consumers" -d "username=$username" -d "tags[]=shared-credential" > /dev/null
    else
      curl -sf -X POST "$ADMIN/consumers" -d "username=$username" > /dev/null
    fi
    curl -sf -X POST "$ADMIN/consumers/$username/acls" -d "group=$group" > /dev/null
    curl -sf -X POST "$ADMIN/consumers/$username/basic-auth" -d "username=$username" -d "password=$DEV_PASSWORD" > /dev/null
  fi
}

# Matches docs/DESIGN.md section 1.3's example consumers, plus one shared
# credential so Kong::CredentialClassifier has something real to classify.
ensure_consumer jakkapat kong-admin-rw personal
ensure_consumer ro-kongctl kong-admin-ro personal
ensure_consumer kong-admin kong-admin-rw shared

echo "admin path bootstrap complete."
echo "  rw:  curl -u jakkapat:$DEV_PASSWORD -H 'Host: kong-admin.internal' http://localhost:8000/"
echo "  ro:  curl -u ro-kongctl:$DEV_PASSWORD -H 'Host: kong-admin-ro.internal' http://localhost:8000/"
echo "  shared: curl -u kong-admin:$DEV_PASSWORD -H 'Host: kong-admin.internal' http://localhost:8000/"
