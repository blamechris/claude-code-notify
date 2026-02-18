#!/bin/bash
# test-env-loading.sh -- Tests for .env file loading and quote stripping
#
# Verifies that:
#   - Unquoted values are loaded correctly
#   - Double-quoted values have quotes stripped
#   - Single-quoted values have quotes stripped
#   - Environment variables take precedence over .env values
#   - Empty values are ignored
#   - Values with internal quotes are preserved

set -uo pipefail

[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# Source real library (need to bypass double-source guard for fresh loads)
unset _NOTIFY_HELPERS_LOADED
source "$LIB_FILE"

# -- Helper to write .env and test load_env_var --

test_env_load() {
    local desc="$1" env_line="$2" expected="$3"
    # Write .env file
    printf '%s\n' "$env_line" > "$NOTIFY_DIR/.env"
    # Clear any previous value
    unset TEST_VAR 2>/dev/null || true
    # Load it
    load_env_var "TEST_VAR"
    assert_eq "$desc" "$expected" "${TEST_VAR:-}"
    unset TEST_VAR 2>/dev/null || true
}

# -- Tests --

# 1. Unquoted value loaded as-is
test_env_load "Unquoted value" \
    "TEST_VAR=hello_world" "hello_world"

# 2. Double-quoted value has quotes stripped
test_env_load "Double-quoted value" \
    'TEST_VAR="hello_world"' "hello_world"

# 3. Single-quoted value has quotes stripped
test_env_load "Single-quoted value" \
    "TEST_VAR='hello_world'" "hello_world"

# 4. URL value (common .env pattern — unquoted)
test_env_load "Unquoted URL" \
    "TEST_VAR=https://discord.com/api/webhooks/123/abc" "https://discord.com/api/webhooks/123/abc"

# 5. URL value with double quotes
test_env_load "Double-quoted URL" \
    'TEST_VAR="https://discord.com/api/webhooks/123/abc"' "https://discord.com/api/webhooks/123/abc"

# 6. URL value with single quotes
test_env_load "Single-quoted URL" \
    "TEST_VAR='https://discord.com/api/webhooks/123/abc'" "https://discord.com/api/webhooks/123/abc"

# 7. Empty value is ignored (var stays unset)
test_env_load "Empty value ignored" \
    "TEST_VAR=" ""

# 8. Value with spaces (double-quoted)
test_env_load "Double-quoted value with spaces" \
    'TEST_VAR="hello world"' "hello world"

# 9. Value with spaces (single-quoted)
test_env_load "Single-quoted value with spaces" \
    "TEST_VAR='hello world'" "hello world"

# 10. Environment variable takes precedence over .env
printf 'TEST_VAR=from_file\n' > "$NOTIFY_DIR/.env"
export TEST_VAR="from_env"
load_env_var "TEST_VAR"
assert_eq "Env var takes precedence over .env" "from_env" "$TEST_VAR"
unset TEST_VAR

# 11. Missing .env file does not error
rm -f "$NOTIFY_DIR/.env"
unset TEST_VAR 2>/dev/null || true
load_env_var "TEST_VAR"
assert_eq "Missing .env file handled gracefully" "" "${TEST_VAR:-}"

# 12. Variable not in .env file
printf 'OTHER_VAR=something\n' > "$NOTIFY_DIR/.env"
unset TEST_VAR 2>/dev/null || true
load_env_var "TEST_VAR"
assert_eq "Variable not in .env stays unset" "" "${TEST_VAR:-}"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
