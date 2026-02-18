#!/usr/bin/env bash
set -e

REPO="https://github.com/golem15com/gxv-skills.git"
PLUGIN_DIR="${HOME}/.claude/plugins/gxv-skills"
COMMANDS_DIR="${HOME}/.claude/commands"

echo "Installing GolemXV skills..."
echo ""

# Step 1: Clone or update the source repo
if [ -d "$PLUGIN_DIR" ]; then
    echo "Updating existing installation..."
    cd "$PLUGIN_DIR" && git pull --ff-only
else
    echo "Fresh install..."
    git clone "$REPO" "$PLUGIN_DIR"
fi

# Step 2: Symlink commands into Claude Code's auto-discovery path
mkdir -p "$COMMANDS_DIR"

# Remove existing symlink or directory if present
if [ -L "$COMMANDS_DIR/gxv" ] || [ -d "$COMMANDS_DIR/gxv" ]; then
    rm -rf "$COMMANDS_DIR/gxv"
fi

ln -s "$PLUGIN_DIR/commands/gxv" "$COMMANDS_DIR/gxv"

# Step 3: Ensure scripts are executable
chmod +x "$PLUGIN_DIR/scripts/"*.sh 2>/dev/null || true

echo ""
echo "GolemXV skills installed!"
echo "  Source: $PLUGIN_DIR"
echo "  Commands: $COMMANDS_DIR/gxv -> (symlinked)"
echo ""
echo "Next steps:"
echo "  1. Set your API key:    export GXV_API_KEY=gxv_your_key_here"
echo "  2. Restart Claude Code"
echo "  3. Run /gxv:init in your project directory"
echo ""
echo "Server defaults to https://golemxv.com. For whitelabel deployments:"
echo "  export GXV_SERVER_URL=https://your-custom-server.com"
echo ""
