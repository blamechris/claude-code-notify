#!/bin/bash
# test-heartbeat.sh -- Tests for heartbeat helpers and stale detection
#
# Verifies that:
#   - read/write last_state_change round-trips correctly
#   - write_status_state auto-writes last_state_change timestamp
#   - Stale detection: title gets "(stale?)" when state change > threshold
#   - Stale detection: title is clean when state change is recent
#   - clear_status_files removes heartbeat/state-change files

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

PROJECT_NAME="test-proj-heartbeat"
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# Stub build_extra_fields
build_extra_fields() { echo "[]"; }

# -- Helper tests --

# 1. read_last_state_change returns empty when no file
rm -f "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}"
assert_eq "read_last_state_change default is empty" "" "$(read_last_state_change)"

# 2. write/read last_state_change round-trip
write_last_state_change "1700000000"
assert_eq "read_last_state_change reads written value" "1700000000" "$(read_last_state_change)"

# 3. write_status_state auto-writes last_state_change on state transition
rm -f "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}"
rm -f "$THROTTLE_DIR/status-state-${PROJECT_NAME}"
write_status_state "online"
LAST_CHANGE=$(read_last_state_change)
assert_true "write_status_state sets last_state_change on transition" [ -n "$LAST_CHANGE" ]
assert_true "last_state_change is a recent timestamp" [ "$LAST_CHANGE" -gt 1000000000 ]

# 3b. write_status_state does NOT update last_state_change on same-state write
# Write a known old timestamp, then same-state write should NOT overwrite it
write_last_state_change "1700000001"
write_status_state "online"
NEW_CHANGE=$(read_last_state_change)
assert_eq "Same-state write does not update timestamp" "1700000001" "$NEW_CHANGE"

# 3c. write_status_state updates timestamp on actual transition
write_status_state "idle"
TRANSITION_CHANGE=$(read_last_state_change)
assert_true "State transition updates timestamp" [ "$TRANSITION_CHANGE" -gt 1700000001 ]

# 4. clear_status_files removes last-state-change file
write_last_state_change "1700000000"
safe_write_file "$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}" "99999"
clear_status_files
assert_false "last-state-change file removed by clear" [ -f "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}" ]
assert_false "heartbeat-pid file removed by clear" [ -f "$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}" ]

# -- Stale detection tests --

# 5. Title gets "(stale?)" when state is old (> threshold)
CLAUDE_NOTIFY_STALE_THRESHOLD=100
# Set last state change to 200 seconds ago
PAST=$(( $(date +%s) - 200 ))
write_last_state_change "$PAST"
payload=$(build_status_payload "online")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_match "Stale title contains '(stale?)'" "stale\\?" "$title"

# 6. Title is clean when state change is recent
RECENT=$(date +%s)
write_last_state_change "$RECENT"
payload=$(build_status_payload "online")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_false "Recent title does not contain '(stale?)'" grep -q "stale?" <<< "$title"

# 7. Stale detection works for idle state
write_last_state_change "$PAST"
payload=$(build_status_payload "idle")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_match "Stale idle title contains '(stale?)'" "stale\\?" "$title"

# 8. Stale detection works for permission state
payload=$(build_status_payload "permission" "test detail")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_match "Stale permission title contains '(stale?)'" "stale\\?" "$title"

# 9. No stale detection when no last_state_change file
rm -f "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}"
payload=$(build_status_payload "online")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_false "No stale when no state change file" grep -q "stale?" <<< "$title"

# 10. Default stale threshold (18000s) doesn't trigger for recent state
unset CLAUDE_NOTIFY_STALE_THRESHOLD
write_last_state_change "$(date +%s)"
payload=$(build_status_payload "online")
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_false "Default threshold: recent state not stale" grep -q "stale?" <<< "$title"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
