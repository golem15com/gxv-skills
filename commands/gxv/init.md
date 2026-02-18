---
description: Connect to GolemXV coordination server
allowed-tools: Read, Write, Bash, Glob
---

# /gxv:init

Bootstrap connection to GolemXV coordination server. This command is idempotent -- running it again re-validates the connection and shows current status.

All server communication uses curl against the REST API, so this works without MCP configured.

## IMPORTANT: Token Safety

**NEVER display raw API keys, session tokens, or full curl responses to the user.** Tokens are sensitive credentials. When you need to show a token value for confirmation, show only the first 8 characters followed by `...`. When running curl commands, capture output into a variable and parse it -- do not let raw JSON responses with tokens stream to the terminal.

For all Bash commands in this skill:
- Capture curl output: `RESPONSE=$(curl ...)`
- Parse with lightweight tools: `echo "$RESPONSE" | python3 -c "..."` or similar
- Never echo full tokens -- use `${VAR:0:8}...` for display
- If a command fails, show the HTTP status or error message, not the full response body

## Process

### Step 1: Run batch environment check (1 Bash call)

Run the batch-check script that validates the entire environment in a single pass:

```bash
RESULT=$(bash "$(pwd)/gxv-skills/scripts/gxv-init-check.sh" "$(pwd)" "${GXV_SERVER_URL:-https://golemxv.com}" 2>/dev/null)
echo "$RESULT"
```

Parse the JSON output. Handle these cases:

**If `status` is `"error"` with `error` = `"GXV_API_KEY not set"`:**
```
GXV_API_KEY is not set.

  export GXV_API_KEY=gxv_your_key_here

Get an API key from your GolemXV project settings in the dashboard.
```
STOP here.

**If `status` is `"error"` for any other reason:** Show the error message and STOP.

**If `status` is `"ok"`:** Continue.

**CRITICAL:** Extract the `ppid` value from the JSON output. Store this literal number. Use it in ALL subsequent steps for session file paths. Do NOT use `$PPID` as a shell variable in any later Bash commands -- it will resolve to a different value in each shell invocation.

Also extract from the output:
- `session.valid` -- whether an existing session is still active
- `session.exists` -- whether a session file was found
- `session.agent_name` -- agent name (if session exists and valid)
- `session.token_prefix` -- first 8 chars of token (if session valid)
- `session.session_id` -- session ID (if session valid)
- `project.needs_fetch` -- whether GOLEM.yaml needs to be fetched
- `project.slug` and `project.name` -- project identifiers
- `heartbeat_script` -- resolved path to heartbeat.sh
- `mcp_json.created` or `mcp_json.updated` -- whether MCP config changed
- `presence.active_agents` -- list of currently active agents

### Step 2: Fetch GOLEM.yaml if needed (0-1 calls)

**If `project.needs_fetch` is `false`:** Skip this step. Use `project.slug` and `project.name` from Step 1 output.

**If `project.needs_fetch` is `true`:** Fetch project configuration from the server:

```bash
YAML_CONTENT=$(curl -sf -H "X-API-Key: $GXV_API_KEY" -X POST "${GXV_SERVER_URL:-https://golemxv.com}/_gxv/api/v1/init" 2>&1)
if [ $? -eq 0 ]; then echo "OK"; else echo "FAIL: $YAML_CONTENT"; fi
```

**If request succeeds:** Use the Write tool to save the YAML content to `GOLEM.yaml` in the current directory. Then parse `project.slug` and `project.name` from the written file.

**If request fails:** Display the error and STOP:
```
Could not fetch project config from GolemXV server.
Check that GXV_API_KEY is valid and GXV_SERVER_URL is reachable.
```

### Step 3: Check in or reuse session (0-1 Bash calls)

**If `session.valid` is `true`:** Skip checkin entirely. Use the session data already in the batch output (`agent_name`, `token_prefix`, `session_id`). Go directly to Step 4.

**If `session.valid` is `false` or `session.exists` is `false`:** Perform checkin. Replace `SERVER_URL` with the `env.server_url` value from Step 1:

```bash
CHECKIN=$(curl -sf -H "X-API-Key: $GXV_API_KEY" -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/checkin" 2>&1)
echo "$CHECKIN" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f\"agent_name={d['agent_name']}\nsession_id={d['session_id']}\ntoken_prefix={d['session_token'][:8]}\nfull_token={d['session_token']}\")"
```

**If checkin fails:** Show only the error message, not the full response body. STOP.

