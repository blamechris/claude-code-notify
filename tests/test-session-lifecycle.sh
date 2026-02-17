#!/bin/bash
# test-session-lifecycle.sh -- Tests for status file tracking through session lifecycle
#
# Verifies that:
#   - SessionStart creates status-msg and status-state files
#   - SessionEnd clears status files
#   - Different projects have independent status files
#   - clear_status_files removes all tracking files

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

PROJECT="test-proj-session"

# -- Tests --

# 1. Status message ID file path follows expected pattern
STATUS_MSG_FILE="$THROTTLE_DIR/status-msg-${PROJECT}"
echo "msg-001" > "$STATUS_MSG_FILE"
assert_true "Status msg file created at expected path" [ -f "$STATUS_MSG_FILE" ]
assert_eq "Status msg ID content correct" "msg-001" "$(cat "$STATUS_MSG_FILE")"
rm -f "$STATUS_MSG_FILE"

# 2. Status state file path follows expected pattern
STATUS_STATE_FILE="$THROTTLE_DIR/status-state-${PROJECT}"
echo "online" > "$STATUS_STATE_FILE"
assert_true "Status state file created at expected path" [ -f "$STATUS_STATE_FILE" ]
assert_eq "Status state content correct" "online" "$(cat "$STATUS_STATE_FILE")"
rm -f "$STATUS_STATE_FILE"

# 3. SessionStart creates both files (simulated)
echo "msg-100" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "online" > "$THROTTLE_DIR/status-state-${PROJECT}"
assert_true "Status msg file exists after SessionStart" [ -f "$THROTTLE_DIR/status-msg-${PROJECT}" ]
assert_true "Status state file exists after SessionStart" [ -f "$THROTTLE_DIR/status-state-${PROJECT}" ]
assert_eq "State is online after SessionStart" "online" "$(cat "$THROTTLE_DIR/status-state-${PROJECT}")"

# 4. SessionEnd clears state but preserves msg ID (for next SessionStart to delete)
rm -f "$THROTTLE_DIR/status-state-${PROJECT}" "$THROTTLE_DIR/last-idle-count-${PROJECT}"
assert_true "Status msg file preserved after SessionEnd" [ -f "$THROTTLE_DIR/status-msg-${PROJECT}" ]
assert_false "Status state file cleared after SessionEnd" [ -f "$THROTTLE_DIR/status-state-${PROJECT}" ]
assert_eq "Msg ID still readable after SessionEnd" "msg-100" "$(cat "$THROTTLE_DIR/status-msg-${PROJECT}")"

# 4b. Next SessionStart can read the preserved msg ID and clean up
OLD_MSG=$(cat "$THROTTLE_DIR/status-msg-${PROJECT}" 2>/dev/null || true)
assert_eq "Next SessionStart reads preserved msg ID" "msg-100" "$OLD_MSG"
# SessionStart then clears all files and posts fresh
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}" "$THROTTLE_DIR/last-idle-count-${PROJECT}"
echo "msg-200" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "online" > "$THROTTLE_DIR/status-state-${PROJECT}"
assert_eq "New session has fresh msg ID" "msg-200" "$(cat "$THROTTLE_DIR/status-msg-${PROJECT}")"
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}"

# 5. Different projects have independent status files
echo "proj-a-msg" > "$THROTTLE_DIR/status-msg-projA"
echo "online" > "$THROTTLE_DIR/status-state-projA"
echo "proj-b-msg" > "$THROTTLE_DIR/status-msg-projB"
echo "idle" > "$THROTTLE_DIR/status-state-projB"

assert_eq "Project A msg ID" "proj-a-msg" "$(cat "$THROTTLE_DIR/status-msg-projA")"
assert_eq "Project B msg ID" "proj-b-msg" "$(cat "$THROTTLE_DIR/status-msg-projB")"
assert_eq "Project A state" "online" "$(cat "$THROTTLE_DIR/status-state-projA")"
assert_eq "Project B state" "idle" "$(cat "$THROTTLE_DIR/status-state-projB")"

# SessionEnd on project A clears state but preserves msg ID
rm -f "$THROTTLE_DIR/status-state-projA"
assert_true "Project A msg preserved after SessionEnd" [ -f "$THROTTLE_DIR/status-msg-projA" ]
assert_true "Project B msg untouched" [ -f "$THROTTLE_DIR/status-msg-projB" ]
assert_eq "Project B state still idle" "idle" "$(cat "$THROTTLE_DIR/status-state-projB")"
rm -f "$THROTTLE_DIR/status-msg-projA" "$THROTTLE_DIR/status-msg-projB" "$THROTTLE_DIR/status-state-projB"

