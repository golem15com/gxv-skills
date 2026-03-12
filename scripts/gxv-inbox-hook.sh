#!/usr/bin/env bash
# GXV Inbox Hook — injects scope awareness and unread messages into context
#
# Designed for Claude Code UserPromptSubmit hook.
# - NO network calls — reads only local .gxv/ files
# - Fast-path exit when no .gxv/ dir
# - Outputs plain text to stdout (injected into Claude context)
# - Line 1: [GXV] Scopes summary (always, when presence cache available)
# - Line 2+: Unread messages (only when new messages exist)
# - Updates last_seen_at after message delivery
#
# Uses $CLAUDE_PROJECT_DIR to find .gxv/ directory.

set -euo pipefail

# Determine project directory
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
GXV_DIR="$PROJECT_DIR/.gxv"

# Fast-path: no .gxv directory → nothing to do
[ -d "$GXV_DIR" ] || exit 0

OUTPUT=""

# ── 1. Scope summary from presence cache ──────────────────────────
# Find most recently modified presence file
PRESENCE_FILE=""
NEWEST_MTIME=0
SELF_AGENT=""

for f in "$GXV_DIR"/presence-*.json; do
  [ -f "$f" ] || continue
  # Use stat to get mtime (portable across Linux/Alpine)
  MTIME=$(stat -c %Y "$f" 2>/dev/null) || continue
  if [ "$MTIME" -gt "$NEWEST_MTIME" ]; then
    NEWEST_MTIME="$MTIME"
    PRESENCE_FILE="$f"
  fi
done

if [ -n "$PRESENCE_FILE" ]; then
  # Check staleness and extract scope info with jq
  SCOPE_LINE=$(jq -r '
    def age_ok:
      (.last_polled_at // "") as $ts |
      if $ts == "" then false
      else
        ($ts | sub("Z$"; "+00:00") | try fromdateiso8601 catch 0) as $polled |
        if $polled == 0 then false
        else (now - $polled) < 120
        end
      end;

    if age_ok then
      .self as $self |
      [.agents[] |
        .agent_name as $name |
        .declared_area as $area |
        if $name == $self then "\($name)(YOU)->\($area // "(none)")"
        else "\($name)->\($area // "(none)")"
        end
      ] | if length > 0 then "[GXV] Scopes: \(join(", "))" else "" end
    else ""
    end
  ' "$PRESENCE_FILE" 2>/dev/null) || true

  SELF_AGENT=$(jq -r '.self // ""' "$PRESENCE_FILE" 2>/dev/null) || true

  if [ -n "$SCOPE_LINE" ]; then
    OUTPUT="$SCOPE_LINE"
  fi
fi

# ── 2. Unread messages from inbox files ───────────────────────────
UNREAD_OUTPUT=""
for INBOX_FILE in "$GXV_DIR"/inbox-*.json; do
  [ -f "$INBOX_FILE" ] || continue

  # Extract unread messages and format them, also get the agent_name
  RESULT=$(jq -r --arg self_agent "$SELF_AGENT" '
    (.agent_name // "") as $file_agent |
    (if $self_agent != "" then $self_agent elif $file_agent != "" then $file_agent else "" end) as $agent |
    (.last_seen_at // "") as $last_seen |

    # Filter messages: only broadcasts and DMs to/from this agent
    [.messages // [] | .[] |
      select(
        ($agent == "") or
        (.recipient // "broadcast") == "broadcast" or
        (.recipient_type // "") == "broadcast" or
        (.recipient // "") == $agent or
        (.recipient_name // "") == $agent or
        (.sender // "") == $agent
      ) |
      select($last_seen == "" or (.created_at // "") > $last_seen)
    ] |
    sort_by(.created_at // "") |

    if length > 0 then
      . as $msgs |
      (["\(length)"] +
       [$msgs[] |
        (.created_at // "") as $created |
        (if ($created | length) >= 16 then $created[11:16] else "??:??" end) as $time |
        (.sender // "unknown") as $sender |
        (.recipient // "broadcast") as $recipient |
        (.content // "") as $content |
        if $recipient == "broadcast" or $recipient == "" then
          "  [\($time)] \($sender) (broadcast): \($content)"
        elif $agent != "" and ($recipient == $agent or (.recipient_name // "") == $agent) then
          "  [\($time)] \($sender) -> YOU: \($content)"
        else
          "  [\($time)] \($sender) -> \($recipient): \($content)"
        end
       ]) | join("\n")
    else ""
    end
  ' "$INBOX_FILE" 2>/dev/null) || true

  if [ -n "$RESULT" ]; then
    # First line is the count, rest are formatted messages
    COUNT=$(echo "$RESULT" | head -1)
    MSGS=$(echo "$RESULT" | tail -n +2)

    if [ -n "$MSGS" ]; then
      UNREAD_OUTPUT="${UNREAD_OUTPUT}[GolemXV] ${COUNT} new message(s):\n\n${MSGS}\n\nReply: /gxv:msg \"your reply\" | DM: /gxv:msg --to agent-name \"message\""

      # Update last_seen_at to now
      NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      jq --arg now "$NOW" '.last_seen_at = $now' "$INBOX_FILE" > "${INBOX_FILE}.tmp" 2>/dev/null \
        && mv "${INBOX_FILE}.tmp" "$INBOX_FILE" || true
    fi
  fi
done

# ── Output ────────────────────────────────────────────────────────
if [ -n "$OUTPUT" ] && [ -n "$UNREAD_OUTPUT" ]; then
  echo "$OUTPUT"
  echo -e "$UNREAD_OUTPUT"
elif [ -n "$OUTPUT" ]; then
  echo "$OUTPUT"
elif [ -n "$UNREAD_OUTPUT" ]; then
  echo -e "$UNREAD_OUTPUT"
fi
