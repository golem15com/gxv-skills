#!/usr/bin/env bash
# GXV Scope Guard — PreToolUse hook for Edit/Write conflict detection
#
# Checks if the target file overlaps another agent's declared scope.
# NO network calls — reads local files only. Target: <50ms.
#
# Behavior:
#   - conflict_mode: "warn"    → allow (pass-through), context hook shows scopes
#   - conflict_mode: "enforce" → deny with reason + coordination suggestion
#
# Safety: allows through when:
#   - No .gxv/ directory
#   - No session file (agent not checked in)
#   - No presence cache or cache older than 2 minutes
#   - File is in own scope
#   - File doesn't match any other agent's scope
#   - GOLEM.yaml missing or conflict_mode unset (default: warn)
#
# Uses $CLAUDE_PROJECT_DIR to find .gxv/ and GOLEM.yaml.

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
GXV_DIR="$PROJECT_DIR/.gxv"

# Fast-path: no .gxv directory → not using GolemXV
[ -d "$GXV_DIR" ] || exit 0

# Extract file_path from hook input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || true
[ -n "$FILE_PATH" ] || exit 0

# Normalize to project-relative path
ABS_PROJECT=$(cd "$PROJECT_DIR" && pwd -P)
if [[ "$FILE_PATH" = /* ]]; then
  ABS_FILE=$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && echo "$(pwd -P)/$(basename "$FILE_PATH")") || exit 0
else
  ABS_FILE=$(cd "$(dirname "$ABS_PROJECT/$FILE_PATH")" 2>/dev/null && echo "$(pwd -P)/$(basename "$FILE_PATH")") || exit 0
fi

# File outside project → allow
[[ "$ABS_FILE" = "$ABS_PROJECT/"* ]] || exit 0
REL_PATH="${ABS_FILE#$ABS_PROJECT/}"

# Find own session and agent name
OWN_AGENT=""
for SF in "$GXV_DIR"/session-*.json; do
  [ -f "$SF" ] || continue
  OWN_AGENT=$(jq -r '.agent_name // ""' "$SF" 2>/dev/null) || true
  [ -n "$OWN_AGENT" ] && break
done
[ -n "$OWN_AGENT" ] || exit 0

# Find most recent presence file
PRESENCE_FILE=""
NEWEST_MTIME=0
for f in "$GXV_DIR"/presence-*.json; do
  [ -f "$f" ] || continue
  MTIME=$(stat -c %Y "$f" 2>/dev/null) || continue
  if [ "$MTIME" -gt "$NEWEST_MTIME" ]; then
    NEWEST_MTIME="$MTIME"
    PRESENCE_FILE="$f"
  fi
done
[ -n "$PRESENCE_FILE" ] || exit 0

# Check staleness and find conflicts using jq
CONFLICT_RESULT=$(jq -r --arg own_agent "$OWN_AGENT" --arg rel_path "$REL_PATH" '
  # Check staleness (>2 minutes old → allow)
  (.last_polled_at // "") as $ts |
  if $ts == "" then "ALLOW"
  else
    ($ts | sub("Z$"; "+00:00") | try fromdateiso8601 catch 0) as $polled |
    if $polled == 0 then "ALLOW"
    elif (now - $polled) > 120 then "ALLOW"
    else
      # Check for conflicts
      [.agents // [] | .[] |
        select(.agent_name != $own_agent and .agent_name != "") |
        .agent_name as $name |
        .declared_area as $area |
        (.declared_files // []) as $files |

        # Area match
        if $area != "" and ($rel_path | startswith($area + "/") or $rel_path == $area) then
          "\($name)|area: \($area)"
        else
          # Files match
          ([$files[] |
            gsub("[*]+$"; "") | gsub("/+$"; "") |
            select(. != "") |
            select($rel_path | startswith(. + "/") or $rel_path == . or startswith(.))
          ] | first // null) as $match |
          if $match != null then "\($name)|file: \($match)"
          else empty
          end
        end
      ] | if length > 0 then .[0] else "ALLOW" end
    end
  end
' "$PRESENCE_FILE" 2>/dev/null) || true

# No conflict or error → allow
[ -n "$CONFLICT_RESULT" ] && [ "$CONFLICT_RESULT" != "ALLOW" ] || exit 0

# Parse conflict result: "agent_name|reason"
CONFLICT_AGENT="${CONFLICT_RESULT%%|*}"
CONFLICT_REASON="${CONFLICT_RESULT#*|}"

# Read conflict_mode from GOLEM.yaml (default: warn)
CONFLICT_MODE="warn"
GOLEM_YAML="$PROJECT_DIR/GOLEM.yaml"
if [ -f "$GOLEM_YAML" ]; then
  # Simple YAML parsing: look for coordination.conflict_mode
  IN_COORDINATION=false
  while IFS= read -r line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    if [[ "$stripped" = coordination:* ]]; then
      IN_COORDINATION=true
      continue
    fi
    if $IN_COORDINATION && [[ "$line" != " "* ]] && [[ "$line" != "	"* ]] && [ -n "$stripped" ]; then
      IN_COORDINATION=false
    fi
    if $IN_COORDINATION && [[ "$stripped" = conflict_mode:* ]]; then
      CONFLICT_MODE="${stripped#conflict_mode:}"
      CONFLICT_MODE="${CONFLICT_MODE#"${CONFLICT_MODE%%[![:space:]]*}"}"
      CONFLICT_MODE="${CONFLICT_MODE%"${CONFLICT_MODE##*[![:space:]]}"}"
      CONFLICT_MODE="${CONFLICT_MODE//\'/}"
      CONFLICT_MODE="${CONFLICT_MODE//\"/}"
      break
    fi
  done < "$GOLEM_YAML"
fi

# Act on conflict
if [ "$CONFLICT_MODE" = "enforce" ]; then
  BASENAME=$(basename "$REL_PATH")
  REASON="SCOPE CONFLICT: ${REL_PATH} is in ${CONFLICT_AGENT}'s scope (${CONFLICT_REASON}).
Coordinate first: /gxv:msg --to ${CONFLICT_AGENT} \"Can I edit ${BASENAME}?\""

  jq -n --arg reason "$REASON" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
# warn mode (or unknown) → allow (exit 0)
