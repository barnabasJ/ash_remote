#!/usr/bin/env bash
# Launch the whole demo: the todo_server backend, then TWO LiveView clients
# signed in as different users — so both the realtime cross-client sync AND
# the ash_multi_datalayer cache metrics are visible end to end.
#
#   Ada   → http://localhost:4001  (ada@example.com)
#   Grace → http://localhost:4002  (grace@example.com)
#
# Open both. Each sees only their own private todos, but a PUBLIC todo created
# in either page appears live in both — and only the affected coverage entry
# on the OTHER page takes a cache miss, visible on its sticky stats bar.
# Ctrl-C stops everything.
set -euo pipefail

cd "$(dirname "$0")"
SERVER_PORT="${SERVER_PORT:-4010}"
ADA_PORT="${ADA_PORT:-4001}"
GRACE_PORT="${GRACE_PORT:-4002}"
export TODO_SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

echo "▶ fetching + compiling deps (first run can take a minute)…"
for app in todo_server todo_client; do
  ( cd "$app" && mix deps.loadpaths --no-compile >/dev/null 2>&1 || mix deps.get >/dev/null )
  ( cd "$app" && mix compile )
done

echo "▶ starting todo_server on :${SERVER_PORT}  (log: /tmp/todo_server.log)"
( cd todo_server && PORT="$SERVER_PORT" mix run --no-halt >/tmp/todo_server.log 2>&1 ) &
SERVER_PID=$!

cleanup() {
  echo
  echo "▶ stopping demo"
  kill "$SERVER_PID" "${ADA_PID:-}" 2>/dev/null || true
  pkill -f "todo_server.*--no-halt" 2>/dev/null || true
  pkill -f "todo_client.*--no-halt" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ waiting for backend health…"
for _ in $(seq 1 120); do
  curl -sf "${TODO_SERVER_URL}/health" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -sf "${TODO_SERVER_URL}/health" >/dev/null 2>&1; then
  echo "backend did not become healthy — last log lines:"
  tail -20 /tmp/todo_server.log
  exit 1
fi

echo "▶ starting Ada's client on :${ADA_PORT}  (log: /tmp/todo_client_ada.log)"
( cd todo_client && WEB_PORT="$ADA_PORT" TODO_EMAIL="ada@example.com" \
    mix run --no-halt >/tmp/todo_client_ada.log 2>&1 ) &
ADA_PID=$!

echo
echo "  Ada   → http://localhost:${ADA_PORT}"
echo "  Grace → http://localhost:${GRACE_PORT}   (starting in the foreground; Ctrl-C to stop all)"
echo
echo "  Try: warm a Browse filter on one page (misses+backfills, then hits on repeat)."
echo "       change a todo the other user can see → watch only the affected filter"
echo "       take a miss on their sticky cache bar, everything else stays a hit."
echo

# Grace's client runs in the foreground so Ctrl-C tears the whole demo down.
( cd todo_client && WEB_PORT="$GRACE_PORT" TODO_EMAIL="grace@example.com" mix run --no-halt )
