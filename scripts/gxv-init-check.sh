#!/usr/bin/env bash
# gxv-init-check.sh -- Single-pass environment validation for /gxv:init
#
# Usage: gxv-init-check.sh <project-dir> <server-url>
#
# Environment variables:
#   GXV_API_KEY   (required) -- GolemXV API key
#   GXV_MCP_URL   (optional) -- Override MCP URL for .mcp.json
#
# Outputs structured JSON to stdout. Errors go to stderr.
# Exit 0 = success (status: "ok"), Exit 1 = error (status: "error")

set -euo pipefail

export PROJECT_DIR="${1:?Usage: gxv-init-check.sh <project-dir> <server-url>}"
export SERVER_URL="${2:?Usage: gxv-init-check.sh <project-dir> <server-url>}"

# Remove trailing slash from server URL
SERVER_URL="${SERVER_URL%/}"

# ── 1. Capture PPID ──────────────────────────────────────────────────
# $PPID is the parent of this script process = the Bash tool process = Claude Code process.
STABLE_PPID="$PPID"

# ── 1b. Early exit for spawned containers ──────────────────────────────
# Spawned agents already have a session managed by the spawner process.
# Running init would create a duplicate phantom session via checkin.
if [ -n "${GXV_SESSION_TOKEN:-}" ]; then
  TOKEN_PREFIX="${GXV_SESSION_TOKEN:0:8}"
  jq -n \
    --arg tp "$TOKEN_PREFIX" \
    --arg slug "${GXV_PROJECT_SLUG:-}" \
    '{
      status: "spawned",
      message: "Session managed by spawner — no checkin needed",
      token_prefix: $tp,
      project_slug: (if $slug == "" then null else $slug end)
    }'
  exit 0
fi

# ── 2. Validate GXV_API_KEY ──────────────────────────────────────────
if [ -z "${GXV_API_KEY:-}" ]; then
  jq -n '{"status": "error", "error": "GXV_API_KEY not set"}'
  exit 1
fi

API_KEY_PREFIX="${GXV_API_KEY:0:8}"

# ── 3. Create .gxv/ directory ─────────────────────────────────────────
mkdir -p "$PROJECT_DIR/.gxv"

MCP_URL="${GXV_MCP_URL:-${SERVER_URL}/mcp}"
GXV_DIR="$PROJECT_DIR/.gxv"
SESSION_FILE="$GXV_DIR/session-${STABLE_PPID}.json"

# ── Initialize result JSON ────────────────────────────────────────────
# We'll build the result incrementally using a temp file
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT

jq -n \
  --arg ppid "$STABLE_PPID" \
  --arg api_prefix "$API_KEY_PREFIX" \
  --arg server_url "$SERVER_URL" \
  --arg mcp_url "$MCP_URL" \
  --arg session_file ".gxv/session-${STABLE_PPID}.json" \
'{
  status: "ok",
  ppid: ($ppid | tonumber),
  env: {
    api_key_set: true,
    api_key_prefix: $api_prefix,
    server_url: $server_url,
    mcp_url: $mcp_url
  },
  session: {
    exists: false,
    valid: false,
    file: $session_file,
    agent_name: null,
    stale_cleaned: 0
  },
  project: {
    slug: null,
    name: null,
    needs_fetch: false
  },
  gitignore: {
    updated: false
  },
  mcp_json: {
    existed: false,
    has_golemxv: false,
    created: false,
    updated: false
  },
  heartbeat_script: null,
  presence: {
    active_agents: []
  }
}' > "$RESULT_FILE"

# ── 4. Check for existing session file ───────────────────────────────
SESSION_DATA=""
SESSION_AGENT=""

if [ -f "$SESSION_FILE" ]; then
  SESSION_DATA=$(cat "$SESSION_FILE" 2>/dev/null) || true
  if [ -n "$SESSION_DATA" ] && echo "$SESSION_DATA" | jq empty 2>/dev/null; then
    SESSION_AGENT=$(echo "$SESSION_DATA" | jq -r '.agent_name // ""')
    jq '.session.exists = true | .session.agent_name = "'"$SESSION_AGENT"'"' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
      && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  else
    # Corrupt session file — remove it
    echo "Warning: Could not parse session file" >&2
    rm -f "$SESSION_FILE"
    SESSION_DATA=""
  fi
fi

# ── 5. Call presence API ──────────────────────────────────────────────
PRESENCE_RESPONSE=$(curl -sf -H "X-API-Key: ${GXV_API_KEY}" \
  --max-time 10 --connect-timeout 5 \
  "${SERVER_URL}/_gxv/api/v1/presence" 2>/dev/null) || true

