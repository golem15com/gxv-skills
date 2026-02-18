---
description: Show GolemXV coordination status
allowed-tools: Read, Bash, mcp__golemxv__*
---

# /gxv:status

Show the current coordination status for this project.

## Process

### Step 1: Load session

Read `.gxv-session` in the project root.

**If missing:**
```
## GolemXV Status

Not connected. Run `/gxv:init` to connect to GolemXV.
```
STOP here.

**If found:** Parse JSON and extract `session_token`, `project_slug`, `project_name`, `agent_name`, `checked_in_at`.

**After parsing**, send a heartbeat to keep the session alive. Call `mcp__golemxv__heartbeat` with the `session_token`. If heartbeat fails (session expired), tell the user to run `/gxv:init` to reconnect and STOP.

### Step 2: Get presence

Call `mcp__golemxv__presence` with the `project_slug`.

This returns a list of active agents with their scopes and check-in times.

**If session is expired or invalid:** Tell the user their session has expired and to run `/gxv:init` again.

### Step 3: Get recent messages

Call `mcp__golemxv__get_messages` with the `project_slug` and `limit=5` for recent messages.

### Step 4: Get tasks

Call `mcp__golemxv__list_tasks` with the `project_slug` to get pending and assigned tasks.

### Step 5: Display dashboard

Format the output as:

```
## GolemXV Status: [project_name]

### Connection
- **Status:** Connected
- **Agent:** [agent_name]
- **Session:** [abbreviated session_token]...
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
