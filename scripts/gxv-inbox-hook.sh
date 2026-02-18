#!/usr/bin/env bash
# GXV Inbox Hook — reads local inbox files and outputs unread messages
#
# Designed for Claude Code UserPromptSubmit hook.
# - NO network calls — reads only local .gxv/inbox-*.json files
# - Fast-path exit when no .gxv/ dir or no inbox files
# - Outputs plain text to stdout (injected into Claude context)
# - Updates last_seen_at after delivery
#
# Uses $CLAUDE_PROJECT_DIR to find .gxv/ directory.

set -euo pipefail

# Determine project directory
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
GXV_DIR="$PROJECT_DIR/.gxv"

# Fast-path: no .gxv directory → nothing to do
[ -d "$GXV_DIR" ] || exit 0

# Collect all inbox files
INBOX_FILES=("$GXV_DIR"/inbox-*.json)

# Fast-path: no inbox files (glob didn't match)
[ -e "${INBOX_FILES[0]}" ] || exit 0

# Use python3 to read all inbox files, collect unread messages, update last_seen_at
python3 -c "
import json, os, sys, glob
from datetime import datetime, timezone

gxv_dir = '$GXV_DIR'
inbox_pattern = os.path.join(gxv_dir, 'inbox-*.json')
inbox_files = glob.glob(inbox_pattern)

if not inbox_files:
    sys.exit(0)

unread = []
agent_name = ''

for inbox_file in inbox_files:
    try:
        with open(inbox_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        continue

    # Extract agent_name from inbox data (set by heartbeat)
    file_agent = data.get('agent_name', '')
    if file_agent and not agent_name:
        agent_name = file_agent

    last_seen = data.get('last_seen_at', '')
    messages = data.get('messages', [])

    # Defense-in-depth: filter out DMs between other agents
    # (heartbeat should already exclude these, but handle old inbox files)
    if agent_name:
        messages = [m for m in messages
            if m.get('recipient', 'broadcast') == 'broadcast'
            or m.get('recipient_type', '') == 'broadcast'
            or m.get('recipient', '') == agent_name
            or m.get('recipient_name', '') == agent_name
            or m.get('sender', '') == agent_name]

    file_unread = []
    for msg in messages:
        created = msg.get('created_at', '')
        if not last_seen or created > last_seen:
            file_unread.append(msg)

    if not file_unread:
        continue

    unread.extend(file_unread)

    # Update last_seen_at to now
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    data['last_seen_at'] = now
    tmp = inbox_file + '.tmp'
    try:
        with open(tmp, 'w') as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, inbox_file)
    except IOError:
        pass

if not unread:
    sys.exit(0)

# Sort by created_at
unread.sort(key=lambda m: m.get('created_at', ''))

# Format output
count = len(unread)
print(f'[GolemXV] {count} new message(s):')
print()

for msg in unread:
    created = msg.get('created_at', '')
    # Extract HH:MM from ISO timestamp
    time_str = created[11:16] if len(created) >= 16 else '??:??'
    sender = msg.get('sender', 'unknown')
    recipient = msg.get('recipient', 'broadcast')
    content = msg.get('content', '')

    if recipient == 'broadcast' or not recipient:
        print(f'  [{time_str}] {sender} (broadcast): {content}')
    elif agent_name and (recipient == agent_name or msg.get('recipient_name', '') == agent_name):
        # DM addressed to this agent — highlight with -> YOU
        print(f'  [{time_str}] {sender} -> YOU: {content}')
    else:
        # DM from this agent to someone else, or unknown recipient
        print(f'  [{time_str}] {sender} -> {recipient}: {content}')

print()
print('Reply: /gxv:msg \"your reply\" | DM: /gxv:msg --to agent-name \"message\"')
" 2>/dev/null || true
