---
description: Claim a pending task
argument-hint: [task-id]
allowed-tools: Read, Bash, mcp__golemxv__*
---

# /gxv:claim

Claim a pending task and mark it as assigned to you.

## Arguments

- **task-id** (required): The ID of the task to claim (e.g., `42` or `#42`)

## Process

### Step 1: Load session

Get this instance's process ID:
```bash
echo $PPID
```

Read `.gxv/session-<PPID>.json` in the current directory (using the PPID value from above).

**If missing:** Tell the user to run `/gxv:init` first and STOP.

Parse JSON and extract `session_token`, `project_slug`, and `agent_name`.

**After parsing**, send a heartbeat to keep the session alive. Call `mcp__golemxv__heartbeat` with the `session_token`. If heartbeat fails (session expired), tell the user to run `/gxv:init` to reconnect and STOP.

### Step 2: Parse task ID

Parse the task ID from `$ARGUMENTS`. Strip any leading `#` character.

**If no argument provided:**
```
Usage: /gxv:claim [task-id]

Run `/gxv:tasks` to see available tasks.
```
STOP here.

### Step 3: Claim task

Call `mcp__golemxv__claim_task` with:
- `session_token` from the session file
- `task_id`: the parsed task ID

### Step 4: Display result

**If claim successful:**
```
## Task Claimed

**Task #[id]:** [title]
**Priority:** [priority]
**Work Area:** [area]
**Description:**
[task description]

### Next Steps
- Start working on the task
- Update progress: `/gxv:scope [area] [files...]` to declare your scope
- When done: `/gxv:done` to complete and check out
```

**If claim failed (already claimed):**
```
## Claim Failed

Task #[id] is already assigned to [agent_name].

Run `/gxv:tasks` to see available tasks.
```

**If claim failed (task not found):**
```
## Claim Failed

Task #[id] not found.

Run `/gxv:tasks` to see available tasks.
```