ACTIVE_AGENTS='[]'
ACTIVE_NAMES=""
if [ -n "$PRESENCE_RESPONSE" ] && echo "$PRESENCE_RESPONSE" | jq empty 2>/dev/null; then
  ACTIVE_AGENTS=$(echo "$PRESENCE_RESPONSE" | jq '.data // []')
  ACTIVE_NAMES=$(echo "$ACTIVE_AGENTS" | jq -r '.[].agent_name // empty' | sort -u)
  jq --argjson agents "$ACTIVE_AGENTS" '.presence.active_agents = $agents' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# ── 6. Validate existing session ─────────────────────────────────────
if [ -n "$SESSION_DATA" ] && [ -n "$SESSION_AGENT" ]; then
  # Check if our agent name is in the active list
  if echo "$ACTIVE_NAMES" | grep -qxF "$SESSION_AGENT" 2>/dev/null; then
    TOKEN_PREFIX=$(echo "$SESSION_DATA" | jq -r '.session_token // "" | .[0:8]')
    SESSION_ID=$(echo "$SESSION_DATA" | jq -r '.session_id // null')
    jq --arg tp "$TOKEN_PREFIX" --arg sid "$SESSION_ID" \
      '.session.valid = true | .session.token_prefix = $tp | .session.session_id = ($sid | if . == "null" then null else . end)' \
      "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
      && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  else
    # Session is stale — agent not in active list
    jq '.session.valid = false | .session.exists = false' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
      && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    rm -f "$SESSION_FILE"
    rm -f "$GXV_DIR/inbox-${STABLE_PPID}.json"
    rm -f "$GXV_DIR/presence-${STABLE_PPID}.json"
    SESSION_DATA=""
    SESSION_AGENT=""
  fi
fi

# ── 7. Clean stale sessions ──────────────────────────────────────────
STALE_CLEANED=0
for OTHER_SESSION in "$GXV_DIR"/session-*.json; do
  [ -f "$OTHER_SESSION" ] || continue
  # Skip our own session
  [ "$OTHER_SESSION" = "$SESSION_FILE" ] && continue

  OTHER_AGENT=$(jq -r '.agent_name // ""' "$OTHER_SESSION" 2>/dev/null) || true
  if [ -z "$OTHER_AGENT" ] || ! echo "$ACTIVE_NAMES" | grep -qxF "$OTHER_AGENT" 2>/dev/null; then
    rm -f "$OTHER_SESSION"

    # Extract the SID from filename
    OTHER_BASENAME="$(basename "$OTHER_SESSION" .json)"
    OTHER_SID="${OTHER_BASENAME#session-}"

    # Kill heartbeat process if PID file exists
    HPID_FILE="$GXV_DIR/heartbeat-${OTHER_SID}.pid"
    if [ -f "$HPID_FILE" ]; then
      HPID=$(cat "$HPID_FILE" 2>/dev/null) || true
      if [ -n "$HPID" ]; then
        kill "$HPID" 2>/dev/null || true
      fi
      rm -f "$HPID_FILE"
    fi

    # Remove associated files
    rm -f "$GXV_DIR/inbox-${OTHER_SID}.json"
    rm -f "$GXV_DIR/presence-${OTHER_SID}.json"
    rm -f "$GXV_DIR/heartbeat-${OTHER_SID}.log"

    STALE_CLEANED=$((STALE_CLEANED + 1))
    echo "Cleaned stale session: $(basename "$OTHER_SESSION") (agent ${OTHER_AGENT})" >&2
  fi
done

if [ "$STALE_CLEANED" -gt 0 ]; then
  jq --argjson count "$STALE_CLEANED" '.session.stale_cleaned = $count' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# ── 8. Check GOLEM.yaml ──────────────────────────────────────────────
