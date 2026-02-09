#!/bin/bash
# run-tests.sh -- Test runner for claude-code-notify
#
# Runs all test-*.sh files in the tests/ directory.
# Sets up a clean, isolated test environment so tests never touch
# real config or throttle state.
#
# Usage:
#   ./tests/run-tests.sh          # Run all tests
#   ./tests/run-tests.sh -v       # Verbose (show each test file name)

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"

# -- Set up isolated test environment --

export TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-notify-tests.XXXXXX")
export THROTTLE_DIR="$TEST_TMPDIR/throttle"
export NOTIFY_DIR="$TEST_TMPDIR/notify-config"
export CLAUDE_NOTIFY_DIR="$NOTIFY_DIR"
export MAIN_SCRIPT="$PROJECT_DIR/claude-notify.sh"

mkdir -p "$THROTTLE_DIR" "$NOTIFY_DIR"

# Prevent any real webhook from being called
export CLAUDE_NOTIFY_WEBHOOK="https://test.example.com/webhook"

# -- Shared assertion helpers --
# These are exported via a helper file that individual tests source.

HELPER_FILE="$TEST_TMPDIR/test-helpers.sh"
cat > "$HELPER_FILE" << 'HELPERS'
# Test assertion helpers -- sourced by each test file.
# Counters are per-file; the runner aggregates totals.

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
    local desc="$1"
    shift
    if "$@"; then
        printf "  PASS: %s\n" "$desc"
        ((pass++))
    else
        printf "  FAIL: %s (command returned non-zero)\n" "$desc"
        ((fail++))
    fi
}

assert_false() {
    local desc="$1"
    shift
    if "$@"; then
        printf "  FAIL: %s (command returned zero, expected non-zero)\n" "$desc"
        ((fail++))
    else
        printf "  PASS: %s\n" "$desc"
        ((pass++))
    fi
}

# Print summary for this test file; sets exit code.
test_summary() {
    local total=$((pass + fail))
    printf "\n  Results: %d passed, %d failed (out of %d)\n" "$pass" "$fail" "$total"
    [ "$fail" -eq 0 ]
}
HELPERS
export HELPER_FILE

# -- Run all test files --

total_pass=0
total_fail=0
total_files=0
failed_files=()

printf "=== claude-code-notify test suite ===\n\n"

for test_file in "$TESTS_DIR"/test-*.sh; do
    [ -f "$test_file" ] || continue
    test_name=$(basename "$test_file" .sh)
    ((total_files++))

    printf "[%s]\n" "$test_name"

    # Run in a subshell so each test gets a fresh environment.
    # Capture output and exit code.
    output=$(bash "$test_file" 2>&1)
    rc=$?

    echo "$output"

    # Extract pass/fail counts from the results line.
    file_pass=$(echo "$output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
    file_fail=$(echo "$output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)

    total_pass=$((total_pass + file_pass))
    total_fail=$((total_fail + file_fail))

    if [ "$rc" -ne 0 ]; then
        failed_files+=("$test_name")
    fi

    printf "\n"
done

# -- Summary --

printf "=== Summary ===\n"
printf "  Files: %d\n" "$total_files"
printf "  Total: %d passed, %d failed\n" "$total_pass" "$total_fail"

if [ "${#failed_files[@]}" -gt 0 ]; then
    printf "  Failed files:\n"
    for f in "${failed_files[@]}"; do
        printf "    - %s\n" "$f"
    done
fi

# -- Cleanup --

rm -rf "$TEST_TMPDIR"

printf "\n"
if [ "$total_fail" -eq 0 ] && [ "$total_files" -gt 0 ]; then
    printf "All tests passed.\n"
    exit 0
else
    printf "Some tests failed.\n"
    exit 1
fi
