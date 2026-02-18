#!/bin/bash
# test-disabled.sh -- Tests for disabled state (.disabled file and env var)
#
# Verifies that:
#   - .disabled file causes silent exit
#   - CLAUDE_NOTIFY_ENABLED=false causes silent exit
#   - No state files are created when disabled
#
# Tests the guard clause directly (sources the library, not the main script)
# to avoid subprocess/fd issues in the test runner.

set -uo pipefail

[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# check_disabled() is now in the shared library (lib/notify-helpers.sh)

PROJECT_NAME="test-proj-disabled"

# -- Tests --

# 1. .disabled file triggers disabled check
touch "$NOTIFY_DIR/.disabled"
unset CLAUDE_NOTIFY_ENABLED 2>/dev/null || true
assert_true ".disabled file triggers disabled exit" check_disabled

# 2. Guard prevents state writes when disabled
rm -f "$THROTTLE_DIR"/status-state-* 2>/dev/null || true
# Simulate the guard pattern: check_disabled && skip write (like exit 0 in production)
if ! check_disabled; then
    write_status_state "online"
fi
state_files=$(ls "$THROTTLE_DIR"/status-state-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "No state files when .disabled guard active" "0" "$state_files"

# 2b. Verify writes DO happen when enabled (proves test #2 isn't vacuous)
rm -f "$NOTIFY_DIR/.disabled"
unset CLAUDE_NOTIFY_ENABLED 2>/dev/null || true
rm -f "$THROTTLE_DIR"/status-state-* 2>/dev/null || true
if ! check_disabled; then
    write_status_state "online"
fi
state_files=$(ls "$THROTTLE_DIR"/status-state-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "State files written when enabled" "1" "$state_files"
rm -f "$THROTTLE_DIR"/status-state-* 2>/dev/null || true

# Re-disable for subsequent tests
touch "$NOTIFY_DIR/.disabled"
rm -f "$NOTIFY_DIR/.disabled"

# 3. CLAUDE_NOTIFY_ENABLED=false triggers disabled check
export CLAUDE_NOTIFY_ENABLED="false"
assert_true "CLAUDE_NOTIFY_ENABLED=false triggers disabled exit" check_disabled
unset CLAUDE_NOTIFY_ENABLED

# 4. .disabled file takes precedence over CLAUDE_NOTIFY_ENABLED=true
touch "$NOTIFY_DIR/.disabled"
export CLAUDE_NOTIFY_ENABLED="true"
assert_true ".disabled takes precedence over ENABLED=true" check_disabled
rm -f "$NOTIFY_DIR/.disabled"
unset CLAUDE_NOTIFY_ENABLED

# 5. Without .disabled or ENABLED=false, check returns false (enabled)
rm -f "$NOTIFY_DIR/.disabled"
unset CLAUDE_NOTIFY_ENABLED 2>/dev/null || true
assert_false "Enabled by default (no .disabled, no env var)" check_disabled

# 6. CLAUDE_NOTIFY_ENABLED=true does not trigger disabled
export CLAUDE_NOTIFY_ENABLED="true"
assert_false "ENABLED=true does not trigger disabled" check_disabled
unset CLAUDE_NOTIFY_ENABLED

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