GOLEM_YAML="$PROJECT_DIR/GOLEM.yaml"
if [ -f "$GOLEM_YAML" ]; then
  # Simple YAML parsing for project.slug and project.name
  PROJ_SLUG=""
  PROJ_NAME=""
  IN_PROJECT=false
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    if [[ "$stripped" = project:* ]]; then
      IN_PROJECT=true
      continue
    fi
    if $IN_PROJECT && [[ "$line" != " "* ]] && [[ "$line" != "	"* ]] && [ -n "$stripped" ]; then
      IN_PROJECT=false
    fi
    if $IN_PROJECT; then
      if [[ "$stripped" = slug:* ]]; then
        PROJ_SLUG="${stripped#slug:}"
        PROJ_SLUG="${PROJ_SLUG#"${PROJ_SLUG%%[![:space:]]*}"}"
        PROJ_SLUG="${PROJ_SLUG%"${PROJ_SLUG##*[![:space:]]}"}"
        PROJ_SLUG="${PROJ_SLUG//\'/}"
        PROJ_SLUG="${PROJ_SLUG//\"/}"
      elif [[ "$stripped" = name:* ]]; then
        PROJ_NAME="${stripped#name:}"
        PROJ_NAME="${PROJ_NAME#"${PROJ_NAME%%[![:space:]]*}"}"
        PROJ_NAME="${PROJ_NAME%"${PROJ_NAME##*[![:space:]]}"}"
        PROJ_NAME="${PROJ_NAME//\'/}"
        PROJ_NAME="${PROJ_NAME//\"/}"
      fi
    fi
  done < "$GOLEM_YAML"

  if [ -n "$PROJ_SLUG" ]; then
    DISPLAY_NAME="${PROJ_NAME:-$PROJ_SLUG}"
    jq --arg slug "$PROJ_SLUG" --arg name "$DISPLAY_NAME" \
      '.project.slug = $slug | .project.name = $name | .project.needs_fetch = false' \
      "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
      && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  else
    jq '.project.needs_fetch = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
      && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
  fi
else
  jq '.project.needs_fetch = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# ── 9. Check .gitignore ──────────────────────────────────────────────
GITIGNORE="$PROJECT_DIR/.gitignore"
HAS_GXV_ENTRY=false
if [ -f "$GITIGNORE" ]; then
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    if [ "$stripped" = ".gxv/" ] || [ "$stripped" = ".gxv" ]; then
      HAS_GXV_ENTRY=true
      break
    fi
  done < "$GITIGNORE"
fi

if ! $HAS_GXV_ENTRY; then
  # Ensure file ends with newline before appending
  if [ -f "$GITIGNORE" ]; then
    # Check if file ends with newline
    if [ -s "$GITIGNORE" ] && [ "$(tail -c 1 "$GITIGNORE" | wc -l)" -eq 0 ]; then
      echo "" >> "$GITIGNORE"
    fi
  fi
  echo "" >> "$GITIGNORE"
  echo "# GolemXV session directory (local, not committed)" >> "$GITIGNORE"
  echo ".gxv/" >> "$GITIGNORE"
  jq '.gitignore.updated = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# ── 10. Check .mcp.json ──────────────────────────────────────────────
MCP_JSON="$PROJECT_DIR/.mcp.json"
GOLEMXV_ENTRY=$(jq -n --arg url "$MCP_URL" '{
  type: "http",
  url: $url,
  headers: {
    "X-API-Key": "${GXV_API_KEY}"
  }
}')

if [ -f "$MCP_JSON" ]; then
  jq '.mcp_json.existed = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"

  if jq empty "$MCP_JSON" 2>/dev/null; then
    HAS_GOLEMXV=$(jq '.mcpServers.golemxv != null' "$MCP_JSON")
    if [ "$HAS_GOLEMXV" = "true" ]; then
      jq '.mcp_json.has_golemxv = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
        && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    else
      # Add golemxv entry, preserving existing servers
      jq --argjson entry "$GOLEMXV_ENTRY" \
        '.mcpServers.golemxv = $entry' "$MCP_JSON" > "${MCP_JSON}.tmp" \
        && mv "${MCP_JSON}.tmp" "$MCP_JSON"
      jq '.mcp_json.has_golemxv = true | .mcp_json.updated = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
        && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
    fi
  else
    echo "Warning: Could not parse .mcp.json" >&2
  fi
else
  # Create .mcp.json
  jq -n --argjson entry "$GOLEMXV_ENTRY" '{
    mcpServers: {
      golemxv: $entry
    }
  }' > "${MCP_JSON}.tmp" && mv "${MCP_JSON}.tmp" "$MCP_JSON"
  jq '.mcp_json.created = true | .mcp_json.has_golemxv = true' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
fi

# ── 11. Detect heartbeat script path ─────────────────────────────────
HEARTBEAT=""
CANDIDATES=()

# Check CLAUDE_PLUGIN_ROOT first
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CANDIDATES+=("${CLAUDE_PLUGIN_ROOT}/scripts/heartbeat.sh")
fi

# Plugin installation path
if [ -n "${HOME:-}" ]; then
  CANDIDATES+=("${HOME}/.claude/plugins/gxv-skills/scripts/heartbeat.sh")
fi

# Submodule path
CANDIDATES+=("${PROJECT_DIR}/gxv-skills/scripts/heartbeat.sh")

for CANDIDATE in "${CANDIDATES[@]}"; do
  if [ -f "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
    HEARTBEAT="$CANDIDATE"
    break
  fi
done

if [ -n "$HEARTBEAT" ]; then
  jq --arg hb "$HEARTBEAT" '.heartbeat_script = $hb' "$RESULT_FILE" > "${RESULT_FILE}.tmp" \
    && mv "${RESULT_FILE}.tmp" "$RESULT_FILE"
else
  echo "Warning: heartbeat.sh not found. Checked: ${CANDIDATES[*]}" >&2
fi

# ── Output ────────────────────────────────────────────────────────────
cat "$RESULT_FILE"
