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
- Parse with lightweight tools: `echo "$RESPONSE" | grep -o '"field":"[^"]*"'` or similar
- Never echo full tokens -- use `${VAR:0:8}...` for display
- If a command fails, show the HTTP status or error message, not the full response body

## Process

### Step 1: Validate environment variables

Check that the API key is set and apply the default server URL if not overridden:

```bash
if [ -z "$GXV_API_KEY" ]; then echo "GXV_API_KEY=(unset)"; else echo "GXV_API_KEY=${GXV_API_KEY:0:8}..."; fi && \
if [ -z "$GXV_SERVER_URL" ]; then export GXV_SERVER_URL=https://golemxv.com && echo "GXV_SERVER_URL=$GXV_SERVER_URL (default)"; else echo "GXV_SERVER_URL=$GXV_SERVER_URL (custom)"; fi && \
echo "GXV_MCP_URL=${GXV_MCP_URL:-(auto: \$GXV_SERVER_URL/mcp)}"
```

**If GXV_API_KEY is empty or unset:**
```
GXV_API_KEY is not set.

  export GXV_API_KEY=gxv_your_key_here

Get an API key from your GolemXV project settings in the dashboard.
```
STOP here.

### Step 2: Generate instance ID and check for existing session

First, generate a unique instance ID for this Claude Code session (if not already set). This ID distinguishes concurrent consoles sharing the same working directory:

```bash
if [ -z "$GXV_INSTANCE_ID" ]; then
  export GXV_INSTANCE_ID=$(head -c 8 /dev/urandom | xxd -p)
  echo "GXV_INSTANCE_ID=$GXV_INSTANCE_ID (new)"
else
  echo "GXV_INSTANCE_ID=$GXV_INSTANCE_ID (existing)"
fi
```

Now read `.gxv-session` in the current directory (NOT parent directories).

