#!/usr/bin/env bash
# Block direct MCP tool calls to GolemXV -- agents must use /gxv: skills
#
# This hook fires on PreToolUse for any tool matching mcp__golemxv__.*
# Returns a deny decision directing the agent to use skills instead.

# Read stdin (hook input JSON) -- we don't need to parse it, just deny
cat > /dev/null

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Direct MCP calls to GolemXV are blocked. Use /gxv: skills instead:\n- /gxv:msg \"message\" -- send messages\n- /gxv:msg --to agent-name \"message\" -- direct message\n- /gxv:status -- coordination status\n- /gxv:tasks -- list tasks\n- /gxv:claim task-id -- claim a task\n- /gxv:scope area files... -- declare work scope\n- /gxv:done -- check out\nSkills handle session loading, heartbeats, and error recovery automatically."
  }
}
JSON
