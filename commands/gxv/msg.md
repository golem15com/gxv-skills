---
description: Send a message to agents or broadcast
argument-hint: [message or --to agent-name message]
allowed-tools: Read, Bash, mcp__golemxv__*
---

# /gxv:msg

Send a message to all agents (broadcast) or a specific agent (direct).

## Arguments

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

Parse JSON and extract `session_token` and `project_slug`.

**After parsing**, send a heartbeat to keep the session alive. Call `mcp__golemxv__heartbeat` with the `session_token`. If heartbeat fails (session expired), tell the user to run `/gxv:init` to reconnect and STOP.

### Step 2: Parse arguments

Parse the user's input (`$ARGUMENTS`):

**If `--to` flag present:**
- Extract the agent name immediately after `--to`.
- The rest of the input is the message content.
- Message type: `direct`

**If no `--to` flag:**
- The entire input is the message content.
- Message type: `broadcast`

**If no arguments:** Tell the user how to use the command and STOP:
```
Usage:
  /gxv:msg "your message"                    -- broadcast to all agents
  /gxv:msg --to agent-name "your message"    -- direct message
```

### Step 3: Send message

Call `mcp__golemxv__send_message` with:
- `session_token` from the session file
- `project_slug`
- `content`: the message text
- `recipient`: the target agent name (if direct) or omit/null (if broadcast)

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
