#!/bin/bash
# claude-notify.sh — Discord notifications for Claude Code sessions
#
# Maintains a single status message per project:
#   SessionStart   → DELETE old + POST  "🟢 Session Online"
#   Agent idle     → DELETE old + POST  "🦀 Ready for input"   (triggers ping)
#   User input     → PATCH               "🟢 Session Online"
#   Permission     → DELETE old + POST  "🔐 Needs Approval"   (triggers ping)
#   User approves  → PATCH               "✅ Permission Approved"
#   Agent works    → PATCH               "🟢 Session Online"
#   SessionEnd     → PATCH               "🔴 Session Offline"
#
# Designed as a Claude Code hook (Notification, SubagentStart/Stop,
# SessionStart/End, PostToolUse).
# See install.sh for setup, or README.md for manual configuration.
#
# Configuration:
#   CLAUDE_NOTIFY_WEBHOOK — Discord webhook URL (required)
#     Set via: environment variable, or ~/.claude-notify/.env file
#
#   CLAUDE_NOTIFY_ENABLED — set to "false" to disable (default: true)
#     Or: touch ~/.claude-notify/.disabled
#
# Project colors are configured in get_project_color() below.

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# -- Configuration --

NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"
THROTTLE_DIR="/tmp/claude-notify"

if ! mkdir -p "$THROTTLE_DIR" 2>/dev/null || [ ! -d "$THROTTLE_DIR" ] || [ ! -w "$THROTTLE_DIR" ]; then
    echo "claude-notify: cannot create or write to $THROTTLE_DIR" >&2
    exit 1
fi

# Load a variable from .env file if not already set via environment
load_env_var() {
    local var_name="$1"
    eval "[ -z \"\${${var_name}:-}\" ]" || return 0
    local val
    val=$(grep -m1 "^${var_name}=" "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$val" ] && eval "${var_name}=\$val" || true
}

# Load config from .env file (env vars take precedence)
if [ -f "$NOTIFY_DIR/.env" ]; then
    load_env_var CLAUDE_NOTIFY_WEBHOOK
    load_env_var CLAUDE_NOTIFY_BOT_NAME
    load_env_var CLAUDE_NOTIFY_SHOW_SESSION_INFO
    load_env_var CLAUDE_NOTIFY_SHOW_TOOL_INFO
    load_env_var CLAUDE_NOTIFY_SHOW_FULL_PATH
    load_env_var CLAUDE_NOTIFY_ONLINE_COLOR
    load_env_var CLAUDE_NOTIFY_OFFLINE_COLOR
    load_env_var CLAUDE_NOTIFY_APPROVAL_COLOR
    load_env_var CLAUDE_NOTIFY_PERMISSION_COLOR
fi

# Check enabled state (file-based .disabled takes precedence over env var)
if [ -f "$NOTIFY_DIR/.disabled" ] || [ "${CLAUDE_NOTIFY_ENABLED:-}" = "false" ]; then
    exit 0
fi

