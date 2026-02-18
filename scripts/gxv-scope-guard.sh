#!/usr/bin/env bash
# GXV Scope Guard — PreToolUse hook for Edit/Write conflict detection
#
# Checks if the target file overlaps another agent's declared scope.
# NO network calls — reads local files only. Target: <50ms.
#
# Behavior:
#   - conflict_mode: "warn"    → allow (pass-through), context hook shows scopes
#   - conflict_mode: "enforce" → deny with reason + coordination suggestion
#
# Safety: allows through when:
#   - No .gxv/ directory
#   - No session file (agent not checked in)
#   - No presence cache or cache older than 2 minutes
#   - File is in own scope
#   - File doesn't match any other agent's scope
#   - GOLEM.yaml missing or conflict_mode unset (default: warn)
#
# Uses $CLAUDE_PROJECT_DIR to find .gxv/ and GOLEM.yaml.

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
GXV_DIR="$PROJECT_DIR/.gxv"

# Fast-path: no .gxv directory → not using GolemXV
[ -d "$GXV_DIR" ] || exit 0

# Delegate to python3 for all logic
echo "$INPUT" | python3 -c "
import json, os, sys, glob
from datetime import datetime, timezone

project_dir = '$PROJECT_DIR'
gxv_dir = '$GXV_DIR'

# ── Parse hook input ──────────────────────────────────────────────
try:
    hook_input = json.load(sys.stdin)
except (json.JSONDecodeError, IOError):
    sys.exit(0)  # Can't parse → allow

tool_input = hook_input.get('tool_input', {})
file_path = tool_input.get('file_path', '')

if not file_path:
    sys.exit(0)  # No file path → allow

# ── Normalize to project-relative path ────────────────────────────
abs_project = os.path.realpath(project_dir)
abs_file = os.path.realpath(file_path) if os.path.isabs(file_path) else os.path.realpath(os.path.join(abs_project, file_path))

if abs_file.startswith(abs_project + '/'):
    rel_path = abs_file[len(abs_project) + 1:]
else:
    sys.exit(0)  # File outside project → allow (not our concern)

# ── Find own session ──────────────────────────────────────────────
session_files = glob.glob(os.path.join(gxv_dir, 'session-*.json'))
if not session_files:
    sys.exit(0)  # No session → not checked in → allow

# Read own agent name from session file(s)
own_agent = ''
for sf in session_files:
    try:
        with open(sf) as f:
            sd = json.load(f)
        own_agent = sd.get('agent_name', '')
        if own_agent:
            break
    except (json.JSONDecodeError, IOError):
        continue

if not own_agent:
    sys.exit(0)  # Can't determine own identity → allow

# ── Load presence cache ───────────────────────────────────────────
presence_files = glob.glob(os.path.join(gxv_dir, 'presence-*.json'))
if not presence_files:
    sys.exit(0)  # No presence data → allow

# Use most recently modified
presence_files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
try:
    with open(presence_files[0]) as f:
        presence = json.load(f)
except (json.JSONDecodeError, IOError):
    sys.exit(0)  # Can't read → allow

# Check staleness (>2 minutes old → don't block on stale data)
polled_at = presence.get('last_polled_at', '')
if polled_at:
    try:
        polled_dt = datetime.fromisoformat(polled_at.replace('Z', '+00:00'))
        age = (datetime.now(timezone.utc) - polled_dt).total_seconds()
        if age > 120:
            sys.exit(0)  # Stale cache → allow
    except (ValueError, TypeError):
        sys.exit(0)  # Bad timestamp → allow
else:
    sys.exit(0)  # No timestamp → allow

# ── Check for conflicts ──────────────────────────────────────────
agents = presence.get('agents', [])
conflict_agent = None
conflict_reason = ''

for a in agents:
    name = a.get('agent_name', '')
    if name == own_agent or not name:
        continue

    area = a.get('declared_area', '')
    files = a.get('declared_files') or []

    # Area match: rel_path starts with declared_area/
    if area and (rel_path.startswith(area + '/') or rel_path == area):
        conflict_agent = name
        conflict_reason = f'area: {area}'
        break

    # Files match: any declared file is a prefix of rel_path
    for df in files:
        # Handle glob-style patterns: strip trailing ** or *
        df_clean = df.rstrip('*').rstrip('/')
        if df_clean and (rel_path.startswith(df_clean + '/') or rel_path == df_clean or rel_path.startswith(df_clean)):
            conflict_agent = name
            conflict_reason = f'file: {df}'
            break
    if conflict_agent:
        break

if not conflict_agent:
    sys.exit(0)  # No conflict → allow

# ── Read conflict_mode from GOLEM.yaml ────────────────────────────
conflict_mode = 'warn'  # default
golem_path = os.path.join(project_dir, 'GOLEM.yaml')
if os.path.exists(golem_path):
    try:
        with open(golem_path) as f:
            content = f.read()
        in_coordination = False
        for line in content.splitlines():
            stripped = line.strip()
            if stripped.startswith('coordination:'):
                in_coordination = True
                continue
            if in_coordination and not line.startswith(' ') and not line.startswith('\t') and stripped:
                in_coordination = False
            if in_coordination and stripped.startswith('conflict_mode:'):
                conflict_mode = stripped.split(':', 1)[1].strip().strip(\"'\\\"\" )
                break
    except IOError:
        pass

# ── Act on conflict ───────────────────────────────────────────────
if conflict_mode == 'enforce':
    reason = (
        f'SCOPE CONFLICT: {rel_path} is in {conflict_agent}\\'s scope ({conflict_reason}).\\n'
        f'Coordinate first: /gxv:msg --to {conflict_agent} \"Can I edit {os.path.basename(rel_path)}?\"'
    )
    result = {
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'permissionDecision': 'deny',
            'permissionDecisionReason': reason,
        }
    }
    json.dump(result, sys.stdout)
    print()
else:
    # warn mode (or unknown) → allow, context hook shows scopes
    sys.exit(0)
" 2>/dev/null || true
