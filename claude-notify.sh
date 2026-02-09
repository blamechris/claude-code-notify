#!/bin/bash
# claude-notify.sh — Discord notifications for Claude Code sessions
#
# Sends color-coded Discord embeds when Claude Code agents:
#   - Go idle (waiting for input)
#   - Need permission approval
#   - Have subagents running in the background
#
# Designed as a Claude Code hook (Notification, SubagentStart, SubagentStop).
# See install.sh for setup, or README.md for manual configuration.
#
# Configuration:
#   CLAUDE_NOTIFY_WEBHOOK — Discord webhook URL (required)
#     Set via: environment variable, or ~/.claude-notify/.env file
#
#   CLAUDE_NOTIFY_ENABLED — set to "false" to disable (default: true)
#     Or: rm ~/.claude-notify/.enabled
#
# Project colors are configured in get_project_color() below.

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# -- Configuration --

NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"
THROTTLE_DIR="/tmp/claude-notify"
IDLE_COOLDOWN="${CLAUDE_NOTIFY_IDLE_COOLDOWN:-120}"
PERMISSION_COOLDOWN="${CLAUDE_NOTIFY_PERMISSION_COOLDOWN:-60}"

mkdir -p "$THROTTLE_DIR"

# Load webhook URL: env var > .env file
if [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && [ -f "$NOTIFY_DIR/.env" ]; then
    CLAUDE_NOTIFY_WEBHOOK=$(grep -m1 '^CLAUDE_NOTIFY_WEBHOOK=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

# Check enabled state
if [ "${CLAUDE_NOTIFY_ENABLED:-}" = "false" ]; then
    exit 0
fi
if [ -f "$NOTIFY_DIR/.disabled" ]; then
    exit 0
fi

# -- Parse hook input --

INPUT=$(cat)
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="${1:-}"
[ -z "$HOOK_EVENT" ] && exit 0

# Extract project name early — needed by SubagentStart/Stop too
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
PROJECT_NAME="unknown"
[ -n "$CWD" ] && PROJECT_NAME=$(basename "$CWD")

# Per-project subagent count file
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# -- Subagent tracking (no webhook needed) --

if [ "$HOOK_EVENT" = "SubagentStart" ]; then
    COUNT=0
    [ -f "$SUBAGENT_COUNT_FILE" ] && COUNT=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
    echo $(( COUNT + 1 )) > "$SUBAGENT_COUNT_FILE"
    exit 0
fi

if [ "$HOOK_EVENT" = "SubagentStop" ]; then
    COUNT=0
    [ -f "$SUBAGENT_COUNT_FILE" ] && COUNT=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
    NEW_COUNT=$(( COUNT - 1 ))
    [ "$NEW_COUNT" -lt 0 ] && NEW_COUNT=0
    echo "$NEW_COUNT" > "$SUBAGENT_COUNT_FILE"
    exit 0
fi

# -- Validate webhook URL (only needed for notification events) --

if [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ]; then
    echo "claude-notify: CLAUDE_NOTIFY_WEBHOOK not set. Run install.sh or set the env var." >&2
    exit 1
fi

# -- Dependencies --

command -v jq &>/dev/null || { echo "claude-notify: jq is required (brew install jq)" >&2; exit 1; }
command -v curl &>/dev/null || { echo "claude-notify: curl is required" >&2; exit 1; }

# -- Parse notification fields --

NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)

# -- Project colors (Discord embed sidebar, decimal RGB) --
# Customize these for your projects. Color values are decimal integers.
# Use https://www.spycolor.com to convert hex → decimal.
get_project_color() {
    # Check for user overrides in config file
    if [ -f "$NOTIFY_DIR/colors.conf" ]; then
        local color
        color=$(grep -m1 "^${1}=" "$NOTIFY_DIR/colors.conf" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$color" ]; then
            echo "$color"
            return
        fi
    fi

    # Built-in defaults
    case "$1" in
        *)  echo 5793266 ;;  # Default blue #5865F2 (Discord blurple)
    esac
}

# -- Status emoji --
get_status_emoji() {
    case "$1" in
        idle_ready)    echo "🟢" ;;
        idle_busy)     echo "🔄" ;;
        permission)    echo "🔐" ;;
        *)             echo "📝" ;;
    esac
}

# -- Throttle helper --
throttle_check() {
    local lock_file="$THROTTLE_DIR/last-${1}"
    local cooldown="$2"
    if [ -f "$lock_file" ]; then
        local last_sent=$(cat "$lock_file" 2>/dev/null || echo 0)
        local now=$(date +%s)
        [ $(( now - last_sent )) -lt "$cooldown" ] && return 1
    fi
    date +%s > "$lock_file"
    return 0
}

# -- Build notification --

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COLOR=$(get_project_color "$PROJECT_NAME")
BOT_NAME="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

case "$NOTIFICATION_TYPE" in
    idle_prompt)
        throttle_check "idle-${PROJECT_NAME}" "$IDLE_COOLDOWN" || exit 0
        SUBAGENTS=0
        [ -f "$SUBAGENT_COUNT_FILE" ] && SUBAGENTS=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)

        if [ "$SUBAGENTS" -gt 0 ]; then
            EMOJI=$(get_status_emoji "idle_busy")
            TITLE="${EMOJI} ${PROJECT_NAME} — Idle"
            FIELDS=$(jq -c -n \
                --arg subs "**${SUBAGENTS}** running" \
                '[
                    {"name": "Status",    "value": "Main loop idle, waiting for subagents", "inline": false},
                    {"name": "Subagents", "value": $subs, "inline": true}
                ]')
        else
            EMOJI=$(get_status_emoji "idle_ready")
            TITLE="${EMOJI} ${PROJECT_NAME} — Ready for input"
            FIELDS=$(jq -c -n \
                '[{"name": "Status", "value": "Waiting for input", "inline": false}]')
        fi
        ;;

    permission_prompt)
        throttle_check "permission-${PROJECT_NAME}" "$PERMISSION_COOLDOWN" || exit 0
        EMOJI=$(get_status_emoji "permission")
        TITLE="${EMOJI} ${PROJECT_NAME} — Needs Approval"
        DETAIL=""
        [ -n "$MESSAGE" ] && DETAIL=$(echo "$MESSAGE" | head -c 300)
        FIELDS=$(jq -c -n \
            --arg detail "$DETAIL" \
            'if $detail != "" then
                [{"name": "Detail", "value": $detail, "inline": false}]
             else [] end')
        ;;

    *)
        throttle_check "other-${PROJECT_NAME}" "$IDLE_COOLDOWN" || exit 0
        EMOJI=$(get_status_emoji "other")
        TITLE="${EMOJI} ${PROJECT_NAME} — ${NOTIFICATION_TYPE:-notification}"
        FIELDS="[]"
        ;;
esac

# -- Send Discord webhook --

PAYLOAD=$(jq -c -n \
    --arg username "$BOT_NAME" \
    --arg title "$TITLE" \
    --argjson color "$COLOR" \
    --argjson fields "$FIELDS" \
    --arg ts "$TIMESTAMP" \
    '{
        username: $username,
        embeds: [{
            title: $title,
            color: $color,
            fields: $fields,
            footer: { text: "Claude Code" },
            timestamp: $ts
        }]
    }')

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$CLAUDE_NOTIFY_WEBHOOK")

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    echo "claude-notify: webhook failed with HTTP $HTTP_CODE" >&2
    exit 1
fi