# Validate webhook URL format if set (catches typos/malformed URLs early)
if [ -n "${CLAUDE_NOTIFY_WEBHOOK:-}" ]; then
    if [[ ! "$CLAUDE_NOTIFY_WEBHOOK" =~ ^https://discord\.com/api/webhooks/[0-9]+/ ]] && \
       [[ ! "$CLAUDE_NOTIFY_WEBHOOK" =~ ^https://discordapp\.com/api/webhooks/[0-9]+/ ]]; then
        echo "claude-notify: warning: CLAUDE_NOTIFY_WEBHOOK doesn't look like a Discord webhook URL" >&2
    fi
fi

# -- Dependencies (jq required for JSON parsing) --

command -v jq &>/dev/null || { echo "claude-notify: jq is required (brew install jq)" >&2; exit 1; }

# -- Parse hook input --

INPUT=$(cat 2>/dev/null) || true

# Validate JSON before parsing (catches malformed input early)
if [ -n "$INPUT" ] && ! echo "$INPUT" | jq empty 2>/dev/null; then
    echo "claude-notify: warning: received invalid JSON on stdin" >&2
    INPUT=""
fi

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -z "$HOOK_EVENT" ] && HOOK_EVENT="${1:-}"
[ -z "$HOOK_EVENT" ] && exit 0

# Extract project name early — needed by SubagentStart/Stop too
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
PROJECT_NAME="unknown"
if [ -n "$CWD" ]; then
    # Prefer git repo root name (fixes monorepo paths like chroxy/packages/app → chroxy)
    GIT_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$GIT_ROOT" ]; then
        PROJECT_NAME=$(basename "$GIT_ROOT")
    else
        PROJECT_NAME=$(basename "$CWD")
    fi
fi
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

# -- Helper functions (must be defined before use) --

# Validate Discord color is in range 0-16777215 (24-bit RGB)
validate_color() {
    local color="$1"
    if [ -n "$color" ] && [[ "$color" =~ ^[0-9]+$ ]] && [ "$color" -ge 0 ] && [ "$color" -le 16777215 ]; then
        return 0
    fi
    return 1
}

# Extract and validate webhook ID/token from Discord webhook URL
# Handles variations: query params, trailing slashes, fragments
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

# Build extra context fields for notifications (if enabled via env vars)
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
            local raw_detail=$(echo "$TOOL_INPUT" | jq -r 'if type == "object" then (.command // .file_path // "...") else . end' 2>/dev/null)
            local tool_detail="$raw_detail"
            if [ "${#raw_detail}" -gt 1000 ]; then
                tool_detail="${raw_detail:0:997}..."
            fi
            if [ -n "$tool_detail" ] && [ "$tool_detail" != "null" ]; then
                extra_fields=$(echo "$extra_fields" | jq -c --arg detail "$tool_detail" '. + [{"name": "Command", "value": $detail, "inline": false}]')
            fi
        fi
    fi

    echo "$extra_fields"
}

# -- Safe file write helper --

# Write content to a file, logging a warning on failure.
# Always returns 0 — hook should continue even if state files fail.
# (Returning non-zero under set -euo pipefail would crash the script.)
safe_write_file() {
    local file="$1"
    local content="$2"
    if ! printf '%s\n' "$content" > "$file" 2>/dev/null; then
        echo "claude-notify: warning: failed to write to $file" >&2
    fi
    return 0
}

# -- Status state helpers --

read_status_state() {
    local file="$THROTTLE_DIR/status-state-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_status_state() {
    safe_write_file "$THROTTLE_DIR/status-state-${PROJECT_NAME}" "$1"
}

read_status_msg_id() {
    local file="$THROTTLE_DIR/status-msg-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_status_msg_id() {
    safe_write_file "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" "$1"
}

# Clear status/throttle/subagent files for a project.
# Pass "keep_msg_id" to preserve the Discord message ID
# (SessionEnd needs this so the next SessionStart can delete the offline message).
clear_status_files() {
    local mode="${1:-}"
    if [ "$mode" != "keep_msg_id" ]; then
        rm -f "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" 2>/dev/null || true
    fi
    rm -f "$THROTTLE_DIR/status-state-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/subagent-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-idle-busy-${PROJECT_NAME}" 2>/dev/null || true
}

# -- Project colors (Discord embed sidebar, decimal RGB) --
# Customize these for your projects. Color values are decimal integers.
# Use https://www.spycolor.com to convert hex → decimal.
get_project_color() {
    local project="$1"

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

    # Default: Discord blurple #5865F2
    echo 5793266
}

# -- Build status payload --
# Builds a Discord embed payload for any state in the lifecycle.
build_status_payload() {
    local state="$1"
    local extra="${2:-}"
    local title color fields
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local bot_name="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"
    local extra_fields=$(build_extra_fields)

    case "$state" in
        online)
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_ONLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        idle)
            color=$(get_project_color "$PROJECT_NAME")
            title="🦀 ${PROJECT_NAME} — Ready for input"
            local base=$(jq -c -n '[{"name": "Status", "value": "Waiting for input", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        idle_busy)
            color=$(get_project_color "$PROJECT_NAME")
            title="🔄 ${PROJECT_NAME} — Idle"
            local base=$(jq -c -n \
                --arg subs "**${extra}** running" \
                '[
                    {"name": "Status", "value": "Main loop idle, waiting for subagents", "inline": false},
                    {"name": "Subagents", "value": $subs, "inline": true}
                ]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        permission)
            color="${CLAUDE_NOTIFY_PERMISSION_COLOR:-16753920}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_PERMISSION_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="16753920"
            fi
            title="🔐 ${PROJECT_NAME} — Needs Approval"
            local detail=""
            if [ -n "$extra" ]; then
                if [ "${#extra}" -gt 1000 ]; then
                    detail="${extra:0:997}..."
                else
                    detail="$extra"
                fi
            fi
            local base=$(jq -c -n \
                --arg detail "$detail" \
                'if $detail != "" then
                    [{"name": "Detail", "value": $detail, "inline": false}]
                 else [] end')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        approved)
            color="${CLAUDE_NOTIFY_APPROVAL_COLOR:-3066993}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_APPROVAL_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="✅ ${PROJECT_NAME} — Permission Approved"
            local base=$(jq -c -n '[{"name": "Status", "value": "Permission granted, tool executed successfully", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        offline)
            color="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_OFFLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="15158332"
            fi
            title="🔴 ${PROJECT_NAME} — Session Offline"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session ended", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        *)
            echo "claude-notify: warning: unknown state '$state', defaulting to online" >&2
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then color="3066993"; fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
    esac

    jq -c -n \
        --arg username "$bot_name" \
        --arg title "$title" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --arg ts "$timestamp" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: "Claude Code" },
                timestamp: $ts
            }]
        }'
}

