#!/bin/bash
# test-integration.sh -- Integration tests for main script event routing
#
# Pipes JSON into claude-notify.sh and verifies state file side effects.
# Uses a mock curl to prevent real Discord API calls.
#
# Verifies that:
#   - SessionStart creates online state and initializes metrics
#   - Notification/idle_prompt transitions to idle
#   - Notification/permission_prompt transitions to permission
#   - PostToolUse detects permission→approved and idle→online transitions
#   - SubagentStart/Stop increments/decrements count
#   - SessionEnd writes offline state and clears files
#   - BG bash tracking via PostToolUse
#   - Unknown notification types are ignored
#   - Empty/missing hook event exits cleanly

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Mock curl setup --
# Creates a mock curl that returns successful Discord API responses
# without making real HTTP calls.

MOCK_BIN="$TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" << 'MOCK_CURL'
#!/bin/bash
# Mock curl: returns successful responses without hitting Discord
BODY_OUT="/dev/stdout"
WRITE_OUT=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        -o) BODY_OUT="${args[$((i+1))]}"; i=$((i+2)) ;;
        -w) WRITE_OUT="${args[$((i+1))]}"; i=$((i+2)) ;;
        -D) touch "${args[$((i+1))]}" 2>/dev/null; i=$((i+2)) ;;
        *) i=$((i+1)) ;;
    esac
done
echo '{"id":"mock-msg-123"}' > "$BODY_OUT"
if [ -n "$WRITE_OUT" ]; then
    printf '%b' "${WRITE_OUT//%\{http_code\}/200}"
fi
MOCK_CURL
chmod +x "$MOCK_BIN/curl"

# Override PATH so mock curl is used (real jq/bash still available)
export PATH="$MOCK_BIN:$PATH"

# -- Test environment --

export CLAUDE_NOTIFY_THROTTLE_DIR="$THROTTLE_DIR"
export CLAUDE_NOTIFY_DIR="$NOTIFY_DIR"
export CLAUDE_NOTIFY_WEBHOOK="https://discord.com/api/webhooks/123456789012345678/test-token-abc123"
# Disable heartbeat to avoid background process interference
export CLAUDE_NOTIFY_HEARTBEAT_INTERVAL=0

# Test project directory (outside any git repo so extract_project_name uses basename)
TEST_PROJECT_DIR="$TEST_TMPDIR/test-integ-proj"
mkdir -p "$TEST_PROJECT_DIR"
PROJECT="test-integ-proj"

# Helper: run main script with JSON input
run_hook() {
    echo "$1" | bash "$MAIN_SCRIPT" 2>/dev/null
    return 0
}

