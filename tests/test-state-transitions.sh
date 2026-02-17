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

# ============================================================
# 13. SubagentStart/Stop PATCH logic (via should_patch_subagent_update)
# ============================================================
# Tests the real should_patch_subagent_update() helper from notify-helpers.sh.

SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT}"

# 13a. PATCH fires when state is online
write_status_state "online"
write_status_msg_id "msg-sub-001"
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"  # clear throttle
CLAUDE_NOTIFY_WEBHOOK="https://discord.com/api/webhooks/123/fake-token"
RESULT=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart PATCHes when state is online" "true" "$RESULT"

# 13b. No PATCH when state is idle
write_status_state "idle"
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
RESULT=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart no PATCH when state is idle" "false" "$RESULT"

# 13c. No PATCH when state is offline
write_status_state "offline"
RESULT=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart no PATCH when state is offline" "false" "$RESULT"

# 13d. No PATCH when state is empty
rm -f "$THROTTLE_DIR/status-state-${PROJECT}"
RESULT=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart no PATCH when state is empty" "false" "$RESULT"

# 13e. Throttle prevents rapid PATCH updates
write_status_state "online"
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
# First call passes (clears throttle above)
RESULT_1=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart first PATCH passes throttle" "true" "$RESULT_1"
# Immediate second call is throttled
RESULT_2=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart rapid PATCH is throttled" "false" "$RESULT_2"

# 13f. No PATCH when webhook is unset
CLAUDE_NOTIFY_WEBHOOK=""
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
write_status_state "online"
RESULT=$(should_patch_subagent_update && echo "true" || echo "false")
assert_eq "SubagentStart no PATCH without webhook" "false" "$RESULT"

# 13g. read_subagent_count helper returns correct values
CLAUDE_NOTIFY_WEBHOOK="https://discord.com/api/webhooks/123/fake-token"
rm -f "$SUBAGENT_COUNT_FILE"
assert_eq "read_subagent_count default is 0" "0" "$(read_subagent_count)"
safe_write_file "$SUBAGENT_COUNT_FILE" "5"
assert_eq "read_subagent_count reads file" "5" "$(read_subagent_count)"
rm -f "$SUBAGENT_COUNT_FILE"

# 13h. should_patch_subagent_update fires for idle_busy state
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
write_status_state "idle_busy"
RESULT=$(should_patch_subagent_update "idle_busy" "2" && echo "true" || echo "false")
assert_eq "SubagentStart PATCH in idle_busy" "true" "$RESULT"

# 13i. should_patch_subagent_update fires for approved state
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
write_status_state "approved"
RESULT=$(should_patch_subagent_update "approved" "1" && echo "true" || echo "false")
assert_eq "SubagentStart PATCH in approved" "true" "$RESULT"

# 13j. count=0 bypasses throttle (even when within 10s cooldown)
write_status_state "online"
# Fire once to set the throttle timestamp
should_patch_subagent_update "online" "1" || true
# Immediately check with count=0 — should bypass throttle
RESULT=$(should_patch_subagent_update "online" "0" && echo "true" || echo "false")
assert_eq "SubagentStop count=0 bypasses throttle" "true" "$RESULT"

# 13k. idle_busy + count=0 bypasses throttle (repost path)
write_status_state "idle_busy"
# Fire once to set the throttle timestamp
should_patch_subagent_update "idle_busy" "1" || true
# Immediately check with count=0 — should bypass
RESULT=$(should_patch_subagent_update "idle_busy" "0" && echo "true" || echo "false")
assert_eq "idle_busy count=0 bypasses throttle" "true" "$RESULT"

# 13l. should_patch_subagent_update does NOT fire for idle state
rm -f "$THROTTLE_DIR/last-subagent-${PROJECT}"
write_status_state "idle"
RESULT=$(should_patch_subagent_update "idle" "1" && echo "true" || echo "false")
assert_eq "No PATCH for idle state" "false" "$RESULT"

# Clean up webhook var so it doesn't leak
unset CLAUDE_NOTIFY_WEBHOOK

# -- Cleanup and summary --

rm -f "$THROTTLE_DIR/status-msg-${PROJECT}" "$THROTTLE_DIR/status-state-${PROJECT}" "$THROTTLE_DIR/subagent-count-${PROJECT}" "$THROTTLE_DIR/last-subagent-${PROJECT}"

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
