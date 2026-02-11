#!/bin/bash
# test-setup.sh -- Shared setup for standalone test execution
#
# Source this at the top of any test-*.sh file when running standalone:
#   [ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/test-setup.sh"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"

export TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-notify-tests.XXXXXX")
export THROTTLE_DIR="$TEST_TMPDIR/throttle"
export NOTIFY_DIR="$TEST_TMPDIR/notify-config"
export CLAUDE_NOTIFY_DIR="$NOTIFY_DIR"
export MAIN_SCRIPT="$PROJECT_DIR/claude-notify.sh"
export LIB_FILE="$PROJECT_DIR/lib/notify-helpers.sh"

mkdir -p "$THROTTLE_DIR" "$NOTIFY_DIR"
STANDALONE=1

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
assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        printf "  PASS: %s\n" "$desc"
        ((pass++))
    else
        printf "  FAIL: %s (pattern '%s' not found in '%s')\n" "$desc" "$pattern" "$actual"
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
export HELPER_FILE