# Helper: clear all state for clean tests
clear_state() {
    rm -f "$THROTTLE_DIR"/*"${PROJECT}"* 2>/dev/null || true
}

# -- Tests --

# 1. SessionStart creates online state
clear_state
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"abc123"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "SessionStart writes online state" "online" "$state"

# 2. SessionStart writes message ID from mock curl
msg_id=$(cat "$THROTTLE_DIR/status-msg-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "SessionStart writes message ID" "mock-msg-123" "$msg_id"

# 3. SessionStart initializes session metrics
tc=$(cat "$THROTTLE_DIR/tool-count-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "SessionStart initializes tool count to 0" "0" "$tc"

ss=$(cat "$THROTTLE_DIR/session-start-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_true "SessionStart writes session-start timestamp" [ "$ss" != "MISSING" ]

# 3b. SessionStart writes session ID for ownership tracking
sid=$(cat "$THROTTLE_DIR/session-id-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "SessionStart writes session ID" "abc123" "$sid"

# 4. Notification/idle_prompt transitions to idle
run_hook '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "idle_prompt writes idle state" "idle" "$state"

# 5. Notification/permission_prompt transitions to permission
run_hook '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow read?","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "permission_prompt writes permission state" "permission" "$state"

# 6. PostToolUse after permission transitions to approved
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "PostToolUse after permission writes approved" "approved" "$state"

# 7. PostToolUse increments tool count
tc=$(cat "$THROTTLE_DIR/tool-count-${PROJECT}" 2>/dev/null || echo "0")
assert_true "PostToolUse increments tool count" [ "$tc" -gt 0 ]

# 8. PostToolUse after approved transitions to online
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Read","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "PostToolUse after approved writes online" "online" "$state"

# 9. PostToolUse after idle transitions to online
run_hook '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "")
assert_eq "idle state set for transition test" "idle" "$state"
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "MISSING")
assert_eq "PostToolUse after idle writes online" "online" "$state"

# 10. SubagentStart increments count
clear_state
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"abc456"}'
run_hook '{"hook_event_name":"SubagentStart","cwd":"'"$TEST_PROJECT_DIR"'"}'
sc=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "SubagentStart increments count to 1" "1" "$sc"

# 11. SubagentStop decrements count
run_hook '{"hook_event_name":"SubagentStop","cwd":"'"$TEST_PROJECT_DIR"'"}'
sc=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "SubagentStop decrements count to 0" "0" "$sc"

# 12. SubagentStop floors at 0
run_hook '{"hook_event_name":"SubagentStop","cwd":"'"$TEST_PROJECT_DIR"'"}'
sc=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "SubagentStop floors count at 0" "0" "$sc"

# 13. SessionEnd clears state files (keeps msg_id)
run_hook '{"hook_event_name":"SessionEnd","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || true)
assert_eq "SessionEnd clears state file" "" "$state"
msg_id=$(cat "$THROTTLE_DIR/status-msg-${PROJECT}" 2>/dev/null || true)
assert_true "SessionEnd preserves msg_id" [ -n "$msg_id" ]

# 14. BG bash tracking via PostToolUse
clear_state
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"abc789"}'
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"sleep 100","run_in_background":true},"cwd":"'"$TEST_PROJECT_DIR"'"}'
bg=$(cat "$THROTTLE_DIR/bg-bash-count-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "BG bash count incremented" "1" "$bg"
peak_bg=$(cat "$THROTTLE_DIR/peak-bg-bash-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "Peak BG bash updated" "1" "$peak_bg"

# 15. Non-bg Bash PostToolUse doesn't increment bg count
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$TEST_PROJECT_DIR"'"}'
bg=$(cat "$THROTTLE_DIR/bg-bash-count-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "Non-bg Bash does not increment bg count" "1" "$bg"

# 16. Unknown notification type is ignored
run_hook '{"hook_event_name":"Notification","notification_type":"unknown_type","cwd":"'"$TEST_PROJECT_DIR"'"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || echo "")
assert_eq "Unknown notification doesn't change state" "online" "$state"

# 17. Empty hook event exits cleanly (no crash)
result=$(echo '{}' | bash "$MAIN_SCRIPT" 2>&1; echo "EXIT:$?")
exit_code=$(echo "$result" | grep -o 'EXIT:[0-9]*' | cut -d: -f2)
assert_eq "Empty hook event exits cleanly" "0" "$exit_code"

# 18. Disabled state prevents processing
clear_state
touch "$NOTIFY_DIR/.disabled"
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"disabled-test"}'
state=$(cat "$THROTTLE_DIR/status-state-${PROJECT}" 2>/dev/null || true)
assert_eq "Disabled state prevents SessionStart" "" "$state"
rm -f "$NOTIFY_DIR/.disabled"

# 19. PostToolUse records last tool name
clear_state
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"tool-test"}'
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"'"$TEST_PROJECT_DIR"'"}'
last_tool=$(cat "$THROTTLE_DIR/last-tool-${PROJECT}" 2>/dev/null || true)
assert_eq "PostToolUse records last tool name" "Edit" "$last_tool"

# 20. Multiple SubagentStarts track peak
clear_state
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$TEST_PROJECT_DIR"'","session_id":"peak-test"}'
run_hook '{"hook_event_name":"SubagentStart","cwd":"'"$TEST_PROJECT_DIR"'"}'
run_hook '{"hook_event_name":"SubagentStart","cwd":"'"$TEST_PROJECT_DIR"'"}'
run_hook '{"hook_event_name":"SubagentStart","cwd":"'"$TEST_PROJECT_DIR"'"}'
peak=$(cat "$THROTTLE_DIR/peak-subagents-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "Peak subagents tracks high-water mark" "3" "$peak"
run_hook '{"hook_event_name":"SubagentStop","cwd":"'"$TEST_PROJECT_DIR"'"}'
peak_after=$(cat "$THROTTLE_DIR/peak-subagents-${PROJECT}" 2>/dev/null || echo "0")
assert_eq "Peak preserved after SubagentStop" "3" "$peak_after"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
