---
description: Connect to GolemXV coordination server
allowed-tools: Read, Write, Bash, Glob, mcp__golemxv__*
---

# /gxv:init

Bootstrap connection to GolemXV coordination server. This command is idempotent -- running it again re-validates the connection and shows current status.

## Process

### Step 1: Check for existing session

Read `.gxv-session` in the project root.

**If file exists:**
1. Parse the JSON to get `session_token` and `project_slug`.
2. Call `mcp__golemxv__presence` with the `project_slug` to verify the session is still active.
3. **If active:** Display current status summary and exit. No re-check-in needed.
4. **If expired or error:** Proceed to Step 2 to re-check-in.

**If file does not exist:** Proceed to Step 2.

### Step 2: Detect GOLEM.yaml

Walk up directories from the current working directory looking for `GOLEM.yaml`:
1. Check cwd
2. Check parent directory
3. Check grandparent directory
4. Continue up to 5 levels

Use the Glob tool or Read tool to check each level.

**If GOLEM.yaml found:** Read it and proceed to Step 3.

**If GOLEM.yaml not found anywhere:** Offer to create one interactively:
1. Ask the user for the **project name** (e.g., "My Project").
2. Ask for the **project slug** (suggest kebab-case derived from the name, e.g., "my-project").
3. Ask for the **GolemXV server URL**. Default to the `GXV_SERVER_URL` environment variable if set. If not set, ask the user.
4. Write `GOLEM.yaml` to the current working directory:
   ```yaml
   project:
     name: "[user-provided name]"
     slug: "[user-provided slug]"
     server_url: "[user-provided or env URL]"
   ```
5. Tell the user: "Created GOLEM.yaml. You can edit it later to add more config."
6. Continue with the newly created file.

### Step 3: Parse GOLEM.yaml

Extract these fields from the GOLEM.yaml file:
- `project.slug` (required)
- `project.name` (optional, defaults to slug)
- `project.server_url` (optional, used for display)

### Step 4: Validate API key

Run via Bash:
```bash
echo $GXV_API_KEY
```

**If empty or unset:**
```
GXV_API_KEY is not set.

Set it before connecting:
  export GXV_API_KEY=gxv_your_key_here

You can get an API key from your GolemXV project settings.
```
STOP here. Do not proceed without a valid API key.

### Step 5: Check in

Call `mcp__golemxv__checkin` with the project slug from GOLEM.yaml.

This validates the API key against the server and returns session information including:
- `session_token` -- opaque token for subsequent MCP calls
- `agent_name` -- assigned by the server

**If checkin fails:** Display the error message from the server and STOP.

### Step 6: Persist session

Write `.gxv-session` to the project root as a JSON file. This is the canonical session schema -- all other `/gxv:` commands depend on these exact fields:

```json
{
  "session_token": "<opaque token from checkin response>",
  "project_slug": "<from GOLEM.yaml project.slug>",
  "project_name": "<from GOLEM.yaml project.name>",
  "agent_name": "<assigned by server during checkin>",
  "server_url": "<GXV_SERVER_URL value used for this session>",
  "checked_in_at": "<ISO 8601 timestamp>"
}
```

### Step 7: Ensure .gxv-session is gitignored

Read `.gitignore` in the project root. If `.gxv-session` is not listed, append it:
```
# GolemXV session (local, not committed)
.gxv-session
```

### Step 8: Get presence info

Call `mcp__golemxv__presence` with the project slug to get:
- Active agent count
- List of active agents and their scopes
- Any detected conflicts

### Step 9: Display connection summary

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

## Error Handling

- **Network errors:** "Could not reach GolemXV server at [url]. Check GXV_SERVER_URL and network connectivity."
- **Invalid API key:** "API key rejected. Check GXV_API_KEY is correct for project [slug]."
- **Server errors:** Display the server error message as-is.
