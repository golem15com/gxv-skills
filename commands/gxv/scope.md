---
description: Declare or update work scope
argument-hint: [area] [files...]
allowed-tools: Read, Bash
---

# /gxv:scope

Declare or update your work scope to prevent conflicts with other agents.

## Arguments

- **area** (required): The work area name (e.g., "auth", "payments", "frontend")
- **files** (optional): File patterns that your work will touch (e.g., "src/auth/*.ts" "tests/auth/*")

If no arguments provided, show current scope.

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

### Step 2: Parse arguments

Parse the user's input (`$ARGUMENTS`):
- First argument is the area name.
- Remaining arguments are file patterns.

**If no arguments:** Fetch current scope from presence and display it:
```bash
PRESENCE=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/presence" 2>/dev/null)
echo "$PRESENCE" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
agent = 'AGENT_NAME'
me = [a for a in data if a.get('agent_name') == agent]
if me:
    area = me[0].get('declared_area') or 'not set'
    files = me[0].get('declared_files') or []
    print(f'area={area}')
    print(f'files={json.dumps(files)}')
else:
    print('area=not set')
    print('files=[]')
"
```
(Replace `SERVER_URL` and `AGENT_NAME` with literal values from the session file.)

Display:
```
## Current Scope

**Area:** [area or "not set"]
**Files:** [file patterns or "none declared"]

To update: `/gxv:scope [area] [files...]`
```
STOP here.

### Step 3: Update scope and check conflicts

Update scope via the status endpoint. The response includes conflict detection automatically:
```bash
SCOPE_RESULT=$(curl -sf -w "\n%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/status" \
  -d '{"session_token":"SESSION_TOKEN","declared_area":"AREA","declared_files":FILES_JSON}' 2>/dev/null)
HTTP_CODE=$(echo "$SCOPE_RESULT" | tail -1)
BODY=$(echo "$SCOPE_RESULT" | sed '$d')
echo "scope_status=$HTTP_CODE"
echo "$BODY" | python3 -c "
import sys, json
data = json.load(sys.stdin)
d = data.get('data', {})
meta = data.get('meta', {})
print(f\"area={d.get('declared_area','')}\")
print(f\"files={json.dumps(d.get('declared_files', []))}\")
conflicts = meta.get('conflicts', [])
if conflicts:
    print('has_conflicts=true')
    for c in conflicts:
        agent = c.get('agent_name', '?')
        overlap = c.get('overlap', [])
        ctype = c.get('type', 'file')
        print(f'  conflict: {agent} ({ctype}): {overlap}')
else:
    print('has_conflicts=false')
" 2>/dev/null || echo "$BODY"
```
(Replace `SERVER_URL`, `SESSION_TOKEN`, `AREA` with literal values. Replace `FILES_JSON` with a JSON array of file patterns, e.g. `["src/auth/*.ts","tests/auth/*"]`.)

### Step 4: Display result

**If no conflicts:**
```
## Scope Updated

**Area:** [area]
**Files:** [file patterns]

No conflicts with other agents.
```

**If conflicts detected:**
```
## Scope Updated (with conflicts)

**Area:** [area]
**Files:** [file patterns]

### Conflicts Detected
- **[agent-name]** overlaps on: [conflicting files/area]
  Consider coordinating via `/gxv:msg --to [agent-name] "message"`
```
