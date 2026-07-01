#!/usr/bin/env bash
# End-to-end demo for the monorepo: boot the todo_server, then run the mob client
# demo (headless) against it, then tear the server down.
set -euo pipefail

cd "$(dirname "$0")"
export HEX_OFFLINE=1
PORT="${PORT:-4999}"
export TODO_SERVER_URL="http://127.0.0.1:${PORT}"

echo "▶ starting todo_server on :${PORT}"
( cd todo_server && PORT="$PORT" mix run --no-halt >/tmp/todo_server.log 2>&1 ) &
SERVER_PID=$!

cleanup() {
  echo "▶ stopping todo_server"
  kill "$SERVER_PID" 2>/dev/null || true
  pkill -f "todo_server.*--no-halt" 2>/dev/null || true
}
trap cleanup EXIT

echo "▶ waiting for server health"
for _ in $(seq 1 60); do
  if curl -sf "${TODO_SERVER_URL}/health" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -sf "${TODO_SERVER_URL}/health" >/dev/null || { echo "server did not start"; cat /tmp/todo_server.log; exit 1; }

echo "▶ running mob client demo"
( cd todo_mob && mix run -e "TodoMob.Demo.run()" )
