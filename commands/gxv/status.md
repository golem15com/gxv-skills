---
description: Show GolemXV coordination status
allowed-tools: Read, Bash
---

# /gxv:status

Show the current coordination status for this project.

## Token Safety

**NEVER display raw session tokens or full curl responses.** Capture output into variables and parse. Show only the first 8 characters of tokens followed by `...`.

## Process

### Step 1: Load session

Get this instance's process ID:
```bash
echo $PPID
```

Read `.gxv/session-<PPID>.json` in the current directory (using the PPID value from above).

**If missing:**
```
## GolemXV Status

Not connected. Run `/gxv:init` to connect to GolemXV.
```
STOP here.

**If found:** Parse JSON and extract `session_token`, `project_slug`, `project_name`, `agent_name`, `server_url`, `checked_in_at`.

**After parsing**, send a heartbeat to keep the session alive:
```bash
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/heartbeat" \
  -d '{"session_token":"SESSION_TOKEN"}' 2>/dev/null)
echo "heartbeat_status=$HTTP_CODE"
```
(Replace `SERVER_URL` and `SESSION_TOKEN` with literal values from the session file.)

If heartbeat returns 404 or 401: session expired, tell user to run `/gxv:init` to reconnect and STOP.

### Step 2: Fetch all status data

Fetch presence, messages, and tasks in a single Bash invocation:
```bash
PRESENCE=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/presence" 2>/dev/null)
MESSAGES=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/messages?limit=5" 2>/dev/null)
TASKS=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/tasks" 2>/dev/null)

echo "===PRESENCE==="
echo "$PRESENCE"
echo "===MESSAGES==="
echo "$MESSAGES"
echo "===TASKS==="
echo "$TASKS"
```
(Replace `SERVER_URL` with the literal value from the session file.)

**If any request fails:** Tell the user their session may have expired and to run `/gxv:init` again.

### Step 3: Display dashboard

Parse the JSON responses and format the output as:

```
## GolemXV Status: [project_name]

### Connection
- **Status:** Connected
- **Agent:** [agent_name]
- **Session:** [first 8 chars of session_token]...
- **Checked in:** [relative time, e.g., "2 hours ago"]

### Active Agents ([count])
- [agent-name]: working on [area] (since [time])
- [agent-name]: working on [area] (since [time])

### My Scope
- **Area:** [declared_area or "not set -- use `/gxv:scope` to declare"]
- **Files:** [declared_files or "none declared"]

### Pending Tasks ([count])
- #[id]: [title] ([priority] priority, [assigned_to or "unassigned"])
- #[id]: [title] ([priority] priority, [assigned_to or "unassigned"])

### In Progress ([count])
- #[id]: [title] (assigned to [agent_name])

### Recent Messages
- [sender] -> [recipient or "all"]: "[message]" ([time ago])
- [sender] -> [recipient or "all"]: "[message]" ([time ago])
```

If any section has no data, show "None" instead of an empty list.

Extract your own scope (declared_area, declared_files) from the presence data by finding the entry where agent_name matches your agent name from the session file.