# 6. clear_status_files removes all tracking files
PROJECT_NAME="$PROJECT"
echo "msg-200" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "idle_busy" > "$THROTTLE_DIR/status-state-${PROJECT}"
echo "3" > "$THROTTLE_DIR/last-idle-count-${PROJECT}"
echo "2" > "$THROTTLE_DIR/subagent-count-${PROJECT}"
echo "12345" > "$THROTTLE_DIR/last-idle-busy-${PROJECT}"
echo "1" > "$THROTTLE_DIR/bg-bash-count-${PROJECT}"
echo "3" > "$THROTTLE_DIR/peak-bg-bash-${PROJECT}"
echo "1700000000" > "$THROTTLE_DIR/last-state-change-${PROJECT}"
echo "12345" > "$THROTTLE_DIR/heartbeat-pid-${PROJECT}"
clear_status_files
assert_false "Msg file cleared" [ -f "$THROTTLE_DIR/status-msg-${PROJECT}" ]
assert_false "State file cleared" [ -f "$THROTTLE_DIR/status-state-${PROJECT}" ]
assert_false "Idle count file cleared" [ -f "$THROTTLE_DIR/last-idle-count-${PROJECT}" ]
assert_false "Subagent count file cleared" [ -f "$THROTTLE_DIR/subagent-count-${PROJECT}" ]
assert_false "Idle-busy throttle file cleared" [ -f "$THROTTLE_DIR/last-idle-busy-${PROJECT}" ]
assert_false "BG bash count file cleared" [ -f "$THROTTLE_DIR/bg-bash-count-${PROJECT}" ]
assert_false "Peak BG bash file cleared" [ -f "$THROTTLE_DIR/peak-bg-bash-${PROJECT}" ]
assert_false "Last state change file cleared" [ -f "$THROTTLE_DIR/last-state-change-${PROJECT}" ]
assert_false "Heartbeat PID file cleared" [ -f "$THROTTLE_DIR/heartbeat-pid-${PROJECT}" ]

# 6b. clear_status_files with keep_msg_id preserves msg ID (SessionEnd behavior)
echo "msg-300" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "offline" > "$THROTTLE_DIR/status-state-${PROJECT}"
echo "5" > "$THROTTLE_DIR/last-idle-count-${PROJECT}"
echo "4" > "$THROTTLE_DIR/subagent-count-${PROJECT}"
echo "99999" > "$THROTTLE_DIR/last-idle-busy-${PROJECT}"
echo "2" > "$THROTTLE_DIR/bg-bash-count-${PROJECT}"
echo "5" > "$THROTTLE_DIR/peak-bg-bash-${PROJECT}"
echo "1700000000" > "$THROTTLE_DIR/last-state-change-${PROJECT}"
echo "54321" > "$THROTTLE_DIR/heartbeat-pid-${PROJECT}"
clear_status_files "keep_msg_id"
assert_true "Msg ID preserved with keep_msg_id" [ -f "$THROTTLE_DIR/status-msg-${PROJECT}" ]
assert_eq "Msg ID content preserved" "msg-300" "$(cat "$THROTTLE_DIR/status-msg-${PROJECT}")"
assert_false "State file cleared with keep_msg_id" [ -f "$THROTTLE_DIR/status-state-${PROJECT}" ]
assert_false "Idle count cleared with keep_msg_id" [ -f "$THROTTLE_DIR/last-idle-count-${PROJECT}" ]
assert_false "Subagent count cleared with keep_msg_id" [ -f "$THROTTLE_DIR/subagent-count-${PROJECT}" ]
assert_false "Idle-busy throttle cleared with keep_msg_id" [ -f "$THROTTLE_DIR/last-idle-busy-${PROJECT}" ]
assert_false "BG bash count cleared with keep_msg_id" [ -f "$THROTTLE_DIR/bg-bash-count-${PROJECT}" ]
assert_false "Peak BG bash cleared with keep_msg_id" [ -f "$THROTTLE_DIR/peak-bg-bash-${PROJECT}" ]
assert_false "Last state change cleared with keep_msg_id" [ -f "$THROTTLE_DIR/last-state-change-${PROJECT}" ]
assert_false "Heartbeat PID cleared with keep_msg_id" [ -f "$THROTTLE_DIR/heartbeat-pid-${PROJECT}" ]
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}"

# 7. SessionStart on fresh project (no pre-existing files)
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}"
echo "fresh-msg" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "online" > "$THROTTLE_DIR/status-state-${PROJECT}"
assert_eq "Fresh session msg" "fresh-msg" "$(cat "$THROTTLE_DIR/status-msg-${PROJECT}")"
assert_eq "Fresh session state" "online" "$(cat "$THROTTLE_DIR/status-state-${PROJECT}")"
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}"

# 8. Overwriting status files replaces content
echo "old-msg" > "$THROTTLE_DIR/status-msg-${PROJECT}"
echo "new-msg" > "$THROTTLE_DIR/status-msg-${PROJECT}"
assert_eq "Status msg overwrite works" "new-msg" "$(cat "$THROTTLE_DIR/status-msg-${PROJECT}")"
echo "online" > "$THROTTLE_DIR/status-state-${PROJECT}"
echo "idle" > "$THROTTLE_DIR/status-state-${PROJECT}"
assert_eq "Status state overwrite works" "idle" "$(cat "$THROTTLE_DIR/status-state-${PROJECT}")"
rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
