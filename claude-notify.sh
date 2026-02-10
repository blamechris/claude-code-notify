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
IDLE_COOLDOWN="${CLAUDE_NOTIFY_IDLE_COOLDOWN:-60}"
PERMISSION_COOLDOWN="${CLAUDE_NOTIFY_PERMISSION_COOLDOWN:-60}"

mkdir -p "$THROTTLE_DIR"

# Load config from .env file (env vars take precedence)
if [ -f "$NOTIFY_DIR/.env" ]; then
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && \
        CLAUDE_NOTIFY_WEBHOOK=$(grep -m1 '^CLAUDE_NOTIFY_WEBHOOK=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_BOT_NAME:-}" ] && \
        CLAUDE_NOTIFY_BOT_NAME=$(grep -m1 '^CLAUDE_NOTIFY_BOT_NAME=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_CLEANUP_OLD:-}" ] && \
        CLAUDE_NOTIFY_CLEANUP_OLD=$(grep -m1 '^CLAUDE_NOTIFY_CLEANUP_OLD=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)

    # Load enhanced context flags
    [ -z "${CLAUDE_NOTIFY_SHOW_SESSION_INFO:-}" ] && \
        CLAUDE_NOTIFY_SHOW_SESSION_INFO=$(grep -m1 '^CLAUDE_NOTIFY_SHOW_SESSION_INFO=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_SHOW_TOOL_INFO:-}" ] && \
        CLAUDE_NOTIFY_SHOW_TOOL_INFO=$(grep -m1 '^CLAUDE_NOTIFY_SHOW_TOOL_INFO=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_SHOW_FULL_PATH:-}" ] && \
        CLAUDE_NOTIFY_SHOW_FULL_PATH=$(grep -m1 '^CLAUDE_NOTIFY_SHOW_FULL_PATH=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)

    # Load color overrides
    [ -z "${CLAUDE_NOTIFY_ONLINE_COLOR:-}" ] && \
        CLAUDE_NOTIFY_ONLINE_COLOR=$(grep -m1 '^CLAUDE_NOTIFY_ONLINE_COLOR=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_OFFLINE_COLOR:-}" ] && \
        CLAUDE_NOTIFY_OFFLINE_COLOR=$(grep -m1 '^CLAUDE_NOTIFY_OFFLINE_COLOR=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_APPROVAL_COLOR:-}" ] && \
        CLAUDE_NOTIFY_APPROVAL_COLOR=$(grep -m1 '^CLAUDE_NOTIFY_APPROVAL_COLOR=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -z "${CLAUDE_NOTIFY_PERMISSION_COLOR:-}" ] && \
        CLAUDE_NOTIFY_PERMISSION_COLOR=$(grep -m1 '^CLAUDE_NOTIFY_PERMISSION_COLOR=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

# Check enabled state (file-based .disabled takes precedence over env var)
if [ -f "$NOTIFY_DIR/.disabled" ] || [ "${CLAUDE_NOTIFY_ENABLED:-}" = "false" ]; then
    exit 0
fi

# -- Dependencies (jq required for JSON parsing) --

command -v jq &>/dev/null || { echo "claude-notify: jq is required (brew install jq)" >&2; exit 1; }

# -- Parse hook input --

read -t 5 -r -d '' INPUT || true
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="${1:-}"
[ -z "$HOOK_EVENT" ] && exit 0

# Extract project name early — needed by SubagentStart/Stop too
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
PROJECT_NAME="unknown"
[ -n "$CWD" ] && PROJECT_NAME=$(basename "$CWD")
PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -cd 'A-Za-z0-9._-')
# Ensure PROJECT_NAME is never empty after sanitization (fixes Issue #38)
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="unknown"

# Extract additional context fields (for optional display)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

# Per-project subagent count file
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# -- Subagent tracking (no webhook needed) --

if [ "$HOOK_EVENT" = "SubagentStart" ]; then
    LOCK="$SUBAGENT_COUNT_FILE.lock"
    while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.01; done
    COUNT=0
    [ -f "$SUBAGENT_COUNT_FILE" ] && COUNT=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
    echo $(( COUNT + 1 )) > "$SUBAGENT_COUNT_FILE"
    rmdir "$LOCK" 2>/dev/null || true
    exit 0
