---
description: Declare or update work scope
argument-hint: [area] [files...]
allowed-tools: Read, Bash, mcp__golemxv__*
---

# /gxv:scope

Declare or update your work scope to prevent conflicts with other agents.

## Arguments

- **area** (required): The work area name (e.g., "auth", "payments", "frontend")
- **files** (optional): File patterns that your work will touch (e.g., "src/auth/*.ts" "tests/auth/*")

If no arguments provided, show current scope.

## Process

### Step 1: Load session

Read `.gxv-session` in the project root.

**If missing:** Tell the user to run `/gxv:init` first and STOP.

Parse JSON and extract `session_token` and `project_slug`.

### Step 2: Parse arguments

Parse the user's input (`$ARGUMENTS`):
- First argument is the area name.
- Remaining arguments are file patterns.

**If no arguments:** Call `mcp__golemxv__presence` to get current scope and display it:
```
## Current Scope

**Area:** [area or "not set"]
**Files:** [file patterns or "none declared"]

To update: `/gxv:scope [area] [files...]`
```
STOP here.

### Step 3: Update scope

Call `mcp__golemxv__scope_update` with:
- `session_token` from the session file
- `area`: the parsed area name
- `files`: array of file patterns

### Step 4: Check for conflicts

Call `mcp__golemxv__conflict_check` with the `project_slug` and new scope to see if any other agent's scope overlaps.

### Step 5: Display result

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
