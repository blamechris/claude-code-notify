#!/bin/bash
# install.sh — Set up claude-code-notify for Claude Code
#
# What this does:
#   1. Creates ~/.claude-notify/ config directory
#   2. Prompts for your Discord webhook URL (if not already configured)
#   3. Adds hooks to ~/.claude/settings.json
#
# Usage:
#   ./install.sh              # Interactive setup
#   ./install.sh --uninstall  # Remove hooks (keeps config)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_SCRIPT="$SCRIPT_DIR/claude-notify.sh"
NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"
SETTINGS_FILE="$HOME/.claude/settings.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { printf "${GREEN}[info]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[warn]${NC} %s\n" "$1"; }
error() { printf "${RED}[error]${NC} %s\n" "$1" >&2; }

# -- Uninstall --

if [ "${1:-}" = "--uninstall" ]; then
    info "Removing claude-code-notify hooks from settings.json..."
    if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
        # Remove hooks that reference claude-notify.sh
        TEMP=$(mktemp)
        jq --arg script "$NOTIFY_SCRIPT" '
            .hooks |= (
                if .Notification then
                    .Notification |= map(select(.hooks | all(.command != $script)))
                    | if .Notification == [] then del(.Notification) else . end
                else . end
                | if .SubagentStart then
                    .SubagentStart |= map(select(.hooks | all(.command != $script)))
                    | if .SubagentStart == [] then del(.SubagentStart) else . end
                else . end
                | if .SubagentStop then
                    .SubagentStop |= map(select(.hooks | all(.command != $script)))
                    | if .SubagentStop == [] then del(.SubagentStop) else . end
                else . end
            )
        ' "$SETTINGS_FILE" > "$TEMP" && mv "$TEMP" "$SETTINGS_FILE"
        info "Hooks removed. Config in $NOTIFY_DIR left intact."
    else
        warn "Could not update settings.json. Remove hooks manually."
    fi
    exit 0
fi

# -- Dependency checks --

if ! command -v jq &>/dev/null; then
    error "jq is required. Install with: brew install jq"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    error "curl is required."
    exit 1
fi

if [ ! -f "$NOTIFY_SCRIPT" ]; then
    error "claude-notify.sh not found at $NOTIFY_SCRIPT"
    error "Run this script from the claude-code-notify repository directory."
    exit 1
fi

# Make script executable
chmod +x "$NOTIFY_SCRIPT"

# -- Config directory --

mkdir -p "$NOTIFY_DIR"
chmod 700 "$NOTIFY_DIR"
info "Config directory: $NOTIFY_DIR"

# -- Webhook URL --

WEBHOOK_URL=""
if [ -f "$NOTIFY_DIR/.env" ]; then
    WEBHOOK_URL=$(grep -m1 '^CLAUDE_NOTIFY_WEBHOOK=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo ""
    echo "Discord webhook URL is required."
    echo "Create one in Discord: Server Settings > Integrations > Webhooks > New Webhook"
    echo ""
    printf "Paste your webhook URL: "
    read -r WEBHOOK_URL

    if [ -z "$WEBHOOK_URL" ]; then
        error "No webhook URL provided. You can set it later in $NOTIFY_DIR/.env"
        echo "CLAUDE_NOTIFY_WEBHOOK=" > "$NOTIFY_DIR/.env"
        chmod 600 "$NOTIFY_DIR/.env"
    else
        echo "CLAUDE_NOTIFY_WEBHOOK=$WEBHOOK_URL" > "$NOTIFY_DIR/.env"
        chmod 600 "$NOTIFY_DIR/.env"
        info "Webhook URL saved to $NOTIFY_DIR/.env"
    fi
else
    info "Webhook URL already configured in $NOTIFY_DIR/.env"
fi

# -- Copy example colors config if none exists --

if [ ! -f "$NOTIFY_DIR/colors.conf" ] && [ -f "$SCRIPT_DIR/colors.conf.example" ]; then
    cp "$SCRIPT_DIR/colors.conf.example" "$NOTIFY_DIR/colors.conf"
    info "Copied colors.conf.example to $NOTIFY_DIR/colors.conf"
fi

# -- Claude Code settings.json --

mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
    info "Created $SETTINGS_FILE"
fi

# Check if hooks already reference our script
if grep -q "$NOTIFY_SCRIPT" "$SETTINGS_FILE" 2>/dev/null; then
    info "Hooks already configured in settings.json. Skipping."
else
    info "Adding hooks to $SETTINGS_FILE..."

    # Build the hook entries
    HOOK_CMD=$(jq -c -n --arg cmd "$NOTIFY_SCRIPT" '{type: "command", command: $cmd}')

    TEMP=$(mktemp)
    jq --argjson hook "$HOOK_CMD" '
        .hooks //= {}
        | .hooks.Notification //= []
        | .hooks.SubagentStart //= []
        | .hooks.SubagentStop //= []
        | .hooks.Notification += [
            { "matcher": "idle_prompt", "hooks": [$hook] },
            { "matcher": "permission_prompt", "hooks": [$hook] }
        ]
        | .hooks.SubagentStart += [{ "hooks": [$hook] }]
        | .hooks.SubagentStop += [{ "hooks": [$hook] }]
    ' "$SETTINGS_FILE" > "$TEMP" && mv "$TEMP" "$SETTINGS_FILE"

    info "Hooks added to settings.json"
fi

# -- Done --

echo ""
info "Installation complete!"
echo ""
echo "  Notifications will fire when Claude Code agents:"
echo "    - Go idle (waiting for input)"
echo "    - Need permission approval"
echo ""
echo "  Configuration:   $NOTIFY_DIR/"
echo "  Project colors:  $NOTIFY_DIR/colors.conf"
echo "  Disable:         touch $NOTIFY_DIR/.disabled"
echo "  Enable:          rm $NOTIFY_DIR/.disabled"
echo "  Uninstall:       ./install.sh --uninstall"
echo ""