fi

if [ "$HOOK_EVENT" = "SubagentStop" ]; then
    LOCK="$SUBAGENT_COUNT_FILE.lock"
    while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.01; done
    COUNT=0
    [ -f "$SUBAGENT_COUNT_FILE" ] && COUNT=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
    NEW_COUNT=$(( COUNT - 1 ))
    [ "$NEW_COUNT" -lt 0 ] && NEW_COUNT=0
    echo "$NEW_COUNT" > "$SUBAGENT_COUNT_FILE"
    rmdir "$LOCK" 2>/dev/null || true
    exit 0
fi

# -- Session lifecycle tracking --

if [ "$HOOK_EVENT" = "SessionStart" ]; then
    # Validate webhook URL
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0

    # Build "Session Online" notification (green)
    ONLINE_COLOR="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"  # Green #2ECC71
    if ! validate_color "$ONLINE_COLOR"; then
        echo "claude-notify: warning: CLAUDE_NOTIFY_ONLINE_COLOR '$ONLINE_COLOR' is out of range (0-16777215), using default" >&2
        ONLINE_COLOR="3066993"
    fi
    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    BOT_NAME="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

    BASE_FIELDS=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
    EXTRA_FIELDS=$(build_extra_fields)
    SESSION_FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')

    PAYLOAD=$(jq -c -n \
        --arg username "$BOT_NAME" \
        --arg title "🟢 ${PROJECT_NAME} — Session Online" \
        --argjson color "$ONLINE_COLOR" \
        --argjson fields "$SESSION_FIELDS" \
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

    curl -s -o /dev/null \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$CLAUDE_NOTIFY_WEBHOOK" 2>/dev/null || true

    exit 0
fi

if [ "$HOOK_EVENT" = "SessionEnd" ]; then
    # Validate webhook URL
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0

    # Find most recent message ID (check idle, then permission)
    MESSAGE_ID=""
    MESSAGE_ID_FILE=""

    # Try idle message first (most common)
    if [ -f "$THROTTLE_DIR/msg-${PROJECT_NAME}-idle_prompt" ]; then
        MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT_NAME}-idle_prompt" 2>/dev/null || true)
        MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT_NAME}-idle_prompt"
    fi

    # If no idle message, try permission message
    if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt" ]; then
        MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt" 2>/dev/null || true)
        MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt"
    fi

    # If we found a message, PATCH it to offline status
    if [ -n "$MESSAGE_ID" ]; then
        if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
            OFFLINE_COLOR="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"  # Red #E74C3C
            if ! validate_color "$OFFLINE_COLOR"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_OFFLINE_COLOR '$OFFLINE_COLOR' is out of range (0-16777215), using default" >&2
                OFFLINE_COLOR="15158332"
            fi
            TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            BOT_NAME="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

            BASE_FIELDS=$(jq -c -n '[{"name": "Status", "value": "Session ended", "inline": false}]')
            EXTRA_FIELDS=$(build_extra_fields)
            OFFLINE_FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')

            PAYLOAD=$(jq -c -n \
                --arg username "$BOT_NAME" \
                --arg title "🔴 ${PROJECT_NAME} — Session Offline" \
                --argjson color "$OFFLINE_COLOR" \
                --argjson fields "$OFFLINE_FIELDS" \
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

            # PATCH with retry (3 attempts, exponential backoff)
            for attempt in 1 2 3; do
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                    -X PATCH \
                    -H "Content-Type: application/json" \
                    -d "$PAYLOAD" \
                    "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${MESSAGE_ID}")

                if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                    # Success - clean up message ID file
                    if ! rm -f "$MESSAGE_ID_FILE" 2>/dev/null; then
                        echo "claude-notify: warning: failed to delete message ID file: $MESSAGE_ID_FILE" >&2
                    fi
                    exit 0
                fi

                # Retry with backoff
                if [ "$attempt" -lt 3 ]; then
                    sleep $(( attempt * attempt ))
                fi
            done
        fi
    fi

    exit 0
fi

# -- Approval detection (PostToolUse) --
# When a tool executes successfully after a permission prompt, update the Discord message to green