# -- POST / PATCH helpers --

# POST a new status message, save message ID + state
post_status_message() {
    local state="$1"
    local extra="${2:-}"
    local payload=$(build_status_payload "$state" "$extra")

    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$CLAUDE_NOTIFY_WEBHOOK?wait=true" 2>/dev/null || true)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        MESSAGE_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null)
        if [ -n "$MESSAGE_ID" ]; then
            write_status_msg_id "$MESSAGE_ID"
            write_status_state "$state"
        fi
    fi
}

# DELETE old message + POST new one (moves to bottom of channel, triggers ping)
# Used for states the user cares about: idle, permission
repost_status_message() {
    local state="$1"
    local extra="${2:-}"
    local msg_id=$(read_status_msg_id)

    # Delete old message if it exists
    if [ -n "$msg_id" ]; then
        if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
            curl -s -o /dev/null -X DELETE \
                "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${msg_id}" \
                2>/dev/null || true
        fi
    fi

    # POST new message (saves ID + state)
    post_status_message "$state" "$extra"
}

# PATCH an existing status message; self-heals on 404 by falling back to POST
patch_status_message() {
    local state="$1"
    local extra="${2:-}"
    local msg_id=$(read_status_msg_id)

    # No message to PATCH — self-heal by POSTing
    if [ -z "$msg_id" ]; then
        post_status_message "$state" "$extra"
        return
    fi

    local payload=$(build_status_payload "$state" "$extra")

    if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
        for attempt in 1 2 3; do
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -X PATCH \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${msg_id}" 2>/dev/null || true)

            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                write_status_state "$state"
                return
            fi

            # 404 = message deleted externally — self-heal by POSTing
            if [ "$HTTP_CODE" = "404" ]; then
                post_status_message "$state" "$extra"
                return
            fi

            # Rate limited or server error — retry with backoff
            if [ "$attempt" -lt 3 ]; then
                sleep $(( attempt * attempt ))
            fi
        done
    fi
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
    safe_write_file "$lock_file" "$(date +%s)"
    return 0
}

# -- Subagent tracking (no webhook needed) --

