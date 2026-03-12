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

# Parse session fields using jq
TOKEN=$(jq -r '.session_token' "$SESSION_FILE")
SERVER=$(jq -r '.server_url' "$SESSION_FILE")
AGENT_NAME=$(jq -r '.agent_name' "$SESSION_FILE")
PROJECT_SLUG=$(jq -r '.project_slug' "$SESSION_FILE")

# Write PID file
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Initialize last_polled_at from existing inbox file, or empty
LAST_POLLED=""
if [ -f "$INBOX_FILE" ]; then
  LAST_POLLED=$(jq -r '.last_polled_at // ""' "$INBOX_FILE" 2>/dev/null) || true
fi

# Heartbeat + message poll loop
while true; do
  # Exit if session file was deleted (checkout)
  [ -f "$SESSION_FILE" ] || break

  # --- 1. Send heartbeat ---
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    --max-time 10 --connect-timeout 5 \
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
    --max-time 10 --connect-timeout 5 \
    -H "X-API-Key: $API_KEY" \
    "$MESSAGES_URL" 2>/dev/null) || true

  if [ -n "$MSG_RESPONSE" ]; then
    POLL_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update inbox file atomically via jq
    EXISTING='{}'
    if [ -f "$INBOX_FILE" ]; then
      EXISTING=$(cat "$INBOX_FILE" 2>/dev/null) || EXISTING='{}'
    fi

    echo "$MSG_RESPONSE" | jq --arg poll_ts "$POLL_TS" \
      --arg agent_name "$AGENT_NAME" \
      --argjson existing "$EXISTING" '
      # Extract new messages from response
      (.data // []) as $new_msgs |

      # Filter out own messages and DMs between other agents
      [$new_msgs[] | select(
        .sender != $agent_name and (
          (.recipient // "broadcast") == "broadcast" or
          (.recipient_type // "") == "broadcast" or
          (.recipient // "") == $agent_name or
          (.recipient_name // "") == $agent_name
        )
      )] as $filtered |

      # Merge with existing messages, deduplicate by id
      ($existing.messages // []) as $old_msgs |
      ([$old_msgs[].id // empty] | map(tostring) | unique) as $existing_ids |
      [$old_msgs[], ($filtered[] | select((.id | tostring) as $id | ($existing_ids | index($id)) == null))] |
      sort_by(.created_at // "") |
      .[-50:] |

      # Build final inbox object
      {
        last_polled_at: $poll_ts,
        last_seen_at: ($existing.last_seen_at // ""),
        agent_name: $agent_name,
        messages: .
      }
    ' > "${INBOX_FILE}.tmp" 2>/dev/null && mv "${INBOX_FILE}.tmp" "$INBOX_FILE" || true

    LAST_POLLED="$POLL_TS"
  fi

  # --- 3. Poll presence and cache locally ---
  PRESENCE_RESPONSE=$(curl -sf \
    --max-time 10 --connect-timeout 5 \
    -H "X-API-Key: $API_KEY" \
    "$SERVER/_gxv/api/v1/presence?project_slug=$PROJECT_SLUG" 2>/dev/null) || true

  if [ -n "$PRESENCE_RESPONSE" ]; then
    PRESENCE_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    echo "$PRESENCE_RESPONSE" | jq --arg poll_ts "$PRESENCE_TS" \
      --arg agent_name "$AGENT_NAME" '
      {
        last_polled_at: $poll_ts,
        self: $agent_name,
        agents: [(.data // [])[] | {
          agent_name: (.agent_name // ""),
          declared_area: (.declared_area // ""),
          declared_files: (.declared_files // []),
          started_at: (.started_at // "")
        }]
      }
    ' > "${PRESENCE_FILE}.tmp" 2>/dev/null && mv "${PRESENCE_FILE}.tmp" "$PRESENCE_FILE" || true
  fi

  sleep "$INTERVAL"
done