**If file exists:**
1. Parse the JSON to get `session_token`, `project_slug`, `server_url`, and `instance_id`.
2. **If `instance_id` in the file matches `$GXV_INSTANCE_ID`:** This is our own session from a previous `/gxv:init` run in the same console. Verify it is still active by calling presence via curl (capture output, don't stream):
   ```bash
   PRESENCE=$(curl -sf -H "X-API-Key: $GXV_API_KEY" "$GXV_SERVER_URL/_gxv/api/v1/presence" 2>&1)
   echo "HTTP status: $?"
   ```
   - **If request succeeds (exit code 0):** Parse the presence data. Still run Step 7 (start heartbeat), Step 8 (.gitignore), and Step 9 (.mcp.json setup) to ensure heartbeat is running and config files exist, then skip to Step 11 for display. No re-check-in needed.
   - **If request fails:** Delete `.gxv-session` and proceed to Step 3 to re-initialize.
3. **If `instance_id` does not match (or is missing):** Another console owns this session. Proceed to Step 3 to create a new session for this console. Do NOT delete the existing file yet -- Step 6 will overwrite it.

**If file does not exist:** Proceed to Step 3.

### Step 3: Fetch GOLEM.yaml from server

Check if `GOLEM.yaml` exists in the current directory using Read tool.

**If GOLEM.yaml exists:** Read it and proceed to Step 4.

**If GOLEM.yaml does not exist:** Fetch project configuration from the server. The API key identifies the project, so the server knows which project config to return:

```bash
YAML_CONTENT=$(curl -sf -H "X-API-Key: $GXV_API_KEY" -X POST "$GXV_SERVER_URL/_gxv/api/v1/init" 2>&1)
if [ $? -eq 0 ]; then echo "OK: received GOLEM.yaml from server"; else echo "FAIL: $YAML_CONTENT"; fi
```

**If request succeeds:** Use the Write tool to write the YAML content to `GOLEM.yaml` in the current directory. Do NOT echo the content through Bash.

**If request fails:** Display the error and STOP:
```
Could not fetch project config from GolemXV server.
Check that GXV_API_KEY is valid and GXV_SERVER_URL is reachable.
```

### Step 4: Parse GOLEM.yaml

Read `GOLEM.yaml` with the Read tool and extract:
- `project.slug` (required)
- `project.name` (optional, defaults to slug)

### Step 5: Check in

Register as an active agent via the REST API. Capture the response:

```bash
CHECKIN=$(curl -sf -H "X-API-Key: $GXV_API_KEY" -H "Content-Type: application/json" -X POST "$GXV_SERVER_URL/_gxv/api/v1/checkin" 2>&1)
echo "exit_code=$?"
```

If exit code is 0, parse the JSON response (use the Read tool concept -- the variable has the data). Extract these fields from the `data` object:
- `session_token` -- opaque token for subsequent API calls (NEVER display fully)
- `agent_name` -- assigned by the server (safe to display)
- `session_id` -- numeric session ID (safe to display)

To extract fields safely without showing the full response:
```bash
echo "$CHECKIN" | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(f\"agent_name={d['agent_name']}\ntoken_prefix={d['session_token'][:8]}\")"
```

**If checkin fails:** Show only the error message, not the full response body. STOP.

### Step 6: Persist session

Use the Write tool to write `.gxv-session` to the current directory as JSON. This is the canonical session schema -- all other `/gxv:` commands depend on these exact fields:

```json
{
  "session_token": "<full token from checkin - stored in file, never displayed>",
  "session_id": "<from checkin response>",
  "project_slug": "<from GOLEM.yaml>",
  "project_name": "<from GOLEM.yaml>",
  "agent_name": "<from checkin response>",
  "server_url": "<GXV_SERVER_URL value>",
  "instance_id": "<GXV_INSTANCE_ID value>",
  "checked_in_at": "<ISO 8601 timestamp>"
}
```

### Step 7: Start heartbeat

The server times out sessions that don't send periodic heartbeats (default: 90 seconds). Start a background heartbeat process to keep the session alive:

```bash
# Stop any existing heartbeat
if [ -f ".gxv/heartbeat.pid" ]; then
  kill $(cat ".gxv/heartbeat.pid") 2>/dev/null || true
  rm -f ".gxv/heartbeat.pid"
fi

# Start new heartbeat
mkdir -p .gxv
HEARTBEAT_SCRIPT="$HOME/.claude/plugins/gxv-skills/scripts/heartbeat.sh"
if [ -x "$HEARTBEAT_SCRIPT" ]; then
  nohup env GXV_API_KEY="$GXV_API_KEY" "$HEARTBEAT_SCRIPT" \
    "$(pwd)/.gxv-session" 30 \
    > .gxv/heartbeat.log 2>&1 &
  echo "heartbeat started (pid=$!, interval=30s)"
else
  echo "WARNING: heartbeat.sh not found at $HEARTBEAT_SCRIPT"
  echo "Sessions will time out without heartbeats."
  echo "Update gxv-skills: curl -fsSL https://skills.golemxv.com | bash"
fi
```

**Important:** The heartbeat script reads the session token from `.gxv-session` and sends periodic heartbeats to the server. It automatically stops when the session file is deleted (by `/gxv:done`) or when the session expires server-side.

### Step 8: Ensure session files are gitignored

Read `.gitignore` in the current directory. If `.gxv-session` and `.gxv/` are not already listed, append them:
```
# GolemXV session files (local, not committed)
.gxv-session
.gxv/
```

### Step 9: Set up MCP configuration

Determine the MCP server URL. Check for an optional override env var:

```bash
echo "GXV_MCP_URL=${GXV_MCP_URL:-(unset)}"
```

- If `GXV_MCP_URL` is set, use that as the MCP URL (for dev setups where MCP runs on a different port)
- If `GXV_MCP_URL` is not set, use `${GXV_SERVER_URL}/mcp` (defaults to `https://golemxv.com/mcp` since GXV_SERVER_URL defaults to `https://golemxv.com`)

Check if `.mcp.json` exists in the current directory.

**If `.mcp.json` does not exist:** Create it with the Write tool. Use the resolved MCP URL:
```json
{
  "mcpServers": {
    "golemxv": {
      "type": "http",
      "url": "<resolved MCP URL>",
      "headers": {
        "X-API-Key": "${GXV_API_KEY}"
      }
    }
  }
}
```

For example:
- If `GXV_MCP_URL=http://localhost:3100/mcp` → use that literally
- If `GXV_MCP_URL` unset and `GXV_SERVER_URL=https://golemxv.com` (default) → use `https://golemxv.com/mcp`
- If `GXV_MCP_URL` unset and `GXV_SERVER_URL=https://custom.example.com` (custom) → use `https://custom.example.com/mcp`

**If `.mcp.json` exists:** Read it and check if the `golemxv` server entry is present under `mcpServers`. If not, add it (preserve existing entries). If it already exists, leave it unchanged.

Set `mcp_just_created` flag if the file was created or modified in this step.

### Step 10: Get presence info

Call presence to get active agents (capture output):
```bash
PRESENCE=$(curl -sf -H "X-API-Key: $GXV_API_KEY" "$GXV_SERVER_URL/_gxv/api/v1/presence" 2>&1)
echo "$PRESENCE" | python3 -c "import sys,json; agents=json.load(sys.stdin)['data']; print(f'active_agents={len(agents)}'); [print(f\"  {a['agent_name']}: {a.get('declared_area','(no scope)')} since {a['started_at']}\") for a in agents]"
```

### Step 11: Display connection summary

Output this directly as markdown (do NOT use Bash echo -- just output it as your response text):

```
## Connected to GolemXV

**Project:** [project_name] ([project_slug])
**Agent:** [agent_name]
**Session:** [first 8 chars of session_token]...
**Server:** [server_url]
**Checked in at:** [timestamp]

### Active Agents ([count])
- [agent-name]: [scope area] (since [time])
- [agent-name]: [scope area] (since [time])

### Next Steps
- `/gxv:scope [area] [files...]` -- declare your work scope
- `/gxv:status` -- check coordination status
- `/gxv:tasks` -- see available tasks
- `/gxv:done` -- check out when finished
```

**If `mcp_just_created` is true**, add this note at the end:

```
> MCP server configured in .mcp.json. Restart Claude Code for
> MCP tools to become available to other /gxv: commands.
```

## Error Handling

- **Network errors:** "Could not reach GolemXV server at [url]. Check GXV_SERVER_URL and network connectivity."
- **Invalid API key:** "API key rejected. Check GXV_API_KEY is correct."
- **Server errors:** Display the error message only, not the full response body.