if [ "$HOOK_EVENT" = "PostToolUse" ]; then
    # Check if webhook is configured
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0

    # Check if there's a permission message to update
    # No time limit - some tools can take longer than 5 minutes
    PERMISSION_MSG_FILE="$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt"
    PERMISSION_TIME_FILE="$THROTTLE_DIR/last-permission-${PROJECT_NAME}"

    if [ -f "$PERMISSION_MSG_FILE" ]; then
        MESSAGE_ID=$(cat "$PERMISSION_MSG_FILE" 2>/dev/null)

        if [ -n "$MESSAGE_ID" ]; then
                # Extract and validate webhook ID and token for PATCH endpoint
                if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
                    # Build approval payload (green color)
                    APPROVAL_COLOR="${CLAUDE_NOTIFY_APPROVAL_COLOR:-3066993}"  # Green #2ECC71
                    # Validate approval color is in Discord range (0-16777215)
                    if ! validate_color "$APPROVAL_COLOR"; then
                        echo "claude-notify: warning: CLAUDE_NOTIFY_APPROVAL_COLOR '$APPROVAL_COLOR' is out of range (0-16777215), using default" >&2
                        APPROVAL_COLOR="3066993"
                    fi
                    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                    BOT_NAME="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

                    # Build fields with optional extra context
                    BASE_FIELDS=$(jq -c -n '[{"name": "Status", "value": "Permission granted, tool executed successfully", "inline": false}]')
                    EXTRA_FIELDS=$(build_extra_fields)
                    APPROVAL_FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')

                    PAYLOAD=$(jq -c -n \
                        --arg username "$BOT_NAME" \
                        --arg title "✅ ${PROJECT_NAME} — Permission Approved" \
                        --argjson color "$APPROVAL_COLOR" \
                        --argjson fields "$APPROVAL_FIELDS" \
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

                    # PATCH with retry (3 attempts, exponential backoff)
                    for attempt in 1 2 3; do
                        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                            -X PATCH \
                            -H "Content-Type: application/json" \
                            -d "$PAYLOAD" \
                            "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${MESSAGE_ID}")

                        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                            # Success - clean up the message ID file so we don't re-update
                            if ! rm -f "$PERMISSION_MSG_FILE" 2>/dev/null; then
                                echo "claude-notify: warning: failed to delete permission message ID file: $PERMISSION_MSG_FILE" >&2
                            fi
                            exit 0
                        fi

                        # Rate limited or server error - retry with backoff
                        if [ "$attempt" -lt 3 ]; then
                            sleep $(( attempt * attempt ))  # 1s, 4s
                        fi
                    done
                fi
            fi
        fi

    exit 0
fi

# -- Validate webhook URL (only needed for notification events) --

if [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ]; then
    echo "claude-notify: CLAUDE_NOTIFY_WEBHOOK not set. Run install.sh or set the env var." >&2
    exit 1
fi

# -- Dependencies (curl required for webhook delivery) --

command -v curl &>/dev/null || { echo "claude-notify: curl is required" >&2; exit 1; }

# -- Parse notification fields --

NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)

# -- Color validation (Discord embed colors are 24-bit: 0-16777215) --
validate_color() {
    local color="$1"
    if [ -n "$color" ] && [[ "$color" =~ ^[0-9]+$ ]] && [ "$color" -ge 0 ] && [ "$color" -le 16777215 ]; then
        return 0
    fi
    return 1
}

# -- Project colors (Discord embed sidebar, decimal RGB) --
# Customize these for your projects. Color values are decimal integers.
# Use https://www.spycolor.com to convert hex → decimal.
get_project_color() {
    local project="$1"
    local event_type="${2:-}"

    # Event-type color overrides (takes precedence over project colors)
    if [ -n "$event_type" ]; then
        case "$event_type" in
            permission_prompt)
                # Orange for permission prompts (urgent, needs attention)
                local perm_color="${CLAUDE_NOTIFY_PERMISSION_COLOR:-16753920}"
                if validate_color "$perm_color"; then
                    echo "$perm_color"
                else
                    echo "claude-notify: warning: CLAUDE_NOTIFY_PERMISSION_COLOR '$perm_color' is out of range (0-16777215), using default" >&2
                    echo "16753920"
                fi
                return
                ;;
        esac
    fi

    # Check for user overrides in config file
    if [ -f "$NOTIFY_DIR/colors.conf" ]; then
        local color
        color=$(grep -m1 "^${project}=" "$NOTIFY_DIR/colors.conf" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$color" ]; then
            if validate_color "$color"; then
                echo "$color"
                return
            else
                echo "claude-notify: warning: color for project '$project' is out of range '$color' (0-16777215), using default" >&2
            fi
        fi
    fi

    # Built-in defaults
    case "$project" in
        *)  echo 5793266 ;;  # Default blue #5865F2 (Discord blurple)
    esac
}

