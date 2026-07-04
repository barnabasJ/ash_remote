#!/usr/bin/env bash
# Launch the whole demo: the todo_server backend, then TWO LiveView clients
# signed in as different users — so the realtime + per-user filtering story is
# visible end to end.
#
#   Ada   → http://localhost:4001  (ada@example.com)
#   Grace → http://localhost:4002  (grace@example.com)
#
# Open both. Each sees only their own private todos, but a PUBLIC todo created in
# either page appears live in both. Ctrl-C stops everything.
set -euo pipefail

cd "$(dirname "$0")"
SERVER_PORT="${SERVER_PORT:-4010}"
ADA_PORT="${ADA_PORT:-4001}"
GRACE_PORT="${GRACE_PORT:-4002}"
export TODO_SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

# Compile up front (the first run compiles ash and friends — can take a minute).
# Doing it here, in the foreground, means the health check below isn't racing
# a multi-minute compile. Only hit the Hex registry when deps are actually
# missing/out of sync — the network here is unreliable, and an already-fetched
# demo shouldn't die on a registry timeout.
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
echo "  Try: add a PUBLIC todo in one page → it appears live in the other."
echo "       add a private todo → only its owner sees it."
echo

# Grace's client runs in the foreground so Ctrl-C tears the whole demo down.
( cd todo_client && WEB_PORT="$GRACE_PORT" TODO_EMAIL="grace@example.com" mix run --no-halt )
