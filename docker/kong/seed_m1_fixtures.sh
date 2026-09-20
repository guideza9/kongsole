#!/bin/sh
# Seeds product-shaped fixture data into the local dev Kong stack so M1
# (kong_entities sync, EntityQuery filter/sort/keyset, the services list/
# detail UI, and the MCP search/plan tools) has something real to work
# against.
#
# Unlike bootstrap.sh (which runs *inside* kong-1's network namespace as a
# one-off compose service, so it can prove the loopback pattern from the
# same vantage point a real bootstrap job would), this is a manual,
# host-side script: run it from the repo root with `docker compose up -d`
# already running. It talks to kong-1's Admin API on the port docker-compose
# publishes to localhost (8001) and shells out to `docker compose exec
# kong-database psql` to backdate a subset of rows -- neither of which a
# fixture-seeding script needs to prove anything about the guarded path, so
# there's no reason to run it from inside the container.
#
# Every entity this script creates carries the tag `m1-fixture` (plus, for
# the backdated subset, `m1-fixture-old`) so it is trivially distinguishable
# from the admin-path entities bootstrap.sh creates, and trivially removable
# with teardown_m1_fixtures.sh. Never touches admin-api / admin-api-rw /
# admin-api-ro or the kong-admin-path consumers.
#
# Idempotent: safe to run again.
set -e

ADMIN=http://127.0.0.1:8001

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

# 8 domains x 8 services = 64 services -- enough to exceed a limit=50 page
# and exercise keyset pagination's next_cursor.
DOMAINS="payments orders users catalog notifications search shipping auth"
SUFFIXES="api webhook internal public legacy v2 gateway worker"

seeded=0
routed=0
backdated=0

i=0
for domain in $DOMAINS; do
  j=0
  for suffix in $SUFFIXES; do
    name="${domain}-${suffix}"

    tags="-d tags[]=m1-fixture -d tags[]=${domain}"
    # every domain's index 0/3/6 gets a lifecycle tag so tags= / tags_any=
    # have more than one dimension to filter on, on top of the domain tag.
    case $((j % 4)) in
      0) tags="$tags -d tags[]=core" ;;
      1) tags="$tags -d tags[]=beta" ;;
      2) tags="$tags -d tags[]=internal" ;;
      3) tags="$tags -d tags[]=core -d tags[]=beta" ;;
    esac
    if [ "$domain" = "payments" ]; then
      tags="$tags -d tags[]=payment"
    fi

    is_old=0
    if [ $((j % 3)) -eq 0 ]; then
      is_old=1
      tags="$tags -d tags[]=m1-fixture-old"
    fi

    if ! exists "/services/$name"; then
      echo "creating service: $name"
      eval curl -sf -X POST "$ADMIN/services" \
        -d "name=$name" \
        -d "url=http://backend.internal/$domain/$suffix" \
        $tags > /dev/null
      seeded=$((seeded + 1))
    fi

    # every even index within a domain gets a route; the rest stay routeless
    # -- this is the exact fork M1's pass criteria checks ("propose adding
    # tag deprecated to whichever [payment-tagged service] has no route").
    if [ $((j % 2)) -eq 0 ]; then
      route_name="${name}-route"
      if ! exists "/routes/$route_name"; then
        echo "  + route: $route_name (/$domain/$suffix)"
        curl -sf -X POST "$ADMIN/services/$name/routes" \
          -d "name=$route_name" -d "paths[]=/$domain/$suffix" \
          -d "tags[]=m1-fixture" > /dev/null
        routed=$((routed + 1))
      fi
    fi

    # backdate the m1-fixture-old subset directly in Kong's Postgres --
    # the Admin API does not accept created_at/updated_at on create, and
    # this is what lets updated_after=<7 days ago> actually exclude rows.
    if [ "$is_old" = "1" ]; then
      days_ago=$((10 + j * 2))
      docker compose exec -T kong-database psql -U kong -d kong -q -c \
        "UPDATE services SET created_at = now() - interval '${days_ago} days', updated_at = now() - interval '${days_ago} days' WHERE name = '${name}';" \
        > /dev/null
      backdated=$((backdated + 1))
    fi

    j=$((j + 1))
  done
  i=$((i + 1))
done

echo
echo "m1 fixtures seeded."
echo "  services created this run: $seeded (64 total across $DOMAINS)"
echo "  routes created this run:   $routed"
echo "  backdated (>7 days old):   $backdated"
echo
echo "  all fixtures tagged:  tags=m1-fixture"
echo "  payment-tagged:       tags=payment  (payments-* services only)"
echo "  routeless subset:     odd suffix index per domain (webhook, public, v2, worker)"
echo "  tear down with:       docker/kong/teardown_m1_fixtures.sh"