# -- Extract and validate webhook ID/token --
# Handles variations in Discord webhook URLs (query params, trailing slashes, fragments)
extract_webhook_id_token() {
    local webhook_url="$1"

    # Extract ID/TOKEN from URL, removing query params and fragments
    local id_token=$(echo "$webhook_url" | jq -R 'split("/webhooks/")[1] | split("?")[0] | split("#")[0] | gsub("/$"; "")' 2>/dev/null || true)

    # Remove jq's JSON quotes if present
    id_token="${id_token%\"}"
    id_token="${id_token#\"}"

    # Validate format: ID (numeric) / TOKEN (alphanumeric, dashes, underscores)
    if [[ "$id_token" =~ ^[0-9]+/[A-Za-z0-9_-]+$ ]]; then
        echo "$id_token"
        return 0
    else
        return 1
    fi
}

# -- Status emoji --
get_status_emoji() {
    case "$1" in
        idle_ready)    echo "🦀" ;;
        idle_busy)     echo "🔄" ;;
        permission)    echo "🔐" ;;
        *)             echo "📝" ;;
    esac
}

# -- Build extra context fields (if enabled) --
build_extra_fields() {
    local extra_fields="[]"

    # Session info (session ID, permission mode)
    if [ "${CLAUDE_NOTIFY_SHOW_SESSION_INFO:-false}" = "true" ]; then
        if [ -n "$SESSION_ID" ]; then
            local short_id="${SESSION_ID:0:8}"
            extra_fields=$(echo "$extra_fields" | jq -c --arg id "$short_id" '. + [{"name": "Session", "value": $id, "inline": true}]')
        fi
        if [ -n "$PERMISSION_MODE" ]; then
            extra_fields=$(echo "$extra_fields" | jq -c --arg mode "$PERMISSION_MODE" '. + [{"name": "Permission Mode", "value": $mode, "inline": true}]')
        fi
    fi

    # Full path (instead of just project name)
    if [ "${CLAUDE_NOTIFY_SHOW_FULL_PATH:-false}" = "true" ] && [ -n "$CWD" ]; then
        extra_fields=$(echo "$extra_fields" | jq -c --arg path "$CWD" '. + [{"name": "Path", "value": $path, "inline": false}]')
    fi

    # Tool info (for permissions)
    if [ "${CLAUDE_NOTIFY_SHOW_TOOL_INFO:-false}" = "true" ] && [ -n "$TOOL_NAME" ]; then
        extra_fields=$(echo "$extra_fields" | jq -c --arg tool "$TOOL_NAME" '. + [{"name": "Tool", "value": $tool, "inline": true}]')

        # Tool input (truncated for safety)
        if [ -n "$TOOL_INPUT" ] && [ "$TOOL_INPUT" != "null" ]; then
            local tool_detail=$(echo "$TOOL_INPUT" | jq -r 'if type == "object" then (.command // .file_path // "...") else . end' 2>/dev/null | head -c 200)
            if [ -n "$tool_detail" ] && [ "$tool_detail" != "null" ]; then
                extra_fields=$(echo "$extra_fields" | jq -c --arg detail "$tool_detail" '. + [{"name": "Command", "value": $detail, "inline": false}]')
            fi
        fi
    fi

    echo "$extra_fields"
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
COLOR=$(get_project_color "$PROJECT_NAME" "$NOTIFICATION_TYPE")
BOT_NAME="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

case "$NOTIFICATION_TYPE" in
    idle_prompt)
        SUBAGENTS=0
        [ -f "$SUBAGENT_COUNT_FILE" ] && SUBAGENTS=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)

        if [ "$SUBAGENTS" -gt 0 ]; then
            # Dedup: suppress if subagent count hasn't changed since last notification
            LAST_COUNT_FILE="$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}"
            LAST_COUNT=""
            [ -f "$LAST_COUNT_FILE" ] && LAST_COUNT=$(cat "$LAST_COUNT_FILE" 2>/dev/null || echo "")
            [ "$SUBAGENTS" = "$LAST_COUNT" ] && exit 0
            # Minimum 15s between subagent-count updates (prevent Discord rate limiting)
            throttle_check "idle-busy-${PROJECT_NAME}" 15 || exit 0
            echo "$SUBAGENTS" > "$LAST_COUNT_FILE"

            EMOJI=$(get_status_emoji "idle_busy")
            TITLE="${EMOJI} ${PROJECT_NAME} — Idle"
            BASE_FIELDS=$(jq -c -n \
                --arg subs "**${SUBAGENTS}** running" \
                '[
                    {"name": "Status",    "value": "Main loop idle, waiting for subagents", "inline": false},
                    {"name": "Subagents", "value": $subs, "inline": true}
                ]')
            EXTRA_FIELDS=$(build_extra_fields)
            FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')
        else
            # Clear last count so next subagent session starts fresh
            rm -f "$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}"
            throttle_check "idle-${PROJECT_NAME}" "$IDLE_COOLDOWN" || exit 0

            EMOJI=$(get_status_emoji "idle_ready")
            TITLE="${EMOJI} ${PROJECT_NAME} — Ready for input"
            BASE_FIELDS=$(jq -c -n \
                '[{"name": "Status", "value": "Waiting for input", "inline": false}]')
            EXTRA_FIELDS=$(build_extra_fields)
            FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')
        fi
        ;;

    permission_prompt)
        throttle_check "permission-${PROJECT_NAME}" "$PERMISSION_COOLDOWN" || exit 0
        EMOJI=$(get_status_emoji "permission")
        TITLE="${EMOJI} ${PROJECT_NAME} — Needs Approval"
        DETAIL=""
        [ -n "$MESSAGE" ] && DETAIL=$(echo "$MESSAGE" | head -c 300)
        BASE_FIELDS=$(jq -c -n \
            --arg detail "$DETAIL" \
            'if $detail != "" then
                [{"name": "Detail", "value": $detail, "inline": false}]
             else [] end')
        EXTRA_FIELDS=$(build_extra_fields)
        FIELDS=$(jq -c -n --argjson base "$BASE_FIELDS" --argjson extra "$EXTRA_FIELDS" '$base + $extra')
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

# Delete old message if cleanup is enabled (but NOT for permission messages - keep audit history)
if [ "${CLAUDE_NOTIFY_CLEANUP_OLD:-false}" = "true" ] && [ "$NOTIFICATION_TYPE" != "permission_prompt" ]; then
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT_NAME}-${NOTIFICATION_TYPE}"
    if [ -f "$MESSAGE_ID_FILE" ]; then
        OLD_MESSAGE_ID=$(cat "$MESSAGE_ID_FILE" 2>/dev/null || true)
        if [ -n "$OLD_MESSAGE_ID" ]; then
            # Extract and validate webhook ID and token from URL for message deletion
            if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
                curl -s -o /dev/null -X DELETE \
                    "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${OLD_MESSAGE_ID}" \
                    2>/dev/null || true
            fi
        fi
    fi
fi

# Send new message and capture response
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$CLAUDE_NOTIFY_WEBHOOK?wait=true")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "204" ] && [ "$HTTP_CODE" != "200" ]; then
    echo "claude-notify: webhook failed with HTTP $HTTP_CODE" >&2
    exit 1
fi

# Save new message ID for future cleanup
if [ "${CLAUDE_NOTIFY_CLEANUP_OLD:-false}" = "true" ] && [ -n "$RESPONSE_BODY" ]; then
    MESSAGE_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null)
    if [ -n "$MESSAGE_ID" ]; then
        MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT_NAME}-${NOTIFICATION_TYPE}"
        echo "$MESSAGE_ID" > "$MESSAGE_ID_FILE"
    fi
fi
