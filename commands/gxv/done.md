---
description: Complete work and check out
argument-hint: [optional work summary]
allowed-tools: Read, Write, Bash, mcp__golemxv__*
---

# /gxv:done

Complete your current work, send a departure broadcast, and check out of GolemXV coordination. This performs full cleanup in a single command.

## Arguments

- **work summary** (optional): A brief summary of what you accomplished. If omitted, a generic departure message is sent.

## Process

### Step 1: Load session

Get this instance's process ID:
```bash
echo $PPID
```

Read `.gxv/session-<PPID>.json` in the current directory (using the PPID value from above).

**If missing:**
```
Not connected to GolemXV. Nothing to check out from.
```
STOP here.

Parse JSON and extract `session_token`, `project_slug`, `project_name`, and `agent_name`.

### Step 2: Complete active task (if any)

Call `mcp__golemxv__list_tasks` with the `project_slug` to find tasks assigned to this agent (`agent_name`) that are in progress.

**If an active task is found:**
1. Call `mcp__golemxv__complete_task` with the `session_token` and `task_id`.
2. If a work summary was provided in `$ARGUMENTS`, include it as the completion note.
3. Note which task was completed for the departure message.

**If no active task:** Skip this step.

### Step 3: Send departure broadcast

Compose a departure message:

**If work summary provided:**
```
[agent_name] checking out. Summary: [work summary]
```

**If task was completed:**
```
[agent_name] checking out. Completed task #[id]: [title]. [work summary if provided]
```

**If no summary and no task:**
```
[agent_name] checking out.
```

Call `mcp__golemxv__send_message` with:
- `session_token`
- `project_slug`
- `content`: the departure message (broadcast, no specific recipient)

### Step 4: Clear scope

Call `mcp__golemxv__scope_update` with:
- `session_token`
- `area`: empty string (clears scope)
- `files`: empty array

### Step 5: Check out

Call `mcp__golemxv__checkout` with the `session_token`.

### Step 6: Delete session file

Delete this instance's session file:
```bash
rm ".gxv/session-$PPID.json"
```

### Step 7: Display checkout summary

```
## Checked Out of GolemXV

**Project:** [project_name]
**Agent:** [agent_name]
**Session ended:** [current timestamp]

### Summary
- [Task completed: #[id] [title] (if applicable)]
- Departure broadcast sent
- Scope cleared
- Session ended

To reconnect later: `/gxv:init`
```
