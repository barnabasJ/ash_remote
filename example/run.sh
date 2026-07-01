#!/usr/bin/env bash
# Launch the whole demo: boot the todo_server, then the LiveView client.
# Open http://localhost:4001 once it's up. Ctrl-C stops both.
set -euo pipefail

cd "$(dirname "$0")"
export HEX_OFFLINE=1
SERVER_PORT="${SERVER_PORT:-4010}"
WEB_PORT="${WEB_PORT:-4001}"
export TODO_SERVER_URL="http://127.0.0.1:${SERVER_PORT}"

echo "▶ starting todo_server on :${SERVER_PORT}"
( cd todo_server && PORT="$SERVER_PORT" mix run --no-halt >/tmp/todo_server.log 2>&1 ) &
SERVER_PID=$!

cleanup() {
  echo "▶ stopping todo_server"
  kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "todo_server.*--no-halt" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ waiting for server health"
for _ in $(seq 1 60); do
  curl -sf "${TODO_SERVER_URL}/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "${TODO_SERVER_URL}/health" >/dev/null || { echo "server did not start"; cat /tmp/todo_server.log; exit 1; }

echo "▶ starting LiveView client — open http://localhost:${WEB_PORT}"
( cd todo_client && mix run --no-halt -e "TodoClient.Web.start(${WEB_PORT})" )
