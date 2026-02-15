#!/usr/bin/env bash
set -e

REPO="https://github.com/golem15com/gxv-skills.git"
PLUGIN_DIR="${HOME}/.claude/plugins/gxv-skills"

echo "Installing GolemXV skills..."
echo ""

if [ -d "$PLUGIN_DIR" ]; then
    echo "Updating existing installation..."
    cd "$PLUGIN_DIR" && git pull --ff-only
else
    echo "Fresh install..."
    git clone "$REPO" "$PLUGIN_DIR"
fi

echo ""
echo "GolemXV skills installed to: $PLUGIN_DIR"
echo ""
echo "Next steps:"
echo "  1. Set your API key:    export GXV_API_KEY=gxv_your_key_here"
echo "  2. Set server URL:      export GXV_SERVER_URL=https://your-golemxv-server.com"
echo "  3. Restart Claude Code"
echo "  4. Run /gxv:init in your project directory"
echo ""
