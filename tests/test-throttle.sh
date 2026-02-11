#!/bin/bash
# test-throttle.sh -- Tests for the throttle_check function
#
# Verifies that:
#   - First call passes (returns 0)
#   - Immediate repeat is throttled (returns 1)
#   - After cooldown expires, call passes again
#   - Different event types throttle independently
#   - Different projects throttle independently

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# -- Tests --

# 1. First call should pass throttle check
assert_true "First call passes throttle" \
    throttle_check "test-event-alpha" 120

# 2. Immediate second call should be throttled
assert_false "Immediate repeat is throttled" \
    throttle_check "test-event-alpha" 120

# 3. After cooldown expires, call should pass again (use 1-second cooldown)
rm -f "$THROTTLE_DIR/last-test-event-expire"
throttle_check "test-event-expire" 1
sleep 1.1
assert_true "Call passes after cooldown expires" \
    throttle_check "test-event-expire" 1

# 4. Different event types should have independent throttles
rm -f "$THROTTLE_DIR/last-test-idle-projectA" "$THROTTLE_DIR/last-test-perm-projectA"
throttle_check "test-idle-projectA" 120  # lock idle
assert_true "Different event type is not throttled" \
    throttle_check "test-perm-projectA" 120

# 5. Different projects should have independent throttles
rm -f "$THROTTLE_DIR/last-test-idle-proj1" "$THROTTLE_DIR/last-test-idle-proj2"
throttle_check "test-idle-proj1" 120  # lock proj1
assert_true "Different project is not throttled" \
    throttle_check "test-idle-proj2" 120

# 6. Verify the lock file is actually created
rm -f "$THROTTLE_DIR/last-test-lockfile"
throttle_check "test-lockfile" 120
assert_true "Lock file is created after throttle_check" \
    test -f "$THROTTLE_DIR/last-test-lockfile"

# 7. Lock file contains a numeric timestamp
content=$(cat "$THROTTLE_DIR/last-test-lockfile")
if [[ "$content" =~ ^[0-9]+$ ]]; then
    printf "  PASS: Lock file contains numeric timestamp\n"
    ((pass++))
else
    printf "  FAIL: Lock file contains '%s', expected numeric timestamp\n" "$content"
    ((fail++))
fi

# 8. Non-numeric cooldown falls back to 30s (still throttles)
rm -f "$THROTTLE_DIR/last-test-bad-cooldown"
throttle_check "test-bad-cooldown" "abc" 2>/dev/null
assert_false "Non-numeric cooldown still throttles (falls back to 30s)" \
    throttle_check "test-bad-cooldown" "abc" 2>/dev/null

# 9. Non-numeric cooldown emits a warning
warning=$(throttle_check "test-warn-cooldown" "xyz" 2>&1 >/dev/null || true)
assert_match "Non-numeric cooldown emits warning" "not numeric" "$warning"

# 10. Corrupt lock file (non-numeric timestamp) doesn't crash
rm -f "$THROTTLE_DIR/last-test-corrupt"
printf 'garbage\n' > "$THROTTLE_DIR/last-test-corrupt"
assert_true "Corrupt lock file doesn't crash throttle_check" \
    throttle_check "test-corrupt" 120

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
