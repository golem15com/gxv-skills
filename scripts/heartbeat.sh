#!/usr/bin/env bash
# GXV Heartbeat — keeps agent session alive and polls for messages/presence
#
# Usage: heartbeat.sh <session-file> [interval-seconds]
#
# Reads session_token, agent_name, project_slug, and server_url from the
# session JSON file. Requires GXV_API_KEY environment variable.
# Writes PID to .gxv/heartbeat-<SID>.pid (per-session, alongside session file).
#
# Each cycle:
#   1. Sends heartbeat POST to keep session alive
#   2. Polls GET /messages for new messages since last poll
#   3. Polls GET /presence and writes .gxv/presence-<SID>.json
#
# Exits automatically when:
#   - Session file is deleted (agent checked out)
#   - Server returns 404/401 (session expired/invalid)

set -euo pipefail

SESSION_FILE="${1:?Usage: heartbeat.sh <session-file> [interval-seconds]}"
INTERVAL="${2:-30}"

# Resolve to absolute path
SESSION_FILE="$(cd "$(dirname "$SESSION_FILE")" && pwd)/$(basename "$SESSION_FILE")"
GXV_DIR="$(dirname "$SESSION_FILE")"

# Extract session ID from filename (e.g., session-1181675.json → 1181675)
SESSION_BASENAME="$(basename "$SESSION_FILE" .json)"
SID="${SESSION_BASENAME#session-}"
PIDFILE="$GXV_DIR/heartbeat-${SID}.pid"
INBOX_FILE="$GXV_DIR/inbox-${SID}.json"
PRESENCE_FILE="$GXV_DIR/presence-${SID}.json"

# Validate
if [ ! -f "$SESSION_FILE" ]; then
  echo "Session file not found: $SESSION_FILE" >&2
  exit 1
fi

API_KEY="${GXV_API_KEY:?GXV_API_KEY environment variable is required}"

# Parse session fields
TOKEN=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['session_token'])")
SERVER=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['server_url'])")
AGENT_NAME=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['agent_name'])")
PROJECT_SLUG=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['project_slug'])")

# Write PID file
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Initialize last_polled_at from existing inbox file, or empty
LAST_POLLED=""
if [ -f "$INBOX_FILE" ]; then
  LAST_POLLED=$(python3 -c "
import json, sys
try:
    data = json.load(open('$INBOX_FILE'))
    print(data.get('last_polled_at', ''))
except: pass
" 2>/dev/null) || true
fi

# Heartbeat + message poll loop
while true; do
  # Exit if session file was deleted (checkout)
  [ -f "$SESSION_FILE" ] || break

  # --- 1. Send heartbeat ---
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -X POST "$SERVER/_gxv/api/v1/heartbeat" \
    -d "{\"session_token\":\"$TOKEN\"}" 2>/dev/null) || true

  # Exit if session is gone server-side
  if [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "401" ]; then
    break
  fi

  # --- 2. Poll for messages ---
  MESSAGES_URL="$SERVER/_gxv/api/v1/messages?project_slug=$PROJECT_SLUG&limit=20"
  if [ -n "$LAST_POLLED" ]; then
    MESSAGES_URL="${MESSAGES_URL}&since=${LAST_POLLED}"
  fi

  MSG_RESPONSE=$(curl -sf \
    -H "X-API-Key: $API_KEY" \
    "$MESSAGES_URL" 2>/dev/null) || true

  if [ -n "$MSG_RESPONSE" ]; then
    # Update inbox file atomically via python (pipe response via stdin to avoid quoting issues)
    POLL_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$MSG_RESPONSE" | python3 -c "
import json, sys, os

response = sys.stdin.read()
poll_ts = sys.argv[1]
agent_name = sys.argv[2]
inbox_file = sys.argv[3]
tmp_file = inbox_file + '.tmp'

try:
    new_msgs = json.loads(response).get('data', [])
except (json.JSONDecodeError, KeyError):
    sys.exit(0)

# Filter out own messages
new_msgs = [m for m in new_msgs if m.get('sender', '') != agent_name]

# Filter out DMs between other agents — keep only broadcasts and DMs to this agent
new_msgs = [m for m in new_msgs
    if m.get('recipient', 'broadcast') == 'broadcast'
    or m.get('recipient_type', '') == 'broadcast'
    or m.get('recipient', '') == agent_name
    or m.get('recipient_name', '') == agent_name]

# Load existing inbox
existing = {'last_polled_at': '', 'last_seen_at': '', 'agent_name': agent_name, 'messages': []}
if os.path.exists(inbox_file):
    try:
        with open(inbox_file) as f:
            existing = json.load(f)
    except: pass

# Merge: add new messages, deduplicate by id
existing_ids = {m.get('id') for m in existing.get('messages', [])}
for m in new_msgs:
    if m.get('id') not in existing_ids:
        existing['messages'].append(m)
        existing_ids.add(m.get('id'))

# Cap at 50 messages (keep newest)
existing['messages'] = sorted(existing['messages'], key=lambda m: m.get('created_at', ''))[-50:]

existing['last_polled_at'] = poll_ts
existing['agent_name'] = agent_name

# Atomic write
with open(tmp_file, 'w') as f:
    json.dump(existing, f, indent=2)
os.replace(tmp_file, inbox_file)
" "$POLL_TS" "$AGENT_NAME" "$INBOX_FILE" 2>/dev/null || true

    LAST_POLLED="$POLL_TS"
  fi

  # --- 3. Poll presence and cache locally ---
  PRESENCE_RESPONSE=$(curl -sf \
    -H "X-API-Key: $API_KEY" \
    "$SERVER/_gxv/api/v1/presence?project_slug=$PROJECT_SLUG" 2>/dev/null) || true

  if [ -n "$PRESENCE_RESPONSE" ]; then
    PRESENCE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "$PRESENCE_RESPONSE" | python3 -c "
import json, sys, os

response = sys.stdin.read()
poll_ts = sys.argv[1]
agent_name = sys.argv[2]
presence_file = sys.argv[3]
tmp_file = presence_file + '.tmp'

try:
    agents = json.loads(response).get('data', [])
except (json.JSONDecodeError, KeyError):
    sys.exit(0)

# Build compact presence cache
cache = {
    'last_polled_at': poll_ts,
    'self': agent_name,
    'agents': []
}

for a in agents:
    cache['agents'].append({
        'agent_name': a.get('agent_name', ''),
        'declared_area': a.get('declared_area', ''),
        'declared_files': a.get('declared_files') or [],
        'started_at': a.get('started_at', ''),
    })

# Atomic write
with open(tmp_file, 'w') as f:
    json.dump(cache, f, indent=2)
os.replace(tmp_file, presence_file)
" "$PRESENCE_TS" "$AGENT_NAME" "$PRESENCE_FILE" 2>/dev/null || true
  fi

  sleep "$INTERVAL"
done
