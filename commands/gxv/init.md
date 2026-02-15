---
description: Connect to GolemXV coordination server
allowed-tools: Read, Write, Bash, Glob
---

# /gxv:init

Bootstrap connection to GolemXV coordination server. This command is idempotent -- running it again re-validates the connection and shows current status.

All server communication uses curl against the REST API, so this works without MCP configured.

## Process

### Step 1: Validate environment variables

Run via Bash:
```bash
echo "GXV_API_KEY=${GXV_API_KEY:-(unset)}" && echo "GXV_SERVER_URL=${GXV_SERVER_URL:-(unset)}"
```

**If either is empty or unset:**
```
Missing environment variables:

  export GXV_API_KEY=gxv_your_key_here
  export GXV_SERVER_URL=https://your-golemxv-server.com

Get an API key from your GolemXV project settings in the dashboard.
```
STOP here. Do not proceed without both variables set.

Store `$GXV_SERVER_URL` and `$GXV_API_KEY` for use in subsequent steps.

### Step 2: Check for existing session

Read `.gxv-session` in the current directory (NOT parent directories).

**If file exists:**
1. Parse the JSON to get `session_token`, `project_slug`, and `server_url`.
2. Verify the session is still active by calling presence via curl:
   ```bash
   curl -sf -H "X-API-Key: $GXV_API_KEY" "$GXV_SERVER_URL/_gxv/api/v1/presence"
   ```
3. **If request succeeds:** Display current status summary (skip to Step 8 for presence, then Step 9 for display). No re-check-in needed.
4. **If request fails:** Delete `.gxv-session` and proceed to Step 3 to re-initialize.

**If file does not exist:** Proceed to Step 3.

### Step 3: Fetch GOLEM.yaml from server

Check if `GOLEM.yaml` exists in the current directory.

**If GOLEM.yaml exists:** Read it and proceed to Step 4.

**If GOLEM.yaml does not exist:** Fetch project configuration from the server. The API key identifies the project, so the server knows which project config to return:

```bash
curl -sf -H "X-API-Key: $GXV_API_KEY" -X POST "$GXV_SERVER_URL/_gxv/api/v1/init"
```

**If request succeeds:** The response is GOLEM.yaml content (text/yaml). Write it to `GOLEM.yaml` in the current directory.

**If request fails:** Display the error and STOP:
```
Could not fetch project config from GolemXV server.
Check that GXV_API_KEY is valid and GXV_SERVER_URL is reachable.
```

### Step 4: Parse GOLEM.yaml

Read `GOLEM.yaml` and extract:
- `project.slug` (required)
- `project.name` (optional, defaults to slug)

### Step 5: Check in

Register as an active agent via the REST API:

```bash
curl -sf -H "X-API-Key: $GXV_API_KEY" -H "Content-Type: application/json" -X POST "$GXV_SERVER_URL/_gxv/api/v1/checkin"
```

Parse the JSON response to extract:
- `data.session_token` -- opaque token for subsequent API calls
- `data.agent_name` -- assigned by the server
- `data.session_id` -- numeric session ID

**If checkin fails:** Display the error message from the server and STOP.

### Step 6: Persist session

Write `.gxv-session` to the current directory as a JSON file. This is the canonical session schema -- all other `/gxv:` commands depend on these exact fields:

```json
{
  "session_token": "<from checkin response>",
  "session_id": "<from checkin response>",
  "project_slug": "<from GOLEM.yaml>",
  "project_name": "<from GOLEM.yaml>",
  "agent_name": "<from checkin response>",
  "server_url": "<GXV_SERVER_URL value>",
  "checked_in_at": "<ISO 8601 timestamp>"
}
```

### Step 7: Ensure .gxv-session is gitignored

Read `.gitignore` in the current directory. If `.gxv-session` is not listed, append it:
```
# GolemXV session (local, not committed)
.gxv-session
```

### Step 8: Set up MCP configuration

Check if `.mcp.json` exists in the current directory.

**If `.mcp.json` does not exist:** Create it:
```json
{
  "mcpServers": {
    "golemxv": {
      "type": "http",
      "url": "${GXV_SERVER_URL}/mcp",
      "headers": {
        "X-API-Key": "${GXV_API_KEY}"
      }
    }
  }
}
```

**If `.mcp.json` exists:** Read it and check if the `golemxv` server entry is present. If not, add it (preserve existing entries). If it already exists, leave it unchanged.

Set `mcp_just_created` flag if the file was created or modified in this step.

### Step 9: Get presence info

Call presence to get active agents:
```bash
curl -sf -H "X-API-Key: $GXV_API_KEY" "$GXV_SERVER_URL/_gxv/api/v1/presence"
```

Parse the response to get:
- Active agent count
- List of active agents and their scopes

### Step 10: Display connection summary

Format the output as:

```
## Connected to GolemXV

**Project:** [project_name] ([project_slug])
**Agent:** [agent_name]
**Session:** [abbreviated session_token, first 8 chars]...
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
- **Server errors:** Display the server error message as-is.