if [ "$HOOK_EVENT" = "SubagentStart" ] || [ "$HOOK_EVENT" = "SubagentStop" ]; then
    LOCK="$SUBAGENT_COUNT_FILE.lock"
    # Acquire lock (break stale locks older than 10s)
    LOCK_ATTEMPTS=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        if [ -d "$LOCK" ] && [ $(($(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0))) -gt 10 ]; then
            rmdir "$LOCK" 2>/dev/null || true
        fi
        LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
        if [ "$LOCK_ATTEMPTS" -gt 100 ]; then
            echo "claude-notify: warning: could not acquire subagent lock after 100 attempts, proceeding unlocked" >&2
            break
        fi
        sleep 0.01
    done
    trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

    COUNT=0
    [ -f "$SUBAGENT_COUNT_FILE" ] && COUNT=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)

    if [ "$HOOK_EVENT" = "SubagentStart" ]; then
        safe_write_file "$SUBAGENT_COUNT_FILE" "$(( COUNT + 1 ))"
    else
        NEW_COUNT=$(( COUNT - 1 ))
        [ "$NEW_COUNT" -lt 0 ] && NEW_COUNT=0
        safe_write_file "$SUBAGENT_COUNT_FILE" "$NEW_COUNT"
    fi

    rmdir "$LOCK" 2>/dev/null || true
    trap - EXIT
    exit 0
fi

# -- Session lifecycle --

if [ "$HOOK_EVENT" = "SessionStart" ]; then
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0
    # Delete previous session's offline message (if any) before clean slate
    OLD_MSG_ID=$(read_status_msg_id)
    if [ -n "$OLD_MSG_ID" ]; then
        if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
            curl -s -o /dev/null -X DELETE \
                "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${OLD_MSG_ID}" \
                2>/dev/null || true
        fi
    fi
    clear_status_files
    post_status_message "online"
    exit 0
fi

if [ "$HOOK_EVENT" = "SessionEnd" ]; then
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0
    CURRENT_STATE=$(read_status_state)
    if [ -n "$CURRENT_STATE" ] && [ "$CURRENT_STATE" != "offline" ]; then
        patch_status_message "offline"
    fi
    clear_status_files "keep_msg_id"
    exit 0
fi

# -- Approval detection / state transition (PostToolUse) --

if [ "$HOOK_EVENT" = "PostToolUse" ]; then
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0
    CURRENT_STATE=$(read_status_state)
    case "$CURRENT_STATE" in
        permission)     patch_status_message "approved" ;;
        idle|idle_busy)
            # Only transition to online if no subagents are running.
            # PostToolUse fires for subagent tool use too — don't let
            # subagent activity revert idle/idle_busy back to online.
            SUBS=0
            [ -f "$SUBAGENT_COUNT_FILE" ] && SUBS=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
            [ "$SUBS" -gt 0 ] && exit 0
            patch_status_message "online"
            ;;
        approved)       patch_status_message "online" ;;
        *)              exit 0 ;;  # online/offline/empty = no-op
    esac
    exit 0
fi

# -- Notification handler --

# Check curl before webhook (curl is needed to use the webhook)
command -v curl &>/dev/null || { echo "claude-notify: curl is required" >&2; exit 1; }

[ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && { echo "claude-notify: CLAUDE_NOTIFY_WEBHOOK not set. Run install.sh or set the env var." >&2; exit 1; }

# -- Parse notification fields --

NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null)
MESSAGE=$(echo "$INPUT" | jq -r '.message // empty' 2>/dev/null)

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
            safe_write_file "$LAST_COUNT_FILE" "$SUBAGENTS"

            repost_status_message "idle_busy" "$SUBAGENTS"
        else
            # Clear last count so next subagent session starts fresh
            rm -f "$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}"
            CURRENT_STATE=$(read_status_state)
            # Already idle — no-op
            [ "$CURRENT_STATE" = "idle" ] && exit 0
            repost_status_message "idle"
        fi
        ;;

    permission_prompt)
        repost_status_message "permission" "${MESSAGE:-}"
        ;;

    *)
        # Skip unknown notification types (don't pollute status message)
        exit 0
        ;;
esac
