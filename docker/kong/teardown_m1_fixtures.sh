#!/bin/sh
# Removes everything seed_m1_fixtures.sh created, by tag -- never touches
# admin-api / admin-api-rw / admin-api-ro or the kong-admin-path consumers,
# since none of those carry the m1-fixture tag.
set -e

ADMIN=http://127.0.0.1:8001

echo "removing m1-fixture routes and services ..."
count=0
for id in $(curl -sf "$ADMIN/services?tags=m1-fixture&size=200" | jq -r '.data[].id'); do
  # drop each service's routes first, then the service itself.
  for route_id in $(curl -sf "$ADMIN/services/$id/routes" | jq -r '.data[].id'); do
    curl -sf -X DELETE "$ADMIN/routes/$route_id" > /dev/null
  done
  curl -sf -X DELETE "$ADMIN/services/$id" > /dev/null
  count=$((count + 1))
done

echo "removed $count m1-fixture services (and their routes)."
