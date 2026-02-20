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
THROTTLE_DIR="${CLAUDE_NOTIFY_THROTTLE_DIR:-/tmp/claude-notify}"

# -- Source shared library (after NOTIFY_DIR/THROTTLE_DIR are set) --

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/notify-helpers.sh"

if ! mkdir -p "$THROTTLE_DIR" 2>/dev/null || [ ! -d "$THROTTLE_DIR" ] || [ ! -w "$THROTTLE_DIR" ]; then
    echo "claude-notify: cannot create or write to $THROTTLE_DIR" >&2
    exit 1
fi
chmod 700 "$THROTTLE_DIR" 2>/dev/null || true

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
    load_env_var CLAUDE_NOTIFY_HEARTBEAT_INTERVAL
    load_env_var CLAUDE_NOTIFY_STALE_THRESHOLD
fi

# Check enabled state (file-based .disabled takes precedence over env var)
check_disabled && exit 0

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

# Read stdin with timeout (portable: timeout may not exist on macOS)
if command -v timeout &>/dev/null; then
    INPUT=$(timeout 5 cat 2>/dev/null) || true
else
    # bash-native fallback for macOS (no coreutils timeout command)
    INPUT=""
    line=""
    while IFS= read -r -t 5 line; do
        INPUT="${INPUT}${INPUT:+$'\n'}${line}"
    done
    # Handle last line without trailing newline (read sets $line then returns non-zero at EOF)
    if [ -n "$line" ]; then
        INPUT="${INPUT}${INPUT:+$'\n'}${line}"
    fi
fi

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

# -- Pre-compute extra context fields (once per invocation) --

EXTRA_FIELDS=$(build_extra_fields "$SESSION_ID" "$PERMISSION_MODE" "$CWD" "$TOOL_NAME" "$TOOL_INPUT")

# -- POST / PATCH helpers --

# POST a new status message, save message ID + state (retries on failure)
post_status_message() {
    local state="$1"
    local extra="${2:-}"
    local ef="${3:-[]}"
    local payload=$(build_status_payload "$state" "$extra" "$ef")
    local resp_headers retry_after

    for attempt in 1 2 3; do
        resp_headers=$(mktemp)
        RESPONSE=$(curl -s -w "\n%{http_code}" -D "$resp_headers" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --config <(printf 'url = "%s"\n' "${CLAUDE_NOTIFY_WEBHOOK}?wait=true") 2>/dev/null || true)

        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            rm -f "$resp_headers"
            MESSAGE_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null)
            if [ -n "$MESSAGE_ID" ]; then
                write_status_msg_id "$MESSAGE_ID"
                write_status_state "$state"
            fi
            return
        fi

        # 429: respect Discord's Retry-After header, then retry
        if [ "$HTTP_CODE" = "429" ]; then
            retry_after=$(grep -i '^retry-after:' "$resp_headers" 2>/dev/null | tr -d '[:space:]' | cut -d: -f2)
            retry_after="${retry_after:-2}"
            [[ "$retry_after" =~ ^[0-9]+\.?[0-9]*$ ]] || retry_after=2
            rm -f "$resp_headers"
            sleep "$retry_after"
            continue
        fi

        rm -f "$resp_headers"
        # Server error — retry with backoff
        if [ "$attempt" -lt 3 ]; then
            sleep $(( attempt * attempt ))
        fi
    done
    echo "claude-notify: warning: POST failed after 3 attempts (last HTTP $HTTP_CODE)" >&2
}

# DELETE old message + POST new one (moves to bottom of channel, triggers ping)
# Used for states the user cares about: idle, permission
repost_status_message() {
    local state="$1"
    local extra="${2:-}"
    local ef="${3:-[]}"
    local msg_id=$(read_status_msg_id)

    # Delete old message if it exists
    if [ -n "$msg_id" ]; then
        if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
            curl -s -o /dev/null -X DELETE \
                --config <(printf 'url = "%s"\n' "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${msg_id}") \
                2>/dev/null || true
        fi
    fi

    # POST new message (saves ID + state)
    post_status_message "$state" "$extra" "$ef"
}

