---
description: List available and assigned tasks
allowed-tools: Read, Bash, mcp__golemxv__*
---

# /gxv:tasks

List all tasks for the current project, grouped by status.

## Process

### Step 1: Load session

Read `.gxv-session` in the project root.

**If missing:** Tell the user to run `/gxv:init` first and STOP.

Parse JSON and extract `session_token`, `project_slug`, and `agent_name`.

**After parsing**, send a heartbeat to keep the session alive. Call `mcp__golemxv__heartbeat` with the `session_token`. If heartbeat fails (session expired), tell the user to run `/gxv:init` to reconnect and STOP.

### Step 2: Get tasks

Call `mcp__golemxv__list_tasks` with the `project_slug`.

### Step 3: Display task list

Group tasks by status and display:

```
## Tasks: [project_name]

### Pending ([count])
Tasks available to claim:

| ID | Title | Priority | Work Area |
|----|-------|----------|-----------|
| #[id] | [title] | [priority] | [area] |
| #[id] | [title] | [priority] | [area] |

### In Progress ([count])
| ID | Title | Assigned To | Started |
|----|-------|-------------|---------|
| #[id] | [title] | [agent_name] | [time] |

### My Tasks
Tasks assigned to you ([agent_name]):

| ID | Title | Status | Priority |
|----|-------|--------|----------|
| #[id] | [title] | [status] | [priority] |

### Recently Completed ([count])
| ID | Title | Completed By | Completed At |
|----|-------|-------------|--------------|
| #[id] | [title] | [agent_name] | [time] |
```

If a section has no tasks, show "None" instead of an empty table.

**Tip at bottom:**
```
To claim a task: `/gxv:claim [task-id]`
```
