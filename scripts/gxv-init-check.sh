#!/usr/bin/env bash
# gxv-init-check.sh -- Single-pass environment validation for /gxv:init
#
# Usage: gxv-init-check.sh <project-dir> <server-url>
#
# Environment variables:
#   GXV_API_KEY   (required) -- GolemXV API key
#   GXV_MCP_URL   (optional) -- Override MCP URL for .mcp.json
#
# Outputs structured JSON to stdout. Errors go to stderr.
# Exit 0 = success (status: "ok"), Exit 1 = error (status: "error")

set -euo pipefail

export PROJECT_DIR="${1:?Usage: gxv-init-check.sh <project-dir> <server-url>}"
export SERVER_URL="${2:?Usage: gxv-init-check.sh <project-dir> <server-url>}"

# Remove trailing slash from server URL
SERVER_URL="${SERVER_URL%/}"

# ── 1. Capture PPID ──────────────────────────────────────────────────
# $PPID is the parent of this script process = the Bash tool process = Claude Code process.
# This value is stable within a single Bash tool invocation.
export STABLE_PPID="$PPID"

# ── 2. Validate GXV_API_KEY ──────────────────────────────────────────
if [ -z "${GXV_API_KEY:-}" ]; then
  python3 -c "
import json, sys
json.dump({'status': 'error', 'error': 'GXV_API_KEY not set'}, sys.stdout, indent=2)
print()
"
  exit 1
fi

export API_KEY_PREFIX="${GXV_API_KEY:0:8}"

# ── 3. Create .gxv/ directory ─────────────────────────────────────────
mkdir -p "$PROJECT_DIR/.gxv"

# ── 4-7. Run all remaining checks via python3 ────────────────────────
# Using python3 for ALL JSON parsing, session validation, file manipulation.
# This avoids grep/sed hacks and handles edge cases properly.

export MCP_URL="${GXV_MCP_URL:-${SERVER_URL}/mcp}"

python3 << 'PYEOF'
import json, os, sys, subprocess, glob, time

project_dir = os.environ["PROJECT_DIR"]
server_url = os.environ["SERVER_URL"]
api_key = os.environ["GXV_API_KEY"]
api_key_prefix = os.environ["API_KEY_PREFIX"]
mcp_url = os.environ["MCP_URL"]
stable_ppid = os.environ["STABLE_PPID"]
gxv_mcp_url_set = "GXV_MCP_URL" in os.environ and os.environ.get("GXV_MCP_URL", "") != ""

result = {
    "status": "ok",
    "ppid": int(stable_ppid),
    "env": {
        "api_key_set": True,
        "api_key_prefix": api_key_prefix,
        "server_url": server_url,
        "mcp_url": mcp_url,
    },
    "session": {
        "exists": False,
        "valid": False,
        "file": f".gxv/session-{stable_ppid}.json",
        "agent_name": None,
        "stale_cleaned": 0,
    },
    "project": {
        "slug": None,
        "name": None,
        "needs_fetch": False,
    },
    "gitignore": {
        "updated": False,
    },
    "mcp_json": {
        "existed": False,
        "has_golemxv": False,
        "created": False,
        "updated": False,
    },
    "heartbeat_script": None,
    "presence": {
        "active_agents": [],
    },
}

# ── 4. Check for existing session file ───────────────────────────────
session_file = os.path.join(project_dir, ".gxv", f"session-{stable_ppid}.json")
session_data = None

if os.path.exists(session_file):
    try:
        with open(session_file) as f:
            session_data = json.load(f)
        result["session"]["exists"] = True
        result["session"]["agent_name"] = session_data.get("agent_name")
    except (json.JSONDecodeError, KeyError, IOError) as e:
        print(f"Warning: Could not parse session file: {e}", file=sys.stderr)
        # Remove corrupt session file
        os.remove(session_file)
        session_data = None

# ── 5. Call presence API ──────────────────────────────────────────────
active_agents = []
try:
    proc = subprocess.run(
        ["curl", "-sf", "-H", f"X-API-Key: {api_key}",
         f"{server_url}/_gxv/api/v1/presence"],
        capture_output=True, text=True, timeout=10
    )
    if proc.returncode == 0 and proc.stdout.strip():
        presence_data = json.loads(proc.stdout)
        active_agents = presence_data.get("data", [])
except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception) as e:
    print(f"Warning: Presence API call failed: {e}", file=sys.stderr)

result["presence"]["active_agents"] = active_agents
active_names = {a.get("agent_name") for a in active_agents}

# ── 6. Validate existing session ─────────────────────────────────────
if session_data and result["session"]["exists"]:
    agent_name = session_data.get("agent_name", "")
    if agent_name in active_names:
        result["session"]["valid"] = True
        result["session"]["token_prefix"] = session_data.get("session_token", "")[:8]
        result["session"]["session_id"] = session_data.get("session_id")
    else:
        # Session is stale -- agent not in active list
        result["session"]["valid"] = False
        # Delete the stale session file
        try:
            os.remove(session_file)
            # Also remove matching inbox file
            inbox_file = os.path.join(project_dir, ".gxv", f"inbox-{stable_ppid}.json")
            if os.path.exists(inbox_file):
                os.remove(inbox_file)
        except OSError:
            pass
        result["session"]["exists"] = False
        session_data = None

