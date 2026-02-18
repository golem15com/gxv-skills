---
description: Send a message or view inbox
argument-hint: [message | --to agent-name message]
allowed-tools: Read, Bash, mcp__golemxv__*
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

Fetch recent messages by calling `mcp__golemxv__get_messages` with:
- `project_slug`
- `limit`: 20

Display the messages formatted as:

```
## Inbox ([count] messages)

[timestamp] **sender** (broadcast): message content
[timestamp] **sender** → **recipient**: message content
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

Filter out messages sent by this agent (`agent_name`) from the display. Format timestamps as `HH:MM` from the ISO `created_at` field. Show newest messages last.

**STOP after displaying inbox.**

### Step 3b: Send message

Call `mcp__golemxv__send_message` with:
- `session_token` from the session file
- `project_slug`
- `content`: the message text
- `to`: the target agent name (if direct) or `broadcast` (if broadcast)

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
