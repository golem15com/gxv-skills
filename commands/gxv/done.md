---
description: Complete work and check out
argument-hint: [optional work summary]
allowed-tools: Read, Write, Bash
---

# /gxv:done

Complete your current work, send a departure broadcast, and check out of GolemXV coordination. This performs full cleanup in a single command.

## Arguments

- **work summary** (optional): A brief summary of what you accomplished. If omitted, a generic departure message is sent.

## Token Safety

**NEVER display raw session tokens or full curl responses.** Capture output into variables and parse.

## Process

### Step 1: Load session

Get this instance's process ID:
```bash
echo $PPID
```

**CRITICAL:** Store the PPID number from the output above. You MUST use this exact number as a literal value in ALL subsequent steps -- including the cleanup step. Do NOT use `$PPID` as a shell variable in later Bash commands.

Read `.gxv/session-<PPID>.json` in the current directory (using the PPID value from above).

**If missing:**
```
Not connected to GolemXV. Nothing to check out from.
```
STOP here.

Parse JSON and extract `session_token`, `project_slug`, `project_name`, `agent_name`, and `server_url`.

### Step 2: Complete active task (if any)

Fetch tasks assigned to this agent via REST API:
```bash
TASKS=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/tasks?assigned_to=AGENT_NAME&status=in_progress" 2>/dev/null)
echo "$TASKS" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for t in data:
    print(f\"task_id={t['id']} title={t['title']}\")
if not data:
    print('no_active_tasks')
"
```
(Replace `SERVER_URL` and `AGENT_NAME` with literal values from the session file.)

**If an active task is found:** Complete it via REST API:
```bash
COMPLETE=$(curl -sf -w "\n%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/tasks/TASK_ID/status" \
  -d '{"session_token":"SESSION_TOKEN","status":"completed"}' 2>/dev/null)
HTTP_CODE=$(echo "$COMPLETE" | tail -1)
echo "complete_status=$HTTP_CODE"
```
(Replace `SERVER_URL`, `TASK_ID`, and `SESSION_TOKEN` with literal values. If a work summary was provided in `$ARGUMENTS`, include it as the completion note.)

Note which task was completed for the departure message.

**If no active task:** Skip this step.

### Step 3: Departure broadcast, clear scope, and checkout

Perform all three operations in a single Bash invocation. Compose the departure message:

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

Run all three API calls together:
```bash
# Send departure broadcast
MSG_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/messages" \
  -d '{"session_token":"SESSION_TOKEN","content":"DEPARTURE_MESSAGE","to":"broadcast"}' 2>/dev/null)
echo "departure_broadcast=$MSG_CODE"

# Clear scope
SCOPE_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/status" \
  -d '{"session_token":"SESSION_TOKEN","declared_area":"","declared_files":[]}' 2>/dev/null)
echo "clear_scope=$SCOPE_CODE"

# Checkout
CHECKOUT_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/checkout" \
  -d '{"session_token":"SESSION_TOKEN"}' 2>/dev/null)
echo "checkout=$CHECKOUT_CODE"
```
(Replace `SERVER_URL`, `SESSION_TOKEN`, and `DEPARTURE_MESSAGE` with literal values. Escape any double quotes in the departure message with backslash.)

### Step 4: Stop heartbeat and delete session + inbox files

Stop the background heartbeat process and clean up session, inbox, heartbeat PID, and log files. Use the literal PPID from Step 1 (NOT `$PPID`):
```bash
# Stop heartbeat (per-session PID file)
if [ -f ".gxv/heartbeat-LITERAL_PPID.pid" ]; then
  kill $(cat ".gxv/heartbeat-LITERAL_PPID.pid") 2>/dev/null || true
  rm -f ".gxv/heartbeat-LITERAL_PPID.pid"
fi

# Delete session, inbox, and heartbeat log files (use literal PPID, e.g. 1234567)
rm -f ".gxv/session-LITERAL_PPID.json"
rm -f ".gxv/inbox-LITERAL_PPID.json"
rm -f ".gxv/heartbeat-LITERAL_PPID.log"
echo "cleanup done"
```
(Replace `LITERAL_PPID` with the actual PPID number captured in Step 1.)

### Step 5: Display checkout summary

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
