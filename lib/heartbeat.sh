#!/bin/bash
# lib/heartbeat.sh — Periodic background loop that keeps the Discord embed fresh
#
# Spawned by SessionStart, self-terminates when session ends (state offline/empty).
# PATCHes the Discord embed periodically so the footer's elapsed time stays current
# and stale sessions are flagged via build_status_payload's stale detection.
#
# Usage: nohup bash lib/heartbeat.sh <PROJECT_NAME> </dev/null >/dev/null 2>&1 &
#
# Required env vars (inherited from claude-notify.sh via export):
#   THROTTLE_DIR, NOTIFY_DIR, PROJECT_NAME, SUBAGENT_COUNT_FILE,
#   CLAUDE_NOTIFY_WEBHOOK, plus any color/bot name overrides
#
# PID saved to heartbeat-pid-PROJECT for cleanup by SessionEnd.

set -euo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

PROJECT_NAME="${1:-}"
[ -z "$PROJECT_NAME" ] && exit 1

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/notify-helpers.sh"

# Stub build_extra_fields — heartbeat has no session-level context
build_extra_fields() { echo "[]"; }

# PID file for cleanup
PID_FILE="$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}"

# Clean up PID file on exit
cleanup() {
    rm -f "$PID_FILE" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# Write our PID (may already be written by caller, but ensure accuracy)
safe_write_file "$PID_FILE" "$$"

INTERVAL="${CLAUDE_NOTIFY_HEARTBEAT_INTERVAL:-300}"
# Validate interval is numeric and handle special cases
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]]; then
    INTERVAL=300
elif [ "$INTERVAL" -eq 0 ]; then
    # Interval=0 disables heartbeat as documented
    exit 0
elif [ "$INTERVAL" -lt 10 ]; then
    INTERVAL=300
fi

while true; do
    sleep "$INTERVAL"

    # Check if session is still active
    STATE=$(read_status_state)
    if [ -z "$STATE" ] || [ "$STATE" = "offline" ]; then
        exit 0
    fi

    # Check if message ID exists (nothing to PATCH without it)
    MSG_ID=$(read_status_msg_id)
    [ -z "$MSG_ID" ] && continue

    # Check webhook is configured
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && exit 0

    # Build and PATCH the payload for the current state
    # For idle_busy, pass subagent count as extra
    EXTRA=""
    if [ "$STATE" = "idle_busy" ]; then
        EXTRA=$(read_subagent_count)
    fi

    PAYLOAD=$(build_status_payload "$STATE" "$EXTRA")

    if WEBHOOK_ID_TOKEN=$(extract_webhook_id_token "$CLAUDE_NOTIFY_WEBHOOK"); then
        curl -s -o /dev/null -w "" \
            -X PATCH \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" \
            "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${MSG_ID}" 2>/dev/null || true
    fi
done
