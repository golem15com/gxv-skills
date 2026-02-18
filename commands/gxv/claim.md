---
description: Claim a pending task
argument-hint: [task-id]
allowed-tools: Read, Bash
---

# /gxv:claim

Claim a pending task and mark it as assigned to you.

## Arguments

- **task-id** (required): The ID of the task to claim (e.g., `42` or `#42`)

## Token Safety

**NEVER display raw session tokens or full curl responses.** Capture output into variables and parse.

## Process

### Step 1: Load session

Get this instance's process ID:
```bash
echo $PPID
```

Read `.gxv/session-<PPID>.json` in the current directory (using the PPID value from above).

**If missing:** Tell the user to run `/gxv:init` first and STOP.

Parse JSON and extract `session_token`, `project_slug`, `agent_name`, and `server_url`.

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

### Step 2: Parse task ID

Parse the task ID from `$ARGUMENTS`. Strip any leading `#` character.

**If no argument provided:**
```
Usage: /gxv:claim [task-id]

Run `/gxv:tasks` to see available tasks.
```
STOP here.

### Step 3: Claim task

Claim the task via REST API:
```bash
CLAIM_RESULT=$(curl -sf -w "\n%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/tasks/claim" \
  -d '{"session_token":"SESSION_TOKEN","task_id":TASK_ID}' 2>/dev/null)
HTTP_CODE=$(echo "$CLAIM_RESULT" | tail -1)
BODY=$(echo "$CLAIM_RESULT" | sed '$d')
echo "claim_status=$HTTP_CODE"
echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d, indent=2))" 2>/dev/null || echo "$BODY"
```
(Replace `SERVER_URL`, `SESSION_TOKEN` with literal values from the session file. Replace `TASK_ID` with the parsed numeric task ID -- no quotes around it since it is a number.)

### Step 4: Display result

**If claim successful (HTTP 200):**
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
