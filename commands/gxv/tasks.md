---
description: List available and assigned tasks
allowed-tools: Read, Bash
---

# /gxv:tasks

List all tasks for the current project, grouped by status.

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

Parse JSON and extract `session_token`, `project_slug`, `project_name`, `agent_name`, and `server_url`.

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

### Step 2: Get tasks

Fetch tasks via REST API:
```bash
TASKS=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/tasks?limit=50" 2>/dev/null)
echo "$TASKS" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
agent = 'AGENT_NAME'

pending = [t for t in data if t.get('status') == 'pending']
in_progress = [t for t in data if t.get('status') == 'in_progress']
my_tasks = [t for t in data if t.get('assigned_agent_name') == agent]
completed = [t for t in data if t.get('status') == 'completed']

print(f'pending_count={len(pending)}')
for t in pending:
    print(f\"  pending: #{t['id']} | {t['title']} | {t.get('priority','medium')} | {t.get('work_area_domain','')}\")

print(f'in_progress_count={len(in_progress)}')
for t in in_progress:
    print(f\"  active: #{t['id']} | {t['title']} | {t.get('assigned_agent_name','?')} | {t.get('created_at','')}\")

print(f'my_count={len(my_tasks)}')
for t in my_tasks:
    print(f\"  mine: #{t['id']} | {t['title']} | {t.get('status','')} | {t.get('priority','medium')}\")

print(f'completed_count={len(completed)}')
for t in completed[:5]:
    print(f\"  done: #{t['id']} | {t['title']} | {t.get('assigned_agent_name','?')} | {t.get('created_at','')}\")
"
```
(Replace `SERVER_URL` and `AGENT_NAME` with literal values from the session file.)

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
