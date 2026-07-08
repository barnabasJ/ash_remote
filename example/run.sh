#!/usr/bin/env bash
# The whole demo: the todo_server backend, then TWO todo_client instances
# (separate BEAM VMs, separate SQLite files) signed in as different users.
# Each client serves BOTH pages — visit either or both per instance:
#
#   /           the ProvenCoverage ETS-cache demo (cross-client cache
#               invalidation, hit/miss/backfill telemetry)
#   /offline    the LocalOutbox demo (offline queueing, stale-check
#               conflicts, three-way resolution UI)
#
#   Ada   → http://localhost:4002[/offline]   (ada@example.com,   priv/client_a.db)
#   Grace → http://localhost:4003[/offline]   (grace@example.com, priv/client_b.db)
#
# Online-cache walkthrough (`/`): warm a Browse filter on one page (miss+
# backfill, then hits on repeat); edit a todo the other user can see and
# watch only the affected filter take a miss on their page, everything else
# stays a hit; a public todo created on either page appears live on both.
#
# Offline walkthrough (`/offline`): add a PUBLIC todo on Ada → it flushes to
# the server and Grace hydrates it. Hit "Go offline" on BOTH. Edit the same
# todo differently on each. "Go online" on Ada (its edit flushes and wins),
# then on Grace — Grace's flush stale-checks, sees the server moved, and
# PARKS the entry as a conflict. Resolve it in Grace's Conflicts panel (Keep
# mine / Take theirs / Retry). The `/oban` page shows the outbox flush jobs
# draining.
#
# Ctrl-C stops everything.
set -euo pipefail

cd "$(dirname "$0")"
SERVER_PORT="${SERVER_PORT:-4010}"
ADA_PORT="${ADA_PORT:-4002}"
GRACE_PORT="${GRACE_PORT:-4003}"
export TODO_SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

echo "▶ compiling…"
for app in todo_server todo_client; do
  ( cd "$app" && (mix deps.loadpaths --no-compile >/dev/null 2>&1 || mix deps.get >/dev/null) )
  ( cd "$app" && mix compile )
done

# Fresh local state each run: two isolated SQLite files (+ wal/shm sidecars).
echo "▶ clearing stale client DBs"
rm -f todo_client/priv/client_a.db* todo_client/priv/client_b.db*
mkdir -p todo_client/priv

echo "▶ starting todo_server on :${SERVER_PORT}  (log: /tmp/todo_server.log)"
( cd todo_server && PORT="$SERVER_PORT" mix run --no-halt >/tmp/todo_server.log 2>&1 ) &
SERVER_PID=$!

cleanup() {
  echo; echo "▶ stopping demo"
  kill "$SERVER_PID" "${ADA_PID:-}" 2>/dev/null || true
  pkill -f "todo_server.*--no-halt" 2>/dev/null || true
  pkill -f "todo_client.*--no-halt" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ waiting for backend…"
for _ in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${TODO_SERVER_URL}/auth/sign-in" \
    -H 'content-type: application/json' \
    -d '{"email":"ada@example.com","password":"password123"}' 2>/dev/null || echo 000)
  [ "$code" = "200" ] && break
  sleep 0.5
done
if [ "${code:-000}" != "200" ]; then
  echo "backend did not become healthy — last log lines:"; tail -20 /tmp/todo_server.log; exit 1
fi

echo "▶ starting Ada's client on :${ADA_PORT}  (log: /tmp/todo_client_ada.log)"
( cd todo_client && WEB_PORT="$ADA_PORT" TODO_EMAIL="ada@example.com" TODO_DB_PATH="priv/client_a.db" \
    mix run --no-halt >/tmp/todo_client_ada.log 2>&1 ) &
ADA_PID=$!

echo
echo "  Ada   → http://localhost:${ADA_PORT}    (or ${ADA_PORT}/offline)"
echo "  Grace → http://localhost:${GRACE_PORT}    (or ${GRACE_PORT}/offline)   (foreground; Ctrl-C stops all)"
echo

# Grace's client runs in the foreground so Ctrl-C tears the whole demo down.
( cd todo_client && WEB_PORT="$GRACE_PORT" TODO_EMAIL="grace@example.com" TODO_DB_PATH="priv/client_b.db" \
    mix run --no-halt )
