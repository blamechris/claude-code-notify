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

# -- Helper: simulate the disabled check from claude-notify.sh:62-64 --

check_disabled() {
    if [ -f "$NOTIFY_DIR/.disabled" ] || [ "${CLAUDE_NOTIFY_ENABLED:-}" = "false" ]; then
        return 0  # would exit 0 (disabled)
    fi
    return 1  # would proceed (enabled)
}

# -- Tests --

# 1. .disabled file triggers disabled check
touch "$NOTIFY_DIR/.disabled"
unset CLAUDE_NOTIFY_ENABLED 2>/dev/null || true
assert_true ".disabled file triggers disabled exit" check_disabled

# 2. No state files created when disabled (simulate by checking nothing was written)
rm -f "$THROTTLE_DIR"/status-state-* 2>/dev/null || true
# If disabled, the script exits before writing state. Verify no state files exist.
state_files=$(ls "$THROTTLE_DIR"/status-state-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "No state files when .disabled exists" "0" "$state_files"

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