# ── 7. Clean stale sessions ──────────────────────────────────────────
stale_cleaned = 0
gxv_dir = os.path.join(project_dir, ".gxv")
for session_path in glob.glob(os.path.join(gxv_dir, "session-*.json")):
    # Skip our own session (already handled above)
    if session_path == session_file:
        continue
    try:
        with open(session_path) as f:
            other_session = json.load(f)
        other_agent = other_session.get("agent_name", "")
        if other_agent not in active_names:
            os.remove(session_path)
            # Remove matching inbox file
            other_basename = os.path.basename(session_path).replace("session-", "").replace(".json", "")
            other_inbox = os.path.join(gxv_dir, f"inbox-{other_basename}.json")
            if os.path.exists(other_inbox):
                os.remove(other_inbox)
            stale_cleaned += 1
            print(f"Cleaned stale session: {os.path.basename(session_path)} (agent {other_agent})", file=sys.stderr)
    except (json.JSONDecodeError, KeyError, IOError):
        # Corrupt file -- remove it
        try:
            os.remove(session_path)
            stale_cleaned += 1
        except OSError:
            pass

result["session"]["stale_cleaned"] = stale_cleaned

# ── 8. Check GOLEM.yaml ──────────────────────────────────────────────
golem_yaml_path = os.path.join(project_dir, "GOLEM.yaml")
if os.path.exists(golem_yaml_path):
    try:
        # Parse YAML manually (simple key: value format, no external deps)
        with open(golem_yaml_path) as f:
            content = f.read()
        # Extract project.slug and project.name using simple parsing
        slug = None
        name = None
        in_project = False
        for line in content.splitlines():
            stripped = line.strip()
            if stripped.startswith("project:"):
                in_project = True
                continue
            if in_project and not line.startswith(" ") and not line.startswith("\t") and stripped:
                in_project = False
            if in_project:
                if stripped.startswith("slug:"):
                    slug = stripped.split(":", 1)[1].strip().strip("'\"")
                elif stripped.startswith("name:"):
                    name = stripped.split(":", 1)[1].strip().strip("'\"")
        result["project"]["slug"] = slug
        result["project"]["name"] = name or slug
        result["project"]["needs_fetch"] = False
    except Exception as e:
        print(f"Warning: Could not parse GOLEM.yaml: {e}", file=sys.stderr)
        result["project"]["needs_fetch"] = True
else:
    result["project"]["needs_fetch"] = True

# ── 9. Check .gitignore ──────────────────────────────────────────────
gitignore_path = os.path.join(project_dir, ".gitignore")
has_gxv_entry = False

if os.path.exists(gitignore_path):
    with open(gitignore_path) as f:
        gitignore_content = f.read()
    # Check if .gxv/ is already listed (with or without comment)
    for line in gitignore_content.splitlines():
        stripped = line.strip()
        if stripped == ".gxv/" or stripped == ".gxv":
            has_gxv_entry = True
            break
else:
    gitignore_content = ""

if not has_gxv_entry:
    with open(gitignore_path, "a") as f:
        if gitignore_content and not gitignore_content.endswith("\n"):
            f.write("\n")
        f.write("\n# GolemXV session directory (local, not committed)\n.gxv/\n")
    result["gitignore"]["updated"] = True

# ── 10. Check .mcp.json ──────────────────────────────────────────────
mcp_json_path = os.path.join(project_dir, ".mcp.json")
golemxv_entry = {
    "type": "http",
    "url": mcp_url,
    "headers": {
        "X-API-Key": "${GXV_API_KEY}"
    }
}

if os.path.exists(mcp_json_path):
    result["mcp_json"]["existed"] = True
    try:
        with open(mcp_json_path) as f:
            mcp_data = json.load(f)
        servers = mcp_data.get("mcpServers", {})
        if "golemxv" in servers:
            result["mcp_json"]["has_golemxv"] = True
        else:
            # Add golemxv entry, preserving existing servers
            if "mcpServers" not in mcp_data:
                mcp_data["mcpServers"] = {}
            mcp_data["mcpServers"]["golemxv"] = golemxv_entry
            # Atomic write
            tmp_path = mcp_json_path + ".tmp"
            with open(tmp_path, "w") as f:
                json.dump(mcp_data, f, indent=2)
                f.write("\n")
            os.replace(tmp_path, mcp_json_path)
            result["mcp_json"]["has_golemxv"] = True
            result["mcp_json"]["updated"] = True
    except (json.JSONDecodeError, IOError) as e:
        print(f"Warning: Could not parse .mcp.json: {e}", file=sys.stderr)
else:
    # Create .mcp.json
    mcp_data = {
        "mcpServers": {
            "golemxv": golemxv_entry
        }
    }
    tmp_path = mcp_json_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(mcp_data, f, indent=2)
        f.write("\n")
    os.replace(tmp_path, mcp_json_path)
    result["mcp_json"]["created"] = True
    result["mcp_json"]["has_golemxv"] = True

# ── 11. Detect heartbeat script path ─────────────────────────────────
heartbeat_candidates = []

# Check CLAUDE_PLUGIN_ROOT first (set by Claude Code for plugin hooks/scripts)
plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
if plugin_root:
    heartbeat_candidates.append(os.path.join(plugin_root, "scripts", "heartbeat.sh"))

# Plugin installation path
home = os.environ.get("HOME", "")
if home:
    heartbeat_candidates.append(os.path.join(home, ".claude", "plugins", "gxv-skills", "scripts", "heartbeat.sh"))

# Submodule path (relative to project dir)
heartbeat_candidates.append(os.path.join(project_dir, "gxv-skills", "scripts", "heartbeat.sh"))

for candidate in heartbeat_candidates:
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        result["heartbeat_script"] = candidate
        break

# If none found, report the candidates checked
if result["heartbeat_script"] is None:
    print(f"Warning: heartbeat.sh not found. Checked: {heartbeat_candidates}", file=sys.stderr)

# ── Output ────────────────────────────────────────────────────────────
json.dump(result, sys.stdout, indent=2)
print()
PYEOF