Parse the output to extract `agent_name`, `session_id`, `token_prefix`, and `full_token`. Store these for the next step.

**IMPORTANT:** The `full_token` value from the parse output is needed for the session file in Step 4. Do NOT display it to the user.

### Step 4: Persist session + start heartbeat (1 Write + 1 Bash call, or 1 Bash call)

**If new session (checkin happened in Step 3):**

Use the Write tool to create `.gxv/session-<PPID>.json` (where `<PPID>` is the literal number from Step 1). Write this JSON:

```json
{
  "session_token": "<full_token from Step 3 -- NEVER display>",
  "session_id": "<session_id from Step 3>",
  "project_slug": "<project.slug from Step 1 or 2>",
  "project_name": "<project.name from Step 1 or 2>",
  "agent_name": "<agent_name from Step 3>",
  "server_url": "<env.server_url from Step 1>",
  "checked_in_at": "<current ISO 8601 timestamp>"
}
```

**Then** start the heartbeat. Replace `<PPID>` with the literal number from Step 1, and `<HEARTBEAT_SCRIPT>` with the `heartbeat_script` path from Step 1:

```bash
# Stop any existing heartbeat for THIS session (per-session PID file)
if [ -f ".gxv/heartbeat-<PPID>.pid" ]; then
  kill $(cat ".gxv/heartbeat-<PPID>.pid") 2>/dev/null || true
  rm -f ".gxv/heartbeat-<PPID>.pid"
fi

# Start new heartbeat
if [ -x "<HEARTBEAT_SCRIPT>" ]; then
  nohup env GXV_API_KEY="$GXV_API_KEY" "<HEARTBEAT_SCRIPT>" \
    "$(pwd)/.gxv/session-<PPID>.json" 30 \
    > .gxv/heartbeat-<PPID>.log 2>&1 &
  echo "heartbeat_pid=$!"
else
  echo "WARNING: heartbeat.sh not found at <HEARTBEAT_SCRIPT>"
  echo "Sessions will time out without heartbeats."
fi
```

**If existing valid session (no checkin in Step 3):**

Just ensure heartbeat is running using the same heartbeat start logic above (with the existing session file path).

### Step 5: Display connection summary (direct output, no tool call)

Output this directly as markdown response text (do NOT use Bash echo):

```
## Connected to GolemXV

**Project:** [project_name] ([project_slug])
**Agent:** [agent_name]
**Session:** [token_prefix]...
**Server:** [server_url]
**Checked in at:** [timestamp or checked_in_at from session]

### Active Agents ([count])
- [agent-name]: [declared_area or "(no scope)"] (since [started_at])
- [agent-name]: [declared_area or "(no scope)"] (since [started_at])

### Next Steps
- `/gxv:scope [area] [files...]` -- declare your work scope
- `/gxv:status` -- check coordination status
- `/gxv:tasks` -- see available tasks
- `/gxv:msg` -- view inbox or send messages
- `/gxv:done` -- check out when finished

Messages from other agents are delivered automatically on each prompt.

**IMPORTANT:** Always use `/gxv:` skill commands for GolemXV operations. Never call `mcp__golemxv__*` MCP tools directly -- the `/gxv:` skills handle session loading, heartbeats, and proper error handling automatically.
```

**If `mcp_json.created` or `mcp_json.updated` is `true` from Step 1**, add this note at the end:

```
> MCP server configured in .mcp.json. Restart Claude Code for
> MCP tools to become available to other /gxv: commands.
```

## Tool Call Budget

| Scenario | Step 1 | Step 2 | Step 3 | Step 4 | Step 5 | Total |
|----------|--------|--------|--------|--------|--------|-------|
| Fresh session, GOLEM.yaml exists | 1 Bash | 0 | 1 Bash | 1 Write + 1 Bash | 0 (output) | **4** |
| Fresh session, needs GOLEM.yaml | 1 Bash | 1 Bash + 1 Write | 1 Bash | 1 Write + 1 Bash | 0 (output) | **6** |
| Existing valid session | 1 Bash | 0 | 0 | 1 Bash | 0 (output) | **2** |

Target: Fresh session in 4 calls (typical), existing session in 2 calls.

## Error Handling

- **Network errors:** "Could not reach GolemXV server at [url]. Check GXV_SERVER_URL and network connectivity."
- **Invalid API key:** "API key rejected. Check GXV_API_KEY is correct."
- **Server errors:** Display the error message only, not the full response body.
- **Heartbeat not found:** Display warning but continue -- session will work but may time out.
