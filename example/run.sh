#!/usr/bin/env bash
# Launch the whole demo: boot the todo_server, then the LiveView client.
# Open http://localhost:4001 once it's up. Ctrl-C stops both.
set -euo pipefail

cd "$(dirname "$0")"
export HEX_OFFLINE="${HEX_OFFLINE:-1}"
SERVER_PORT="${SERVER_PORT:-4010}"
WEB_PORT="${WEB_PORT:-4001}"
export TODO_SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

# Compile up front (the first run compiles ash and friends — can take a minute).
# Doing it here, in the foreground, means the health check below isn't racing
# a multi-minute compile.
echo "▶ fetching + compiling deps (first run can take a minute)…"
( cd todo_server && mix deps.get >/dev/null && mix compile )
( cd todo_client && mix deps.get >/dev/null && mix compile )

echo "▶ starting todo_server on :${SERVER_PORT}"
( cd todo_server && PORT="$SERVER_PORT" mix run --no-halt >/tmp/todo_server.log 2>&1 ) &
SERVER_PID=$!

cleanup() {
  echo "▶ stopping todo_server"
  kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "todo_server.*--no-halt" 2>/dev/null || true
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

echo "▶ LiveView client → open http://localhost:${WEB_PORT}  (Ctrl-C to stop)"
( cd todo_client && WEB_PORT="$WEB_PORT" mix run --no-halt )
