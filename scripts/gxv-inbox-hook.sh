#!/usr/bin/env bash
# GXV Inbox Hook — injects scope awareness and unread messages into context
#
# Designed for Claude Code UserPromptSubmit hook.
# - NO network calls — reads only local .gxv/ files
# - Fast-path exit when no .gxv/ dir
# - Outputs plain text to stdout (injected into Claude context)
# - Line 1: [GXV] Scopes summary (always, when presence cache available)
# - Line 2+: Unread messages (only when new messages exist)
# - Updates last_seen_at after message delivery
#
# Uses $CLAUDE_PROJECT_DIR to find .gxv/ directory.

set -euo pipefail

# Determine project directory
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
GXV_DIR="$PROJECT_DIR/.gxv"

# Fast-path: no .gxv directory → nothing to do
[ -d "$GXV_DIR" ] || exit 0

# Use python3 for all file reads and output formatting
python3 -c "
import json, os, sys, glob
from datetime import datetime, timezone

gxv_dir = '$GXV_DIR'
output_lines = []

# ── 1. Scope summary from presence cache ──────────────────────────
presence_pattern = os.path.join(gxv_dir, 'presence-*.json')
presence_files = glob.glob(presence_pattern)

self_agent = ''
scope_parts = []

if presence_files:
    # Use most recently modified presence file
    presence_files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    try:
        with open(presence_files[0]) as f:
            presence = json.load(f)

        # Check staleness — skip if older than 2 minutes
        polled_at = presence.get('last_polled_at', '')
        self_agent = presence.get('self', '')
        stale = False
        if polled_at:
            try:
                polled_dt = datetime.fromisoformat(polled_at.replace('Z', '+00:00'))
                age = (datetime.now(timezone.utc) - polled_dt).total_seconds()
                if age > 120:
                    stale = True
            except (ValueError, TypeError):
                stale = True

        if not stale:
            agents = presence.get('agents', [])
            for a in agents:
                name = a.get('agent_name', '?')
                area = a.get('declared_area', '')
                if name == self_agent:
                    scope_parts.append(f'{name}(YOU)->{area or \"(none)\"}')
                else:
                    scope_parts.append(f'{name}->{area or \"(none)\"}')

            if scope_parts:
                output_lines.append(f'[GXV] Scopes: {', '.join(scope_parts)}')
    except (json.JSONDecodeError, IOError, KeyError):
        pass

# ── 2. Unread messages from inbox files ───────────────────────────
inbox_pattern = os.path.join(gxv_dir, 'inbox-*.json')
inbox_files = glob.glob(inbox_pattern)

unread = []
agent_name = self_agent  # prefer presence-derived agent name

for inbox_file in inbox_files:
    try:
        with open(inbox_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        continue

    file_agent = data.get('agent_name', '')
    if file_agent and not agent_name:
        agent_name = file_agent

    last_seen = data.get('last_seen_at', '')
    messages = data.get('messages', [])

    # Defense-in-depth: filter out DMs between other agents
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

if unread:
    unread.sort(key=lambda m: m.get('created_at', ''))
    count = len(unread)
    output_lines.append(f'[GolemXV] {count} new message(s):')
    output_lines.append('')

    for msg in unread:
        created = msg.get('created_at', '')
        time_str = created[11:16] if len(created) >= 16 else '??:??'
        sender = msg.get('sender', 'unknown')
        recipient = msg.get('recipient', 'broadcast')
        content = msg.get('content', '')

        if recipient == 'broadcast' or not recipient:
            output_lines.append(f'  [{time_str}] {sender} (broadcast): {content}')
        elif agent_name and (recipient == agent_name or msg.get('recipient_name', '') == agent_name):
            output_lines.append(f'  [{time_str}] {sender} -> YOU: {content}')
        else:
            output_lines.append(f'  [{time_str}] {sender} -> {recipient}: {content}')

    output_lines.append('')
    output_lines.append('Reply: /gxv:msg \"your reply\" | DM: /gxv:msg --to agent-name \"message\"')

# ── Output ────────────────────────────────────────────────────────
if output_lines:
    print('\n'.join(output_lines))
" 2>/dev/null || true
