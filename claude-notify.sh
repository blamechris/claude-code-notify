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
# Project colors are configured in ~/.claude-notify/colors.conf.

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# -- Configuration --

NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"
THROTTLE_DIR="/tmp/claude-notify"

# -- Source shared library (after NOTIFY_DIR/THROTTLE_DIR are set) --

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/notify-helpers.sh"

if ! mkdir -p "$THROTTLE_DIR" 2>/dev/null || [ ! -d "$THROTTLE_DIR" ] || [ ! -w "$THROTTLE_DIR" ]; then
    echo "claude-notify: cannot create or write to $THROTTLE_DIR" >&2
    exit 1
fi

# Load config from .env file (env vars take precedence)
if [ -f "$NOTIFY_DIR/.env" ]; then
    load_env_var CLAUDE_NOTIFY_WEBHOOK
    load_env_var CLAUDE_NOTIFY_BOT_NAME
    load_env_var CLAUDE_NOTIFY_SHOW_SESSION_INFO
    load_env_var CLAUDE_NOTIFY_SHOW_TOOL_INFO
    load_env_var CLAUDE_NOTIFY_SHOW_FULL_PATH
    load_env_var CLAUDE_NOTIFY_SHOW_ACTIVITY
    load_env_var CLAUDE_NOTIFY_ACTIVITY_THROTTLE
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
PROJECT_NAME=$(extract_project_name "$INPUT")

# Extract additional context fields (for optional display)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty' 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# Per-project subagent count file
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# -- Build extra context fields for notifications (if enabled via env vars) --
# This stays in the main script because it reads globals (SESSION_ID, CWD, etc.)

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
        # Track peak subagent count (high-water mark)
        NEW_COUNT=$(( COUNT + 1 ))
        PEAK=$(read_peak_subagents)
        if [ "$NEW_COUNT" -gt "$PEAK" ]; then
            write_peak_subagents "$NEW_COUNT"
        fi
    else
        NEW_COUNT=$(( COUNT - 1 ))
        [ "$NEW_COUNT" -lt 0 ] && NEW_COUNT=0
        safe_write_file "$SUBAGENT_COUNT_FILE" "$NEW_COUNT"
    fi

    rmdir "$LOCK" 2>/dev/null || true
    trap - EXIT

    # PATCH the Discord embed with updated subagent count (throttled)
    # Read state once to avoid TOCTOU race between decision and PATCH
    STATUS_STATE="$(read_status_state)"
    if should_patch_subagent_update "$STATUS_STATE" "$NEW_COUNT"; then
        # idle_busy + all agents done → repost as plain idle (triggers ping)
        if [ "$STATUS_STATE" = "idle_busy" ] && [ "$NEW_COUNT" = "0" ]; then
            if [ -n "${CLAUDE_NOTIFY_WEBHOOK:-}" ]; then
                repost_status_message "idle"
            fi
        else
            # idle_busy needs subagent count passed as extra for the embed
            if [ "$STATUS_STATE" = "idle_busy" ]; then
                patch_status_message "$STATUS_STATE" "$NEW_COUNT"
            else
                patch_status_message "$STATUS_STATE"
            fi
        fi
    fi
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
    write_session_start "$(date +%s)"
    write_tool_count "0"
    write_peak_subagents "0"
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
    # Increment tool counter (file write only, no PATCH)
    TOOL_COUNT=$(read_tool_count)
    write_tool_count "$(( TOOL_COUNT + 1 ))"
    # Persist last tool name for activity display
    if [ -n "$TOOL_NAME" ]; then
        write_last_tool "$TOOL_NAME"
    fi
    CURRENT_STATE=$(read_status_state)
    case "$CURRENT_STATE" in
        permission)     patch_status_message "approved" ;;
        idle|idle_busy)
            # Only transition to online if no subagents are running.
            # PostToolUse fires for subagent tool use too — don't let
            # subagent activity revert idle/idle_busy back to online.
            SUBS=$(read_subagent_count)
            [ "$SUBS" -gt 0 ] && exit 0
            patch_status_message "online"
            ;;
        approved)       patch_status_message "online" ;;
        online)
            # Heartbeat: throttled PATCH with updated activity metrics
            if [ "${CLAUDE_NOTIFY_SHOW_ACTIVITY:-false}" = "true" ]; then
                throttle_check "activity-${PROJECT_NAME}" "${CLAUDE_NOTIFY_ACTIVITY_THROTTLE:-30}" || exit 0
                patch_status_message "online"
            fi
            exit 0
            ;;
        *)              exit 0 ;;  # offline/empty = no-op
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
        SUBAGENTS=$(read_subagent_count)

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