# PATCH an existing status message; self-heals on 404 by falling back to POST
patch_status_message() {
    local state="$1"
    local extra="${2:-}"
    local ef="${3:-[]}"
    local msg_id=$(read_status_msg_id)

    # No message to PATCH — self-heal by POSTing
    if [ -z "$msg_id" ]; then
        post_status_message "$state" "$extra" "$ef"
        return
    fi

    local payload=$(build_status_payload "$state" "$extra" "$ef")

    if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
        local resp_headers retry_after
        for attempt in 1 2 3; do
            resp_headers=$(mktemp)
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -D "$resp_headers" \
                -X PATCH \
                -H "Content-Type: application/json" \
                -d "$payload" \
                --config <(printf 'url = "%s"\n' "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${msg_id}") 2>/dev/null || true)

            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                rm -f "$resp_headers"
                write_status_state "$state"
                return
            fi

            # 404 = message deleted externally — self-heal by POSTing
            if [ "$HTTP_CODE" = "404" ]; then
                rm -f "$resp_headers"
                post_status_message "$state" "$extra" "$ef"
                return
            fi

            # 429: respect Discord's Retry-After header, then retry
            if [ "$HTTP_CODE" = "429" ]; then
                retry_after=$(grep -i '^retry-after:' "$resp_headers" 2>/dev/null | tr -d '[:space:]' | cut -d: -f2)
                retry_after="${retry_after:-2}"
                [[ "$retry_after" =~ ^[0-9]+\.?[0-9]*$ ]] || retry_after=2
                rm -f "$resp_headers"
                sleep "$retry_after"
                continue
            fi

            rm -f "$resp_headers"
            # Server error — retry with backoff
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
        if [ "$LOCK_ATTEMPTS" -ge 100 ]; then
            echo "claude-notify: warning: could not acquire subagent lock after 100 attempts, skipping update" >&2
            exit 0
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
            repost_status_message "idle" "" "$EXTRA_FIELDS"
        else
            # idle_busy needs subagent count passed as extra for the embed
            if [ "$STATUS_STATE" = "idle_busy" ]; then
                patch_status_message "$STATUS_STATE" "$NEW_COUNT" "$EXTRA_FIELDS"
            else
                patch_status_message "$STATUS_STATE" "" "$EXTRA_FIELDS"
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
                --config <(printf 'url = "%s"\n' "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${OLD_MSG_ID}") \
                2>/dev/null || true
        fi
    fi
    # Kill stale heartbeat from previous session BEFORE clear_status_files
    # (clear_status_files removes the PID file we need to read)
    HEARTBEAT_PID_FILE="$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}"
    if [ -f "$HEARTBEAT_PID_FILE" ]; then
        OLD_HB_PID=$(cat "$HEARTBEAT_PID_FILE" 2>/dev/null || true)
        # Verify PID is actually our heartbeat (guards against PID recycling)
        if [ -n "$OLD_HB_PID" ] && kill -0 "$OLD_HB_PID" 2>/dev/null && \
           ps -p "$OLD_HB_PID" -o command= 2>/dev/null | grep -qF "lib/heartbeat.sh"; then
            kill "$OLD_HB_PID" 2>/dev/null || true
        fi
    fi

    clear_status_files
    write_session_start "$(date +%s)"
    # Write session ID for ownership tracking (heartbeat uses this to detect supersession)
    [ -n "$SESSION_ID" ] && write_session_id "$SESSION_ID"
    write_tool_count "0"
    write_peak_subagents "0"
    write_bg_bash_count "0"
    write_peak_bg_bash "0"
    post_status_message "online" "" "$EXTRA_FIELDS"

    # Spawn heartbeat background process
    # Launch heartbeat (passes required env vars via export inheritance)
    export THROTTLE_DIR NOTIFY_DIR PROJECT_NAME SUBAGENT_COUNT_FILE
    export CLAUDE_NOTIFY_WEBHOOK CLAUDE_NOTIFY_HEARTBEAT_INTERVAL CLAUDE_NOTIFY_STALE_THRESHOLD
    export CLAUDE_NOTIFY_BOT_NAME CLAUDE_NOTIFY_ONLINE_COLOR CLAUDE_NOTIFY_OFFLINE_COLOR
    export CLAUDE_NOTIFY_APPROVAL_COLOR CLAUDE_NOTIFY_PERMISSION_COLOR
    # Extra fields context for heartbeat (build_extra_fields reads these via env)
    export SESSION_ID CWD PERMISSION_MODE
    export CLAUDE_NOTIFY_SHOW_SESSION_INFO CLAUDE_NOTIFY_SHOW_FULL_PATH
    nohup bash "$SCRIPT_DIR/lib/heartbeat.sh" "$PROJECT_NAME" </dev/null >/dev/null 2>&1 &
    safe_write_file "$HEARTBEAT_PID_FILE" "$!"

    exit 0
fi

