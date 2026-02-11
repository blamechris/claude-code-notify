#!/bin/bash
# test-state-transitions.sh -- Tests for the PATCH-based state machine
#
# Verifies that:
#   - PostToolUse transitions: idle→online, permission→approved, approved→online
#   - PostToolUse no-op when state is online/offline/empty
#   - idle_prompt no-op when already idle
#   - idle_busy dedup: same subagent count is suppressed
#   - State file is updated correctly at each transition

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

PROJECT="test-proj-states"
PROJECT_NAME="$PROJECT"

# -- Tests --

# 1. PostToolUse with state=idle and 0 subagents → should transition to online
write_status_state "idle"
write_status_msg_id "msg-001"
rm -f "$THROTTLE_DIR/subagent-count-${PROJECT}"
CURRENT=$(read_status_state)
assert_eq "Pre-condition: state is idle" "idle" "$CURRENT"
# Simulate: PostToolUse handler — mirrors production guard pattern
SUBS=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo 0)
if [ "$SUBS" -gt 0 ]; then :; else write_status_state "online"; fi
assert_eq "idle (0 subs) → online transition" "online" "$(read_status_state)"

# 2. PostToolUse with state=idle_busy and 0 subagents → should transition to online
write_status_state "idle_busy"
echo "0" > "$THROTTLE_DIR/subagent-count-${PROJECT}"
SUBS=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo 0)
if [ "$SUBS" -gt 0 ]; then :; else write_status_state "online"; fi
assert_eq "idle_busy (0 subs) → online transition" "online" "$(read_status_state)"

# 2b. PostToolUse with state=idle_busy and subagents running → no-op
write_status_state "idle_busy"
echo "3" > "$THROTTLE_DIR/subagent-count-${PROJECT}"
SUBS=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo 0)
if [ "$SUBS" -gt 0 ]; then :; else write_status_state "online"; fi
assert_eq "idle_busy (3 subs) stays idle_busy" "idle_busy" "$(read_status_state)"

# 2c. PostToolUse with state=idle and subagents running → no-op
write_status_state "idle"
echo "2" > "$THROTTLE_DIR/subagent-count-${PROJECT}"
SUBS=$(cat "$THROTTLE_DIR/subagent-count-${PROJECT}" 2>/dev/null || echo 0)
if [ "$SUBS" -gt 0 ]; then :; else write_status_state "online"; fi
assert_eq "idle (2 subs) stays idle" "idle" "$(read_status_state)"
rm -f "$THROTTLE_DIR/subagent-count-${PROJECT}"

# 3. PostToolUse with state=permission → should transition to approved
write_status_state "permission"
CURRENT=$(read_status_state)
if [ "$CURRENT" = "permission" ]; then write_status_state "approved"; fi
assert_eq "permission → approved transition" "approved" "$(read_status_state)"

# 4. PostToolUse with state=approved → should transition to online
write_status_state "approved"
CURRENT=$(read_status_state)
if [ "$CURRENT" = "approved" ]; then write_status_state "online"; fi
assert_eq "approved → online transition" "online" "$(read_status_state)"

# 5. PostToolUse with state=online → no-op
write_status_state "online"
CURRENT=$(read_status_state)
# The handler does nothing for online state
SHOULD_NOOP=false
case "$CURRENT" in
    permission|idle|idle_busy|approved) SHOULD_NOOP=false ;;
    *) SHOULD_NOOP=true ;;
esac
assert_eq "online is a no-op for PostToolUse" "true" "$SHOULD_NOOP"

# 6. PostToolUse with state=offline → no-op
write_status_state "offline"
CURRENT=$(read_status_state)
SHOULD_NOOP=false
case "$CURRENT" in
    permission|idle|idle_busy|approved) SHOULD_NOOP=false ;;
    *) SHOULD_NOOP=true ;;
esac
assert_eq "offline is a no-op for PostToolUse" "true" "$SHOULD_NOOP"

# 7. PostToolUse with empty state → no-op
rm -f "$THROTTLE_DIR/status-state-${PROJECT}"
CURRENT=$(read_status_state)
SHOULD_NOOP=false
case "$CURRENT" in
    permission|idle|idle_busy|approved) SHOULD_NOOP=false ;;
    *) SHOULD_NOOP=true ;;
esac
assert_eq "empty state is a no-op for PostToolUse" "true" "$SHOULD_NOOP"

# 8. idle_prompt no-op when already idle
write_status_state "idle"
CURRENT=$(read_status_state)
SHOULD_SKIP=$([ "$CURRENT" = "idle" ] && echo "true" || echo "false")
assert_eq "idle_prompt skipped when already idle" "true" "$SHOULD_SKIP"

# 9. idle_prompt proceeds when state is online
write_status_state "online"
CURRENT=$(read_status_state)
SHOULD_SKIP=$([ "$CURRENT" = "idle" ] && echo "true" || echo "false")
assert_eq "idle_prompt proceeds when state is online" "false" "$SHOULD_SKIP"

# 10. idle_busy dedup: same subagent count is suppressed
LAST_COUNT_FILE="$THROTTLE_DIR/last-idle-count-${PROJECT}"
echo "3" > "$LAST_COUNT_FILE"
SUBAGENTS=3
LAST_COUNT=$(cat "$LAST_COUNT_FILE" 2>/dev/null || echo "")
SHOULD_SUPPRESS=$([ "$SUBAGENTS" = "$LAST_COUNT" ] && echo "true" || echo "false")
assert_eq "Same subagent count suppresses idle_busy" "true" "$SHOULD_SUPPRESS"

# 11. idle_busy dedup: different count proceeds
SUBAGENTS=5
SHOULD_SUPPRESS=$([ "$SUBAGENTS" = "$LAST_COUNT" ] && echo "true" || echo "false")
assert_eq "Different subagent count allows idle_busy" "false" "$SHOULD_SUPPRESS"
rm -f "$LAST_COUNT_FILE"

# 12. State transitions are per-project
write_status_state "permission"
echo "other-state" > "$THROTTLE_DIR/status-state-other-project"
assert_eq "Project state is independent" "permission" "$(read_status_state)"
assert_eq "Other project state is independent" "other-state" "$(cat "$THROTTLE_DIR/status-state-other-project")"
rm -f "$THROTTLE_DIR/status-state-other-project"

# -- Cleanup and summary --

rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}" "$THROTTLE_DIR/subagent-count-${PROJECT}"

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
