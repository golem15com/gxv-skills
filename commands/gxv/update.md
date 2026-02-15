---
description: Update gxv-skills to latest version
allowed-tools: Read, Bash
---

# /gxv:update

Check for and install updates to the gxv-skills plugin.

## Process

### Step 1: Get installed version

Read the VERSION file from the plugin directory:
```bash
cat ~/.claude/plugins/gxv-skills/VERSION 2>/dev/null
```

**If VERSION file missing:**
```
## gxv-skills Update

**Installed version:** Unknown

Your installation may be incomplete. Try reinstalling:
  curl -fsSL https://raw.githubusercontent.com/golem15/gxv-skills/master/install.sh | bash
```
STOP here.

### Step 2: Check for updates

Fetch the latest version from the remote repository:
```bash
cd ~/.claude/plugins/gxv-skills && git fetch origin 2>/dev/null
```

Compare local HEAD with remote:
```bash
cd ~/.claude/plugins/gxv-skills && git rev-list HEAD..origin/master --count 2>/dev/null
```

**If fetch fails:**
```
Couldn't check for updates (offline or repository unavailable).

To update manually:
  cd ~/.claude/plugins/gxv-skills && git pull --ff-only
```
STOP here.

### Step 3: Compare versions

**If no commits behind (count = 0):**
```
## gxv-skills Update

**Installed:** [version]
**Status:** Up to date

You're on the latest version.
```
STOP here.

### Step 4: Show pending changes

If updates are available, show what changed:
```bash
cd ~/.claude/plugins/gxv-skills && git log HEAD..origin/master --oneline
```

Display:
```
## gxv-skills Update Available

**Installed:** [current version]
**Commits behind:** [count]

### Changes
[git log output]

Updating now...
```

### Step 5: Pull updates

```bash
cd ~/.claude/plugins/gxv-skills && git pull --ff-only
```

Read the new VERSION file:
```bash
cat ~/.claude/plugins/gxv-skills/VERSION
```

### Step 6: Display result

```
## gxv-skills Updated

**Previous:** [old version]
**Current:** [new version]

Restart Claude Code to pick up the new commands.
```

**If pull fails (diverged history):**
```
## Update Failed

Local changes conflict with upstream. To force update:
  cd ~/.claude/plugins/gxv-skills && git reset --hard origin/master

Warning: This will discard any local modifications.
```