if [ "$HOOK_EVENT" = "SessionEnd" ]; then
    # Kill heartbeat BEFORE webhook check — heartbeat is independent of webhook config
    HEARTBEAT_PID_FILE="$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}"
    if [ -f "$HEARTBEAT_PID_FILE" ]; then
        HB_PID=$(cat "$HEARTBEAT_PID_FILE" 2>/dev/null || true)
        # Verify PID is actually our heartbeat (guards against PID recycling)
        if [ -n "$HB_PID" ] && kill -0 "$HB_PID" 2>/dev/null && \
           ps -p "$HB_PID" -o command= 2>/dev/null | grep -qF "lib/heartbeat.sh"; then
            kill "$HB_PID" 2>/dev/null || true
        fi
        rm -f "$HEARTBEAT_PID_FILE"
    fi

    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0

    CURRENT_STATE=$(read_status_state)
    if [ -n "$CURRENT_STATE" ] && [ "$CURRENT_STATE" != "offline" ]; then
        patch_status_message "offline" "" "$EXTRA_FIELDS"
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
    # Detect background bash launches
    if [ "$TOOL_NAME" = "Bash" ] && [ -n "$TOOL_INPUT" ] && [ "$TOOL_INPUT" != "null" ]; then
        RUN_IN_BG=$(echo "$TOOL_INPUT" | jq -r '.run_in_background // false' 2>/dev/null)
        if [ "$RUN_IN_BG" = "true" ]; then
            BG_COUNT=$(read_bg_bash_count)
            NEW_BG=$(( BG_COUNT + 1 ))
            write_bg_bash_count "$NEW_BG"
            PEAK_BG=$(read_peak_bg_bash)
            if [ "$NEW_BG" -gt "$PEAK_BG" ]; then
                write_peak_bg_bash "$NEW_BG"
            fi
        fi
    fi
    # Read state once then act — no locking needed because Claude Code hooks are
    # invoked sequentially within a session. Concurrent sessions on the same project
    # could theoretically race, but last-writer-wins and self-corrects on next event.
    CURRENT_STATE=$(read_status_state)
    case "$CURRENT_STATE" in
        permission)     patch_status_message "approved" "" "$EXTRA_FIELDS" ;;
        idle|idle_busy)
            # Only transition to online if no subagents or bg bashes are running.
            # PostToolUse fires for subagent tool use too — don't let
            # subagent activity revert idle/idle_busy back to online.
            SUBS=$(read_subagent_count)
            [ "$SUBS" -gt 0 ] && exit 0
            patch_status_message "online" "" "$EXTRA_FIELDS"
            ;;
        approved)       patch_status_message "online" "" "$EXTRA_FIELDS" ;;
        online)
            # Heartbeat: throttled PATCH with updated activity metrics
            if [ "${CLAUDE_NOTIFY_SHOW_ACTIVITY:-false}" = "true" ]; then
                throttle_check "activity-${PROJECT_NAME}" "${CLAUDE_NOTIFY_ACTIVITY_THROTTLE:-30}" || exit 0
                patch_status_message "online" "" "$EXTRA_FIELDS"
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
        BG_BASHES=$(read_bg_bash_count)

        if [ "$SUBAGENTS" -gt 0 ] || [ "$BG_BASHES" -gt 0 ]; then
            if [ "$SUBAGENTS" -gt 0 ]; then
                # Dedup: suppress if subagent count hasn't changed since last notification
                LAST_COUNT_FILE="$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}"
                LAST_COUNT=""
                [ -f "$LAST_COUNT_FILE" ] && LAST_COUNT=$(cat "$LAST_COUNT_FILE" 2>/dev/null || echo "")
                [ "$SUBAGENTS" = "$LAST_COUNT" ] && exit 0
                # Minimum 15s between subagent-count updates (prevent Discord rate limiting)
                throttle_check "idle-busy-${PROJECT_NAME}" 15 || exit 0
                safe_write_file "$LAST_COUNT_FILE" "$SUBAGENTS"

                repost_status_message "idle_busy" "$SUBAGENTS" "$EXTRA_FIELDS"
            else
                # BG bashes only (no subagents) — show idle with bg bash info in status text
                CURRENT_STATE=$(read_status_state)
                [ "$CURRENT_STATE" = "idle" ] && exit 0
                repost_status_message "idle" "" "$EXTRA_FIELDS"
            fi
        else
            # Clear last count so next subagent session starts fresh
            rm -f "$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}"
            CURRENT_STATE=$(read_status_state)
            # Already idle — no-op
            [ "$CURRENT_STATE" = "idle" ] && exit 0
            repost_status_message "idle" "" "$EXTRA_FIELDS"
        fi
        ;;

    permission_prompt)
        repost_status_message "permission" "${MESSAGE:-}" "$EXTRA_FIELDS"
        ;;

    *)
        # Skip unknown notification types (don't pollute status message)
        exit 0
        ;;
esac
