#!/usr/bin/env bash
# GXV Heartbeat — keeps agent session alive by sending periodic heartbeats
#
# Usage: heartbeat.sh <session-file> [interval-seconds]
#
# Reads session_token and server_url from the session JSON file.
# Requires GXV_API_KEY environment variable.
# Writes PID to .gxv/heartbeat.pid (alongside session file).
#
# Exits automatically when:
#   - Session file is deleted (agent checked out)
#   - Server returns 404/401 (session expired/invalid)

set -euo pipefail

SESSION_FILE="${1:?Usage: heartbeat.sh <session-file> [interval-seconds]}"
INTERVAL="${2:-30}"

# Resolve to absolute path
SESSION_FILE="$(cd "$(dirname "$SESSION_FILE")" && pwd)/$(basename "$SESSION_FILE")"
PIDFILE="$(dirname "$SESSION_FILE")/heartbeat.pid"

# Validate
if [ ! -f "$SESSION_FILE" ]; then
  echo "Session file not found: $SESSION_FILE" >&2
  exit 1
fi

API_KEY="${GXV_API_KEY:?GXV_API_KEY environment variable is required}"

# Parse session
TOKEN=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['session_token'])")
SERVER=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['server_url'])")

# Write PID file
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Heartbeat loop
while true; do
  # Exit if session file was deleted (checkout)
  [ -f "$SESSION_FILE" ] || break

  # Send heartbeat
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -X POST "$SERVER/_gxv/api/v1/heartbeat" \
    -d "{\"session_token\":\"$TOKEN\"}" 2>/dev/null) || true

  # Exit if session is gone server-side
  [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "401" ] && break

  sleep "$INTERVAL"
done
