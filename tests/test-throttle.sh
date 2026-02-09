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
if [ -z "${HELPER_FILE:-}" ]; then
    TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_DIR="$(dirname "$TESTS_DIR")"
    export TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-notify-tests.XXXXXX")
    export THROTTLE_DIR="$TEST_TMPDIR/throttle"
    export NOTIFY_DIR="$TEST_TMPDIR/notify-config"
    export CLAUDE_NOTIFY_DIR="$NOTIFY_DIR"
    export MAIN_SCRIPT="$PROJECT_DIR/claude-notify.sh"
    mkdir -p "$THROTTLE_DIR" "$NOTIFY_DIR"
    STANDALONE=1

    # Build helpers inline
    HELPER_FILE="$TEST_TMPDIR/test-helpers.sh"
    cat > "$HELPER_FILE" << 'HELPERS'
pass=0
fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf "  PASS: %s\n" "$desc"
        ((pass++))
    else
        printf "  FAIL: %s (expected '%s', got '%s')\n" "$desc" "$expected" "$actual"
        ((fail++))
    fi
}
assert_true() {
    local desc="$1"; shift
    if "$@"; then printf "  PASS: %s\n" "$desc"; ((pass++))
    else printf "  FAIL: %s (command returned non-zero)\n" "$desc"; ((fail++)); fi
}
assert_false() {
    local desc="$1"; shift
    if "$@"; then printf "  FAIL: %s (command returned zero, expected non-zero)\n" "$desc"; ((fail++))
    else printf "  PASS: %s\n" "$desc"; ((pass++)); fi
}
test_summary() {
    local total=$((pass + fail))
    printf "\n  Results: %d passed, %d failed (out of %d)\n" "$pass" "$fail" "$total"
    [ "$fail" -eq 0 ]
}
HELPERS
fi

source "$HELPER_FILE"

# Extract the throttle_check function from the main script so we can test it
# in isolation without triggering the script's `cat` (stdin read), `exit`,
# or webhook logic.
throttle_check() {
    local lock_file="$THROTTLE_DIR/last-${1}"
    local cooldown="$2"
    if [ -f "$lock_file" ]; then
        local last_sent=$(cat "$lock_file" 2>/dev/null || echo 0)
        local now=$(date +%s)
        [ $(( now - last_sent )) -lt "$cooldown" ] && return 1
    fi
    date +%s > "$lock_file"
    return 0
}

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

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
