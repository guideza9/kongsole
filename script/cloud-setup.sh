#!/usr/bin/env bash
# Prepares a Claude Code cloud session (claude.ai/code) so rspec and the MCP
# vitest suite run straight away. Wired as a SessionStart hook in
# .claude/settings.json; it exits immediately anywhere CLAUDE_CODE_REMOTE is
# not "true", so local machines never run it.
#
# The cloud sandbox has no Docker, so the Kong compose stack cannot start.
# Specs stub Kong with webmock; nothing here reaches a real Kong (CLAUDE.md
# rule 7). Idempotent: safe to re-run on resume.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}"

log() { echo "[cloud-setup] $*" >&2; }

# Persist a variable for every later Bash call in this session.
persist() {
  export "$1=$2"
  [ -n "${CLAUDE_ENV_FILE:-}" ] && echo "export $1=$2" >> "$CLAUDE_ENV_FILE"
}

# --- Ruby ------------------------------------------------------------------
want_ruby=$(cat .ruby-version)
if ! ruby -v 2>/dev/null | grep -q "ruby ${want_ruby}"; then
  if command -v mise >/dev/null 2>&1; then
    log "installing ruby ${want_ruby} with mise"
    mise install "ruby@${want_ruby}"
    ruby_bin=$(mise where "ruby@${want_ruby}")/bin
  elif command -v rbenv >/dev/null 2>&1; then
    log "installing ruby ${want_ruby} with rbenv"
    rbenv install -s "${want_ruby}"
    ruby_bin=$(rbenv root)/versions/${want_ruby}/bin
  else
    log "WARNING: ruby ${want_ruby} not found and no mise/rbenv; using $(ruby -v 2>/dev/null || echo 'no ruby')"
  fi
  [ -n "${ruby_bin:-}" ] && persist PATH "${ruby_bin}:${PATH}"
fi

log "bundle install"
bundle check >/dev/null 2>&1 || bundle install --jobs 4

# --- PostgreSQL --------------------------------------------------------------
# config/database.yml expects role kongsole/kongsole on DATABASE_PORT
# (default 5433 for the local compose; the sandbox server uses its own port).
if ! pg_isready -q -h localhost 2>/dev/null; then
  log "starting postgresql"
  service postgresql start >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pg_isready -q -h localhost && break; sleep 1; done
fi

as_postgres() { su postgres -c "psql -tAc \"$1\"" ; }
pg_port=$(as_postgres "show port" | tr -d '[:space:]')
persist DATABASE_PORT "${pg_port}"

if [ "$(as_postgres "select 1 from pg_roles where rolname = 'kongsole'")" != "1" ]; then
  log "creating role kongsole"
  as_postgres "create role kongsole login superuser password 'kongsole'"
fi

log "preparing test database (port ${pg_port})"
RAILS_ENV=test bin/rails db:prepare
bin/rails tailwindcss:build >/dev/null 2>&1 || log "WARNING: tailwindcss:build failed; view specs may miss styles"

# --- MCP server ------------------------------------------------------------
if [ -f mcp/package-lock.json ]; then
  log "npm ci in mcp/"
  (cd mcp && npm ci --no-audit --no-fund)
fi

log "ready: bundle exec rspec  |  (cd mcp && npm test)"
