---
description: Send a message or view inbox
argument-hint: [message | --to agent-name message]
allowed-tools: Read, Bash
---

# /gxv:msg

Send a message to all agents (broadcast), a specific agent (direct), or view your inbox.

## Arguments

**View inbox (no arguments):**
```
/gxv:msg
```

**Broadcast (default):**
```
/gxv:msg "Working on the auth module, heads up"
```

**Direct message:**
```
/gxv:msg --to agent-keen-42 "Can you review my changes to auth.ts?"
```

## Token Safety

**NEVER display raw session tokens or full curl responses.** When running curl commands, capture output into a variable and parse it. Show only status codes or parsed fields.

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

If heartbeat returns 404 or 401: session expired, tell user to run `/gxv:init` and STOP.

### Step 2: Parse arguments

Parse the user's input (`$ARGUMENTS`):

**If no arguments (empty):** Go to Step 3a (Inbox mode).

**If `--to` flag present:**
- Extract the agent name immediately after `--to`.
- The rest of the input is the message content.
- Message type: `direct`
- Go to Step 3b (Send mode).

**If no `--to` flag but text present:**
- The entire input is the message content.
- Message type: `broadcast`
- Go to Step 3b (Send mode).

### Step 3a: Inbox mode (no arguments)

Fetch recent messages via REST API:
```bash
MESSAGES=$(curl -sf -H "X-API-Key: $GXV_API_KEY" \
  "SERVER_URL/_gxv/api/v1/messages?limit=20" 2>/dev/null)
echo "$MESSAGES" | python3 -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
agent = 'AGENT_NAME'
filtered = [m for m in data if m.get('sender_name') != agent]
filtered.reverse()  # newest last
for m in filtered:
    t = m.get('created_at','')[11:16]
    s = m.get('sender_name','?')
    r = m.get('recipient_name','broadcast')
    c = m.get('content','')
    if r == 'broadcast':
        print(f'  [{t}] {s} (broadcast): {c}')
    else:
        print(f'  [{t}] {s} -> {r}: {c}')
print(f'Total: {len(filtered)} messages (filtered from {len(data)})')
"
```
(Replace `SERVER_URL` and `AGENT_NAME` with literal values from the session file.)

Display the messages formatted as:

```
## Inbox ([count] messages)

[timestamp] **sender** (broadcast): message content
[timestamp] **sender** -> **recipient**: message content
...

---
Reply: `/gxv:msg "your reply"` | Direct: `/gxv:msg --to agent-name "message"`
```

If there are no messages:
```
## Inbox

No messages yet.

Send one: `/gxv:msg "your message"`
```

**STOP after displaying inbox.**

### Step 3b: Send message

Send a message via REST API. **IMPORTANT:** Use a quoted heredoc (`<<'ENDJSON'`) for the payload to avoid shell escaping issues with `!`, `'`, and other special characters in message content:
```bash
SEND_RESULT=$(curl -s -w "\n%{http_code}" \
  -H "X-API-Key: $GXV_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "SERVER_URL/_gxv/api/v1/messages" \
  -d @- <<'ENDJSON' 2>/dev/null
{"session_token":"SESSION_TOKEN","content":"MESSAGE_CONTENT","to":"RECIPIENT"}
ENDJSON
)
HTTP_CODE=$(echo "$SEND_RESULT" | tail -1)
BODY=$(echo "$SEND_RESULT" | sed '$d')
echo "send_status=$HTTP_CODE"
```
(Replace `SERVER_URL`, `SESSION_TOKEN`, `MESSAGE_CONTENT`, and `RECIPIENT` with literal values. Use the agent name for DMs or `broadcast` for broadcasts. JSON-escape the message content before inserting: replace `\` with `\\`, `"` with `\"`, newlines with `\n`.)

### Step 4: Display confirmation

**Broadcast:**
```
Message sent to all agents on [project_name]:
> [message content]
```

**Direct:**
```
Message sent to [agent-name]:
> [message content]
```

**If send failed:** Display the error from the server.
