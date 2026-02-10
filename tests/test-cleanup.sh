#!/bin/bash
# test-cleanup.sh — Tests for status file isolation (single message per project)
#
# Verifies that:
#   - Each project has exactly one status-msg file and one status-state file
#   - Different projects have separate status files
#   - Status files overwrite correctly
#   - Status files are independent from throttle/subagent files

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Tests --

# 1. Status message file path follows expected pattern (single file per project)
PROJECT="my-app"
EXPECTED_MSG="$THROTTLE_DIR/status-msg-${PROJECT}"
EXPECTED_STATE="$THROTTLE_DIR/status-state-${PROJECT}"

echo "test-message-id-123" > "$EXPECTED_MSG"
echo "online" > "$EXPECTED_STATE"
assert_true "Status msg file created at expected path" [ -f "$EXPECTED_MSG" ]
assert_true "Status state file created at expected path" [ -f "$EXPECTED_STATE" ]

SAVED_ID=$(cat "$EXPECTED_MSG")
assert_eq "Message ID content is correct" "test-message-id-123" "$SAVED_ID"
SAVED_STATE=$(cat "$EXPECTED_STATE")
assert_eq "State content is correct" "online" "$SAVED_STATE"

# 2. Different projects have separate status files
echo "projectA-msg" > "$THROTTLE_DIR/status-msg-projectA"
echo "projectB-msg" > "$THROTTLE_DIR/status-msg-projectB"

ID_A=$(cat "$THROTTLE_DIR/status-msg-projectA")
ID_B=$(cat "$THROTTLE_DIR/status-msg-projectB")

assert_eq "Project A has its own message ID" "projectA-msg" "$ID_A"
assert_eq "Project B has its own message ID" "projectB-msg" "$ID_B"

# 3. Single file per project (no event-type split)
# There should only be status-msg-PROJECT, NOT status-msg-PROJECT-idle_prompt etc.
echo "single-msg" > "$THROTTLE_DIR/status-msg-testproj"
echo "idle" > "$THROTTLE_DIR/status-state-testproj"
assert_true "Single msg file per project" [ -f "$THROTTLE_DIR/status-msg-testproj" ]
assert_true "Single state file per project" [ -f "$THROTTLE_DIR/status-state-testproj" ]
# Update state (simulating idle→permission transition)
echo "permission" > "$THROTTLE_DIR/status-state-testproj"
assert_eq "State updated in same file" "permission" "$(cat "$THROTTLE_DIR/status-state-testproj")"
assert_eq "Msg ID unchanged during state transition" "single-msg" "$(cat "$THROTTLE_DIR/status-msg-testproj")"

# 4. Overwriting status files replaces old content
echo "old-message-id" > "$THROTTLE_DIR/status-msg-replace-test"
echo "new-message-id" > "$THROTTLE_DIR/status-msg-replace-test"

FINAL_ID=$(cat "$THROTTLE_DIR/status-msg-replace-test")
assert_eq "New message ID replaces old one" "new-message-id" "$FINAL_ID"

# 5. Reading non-existent status files returns empty
EMPTY_ID=$(cat "$THROTTLE_DIR/status-msg-nonexistent" 2>/dev/null || true)
assert_eq "Non-existent msg file returns empty" "" "$EMPTY_ID"

EMPTY_STATE=$(cat "$THROTTLE_DIR/status-state-nonexistent" 2>/dev/null || true)
assert_eq "Non-existent state file returns empty" "" "$EMPTY_STATE"

# 6. Project names are sanitized in file paths (matching main script behavior)
UNSAFE_PROJECT="my.app-v2_test"
SAFE_PROJECT=$(echo "$UNSAFE_PROJECT" | tr -cd 'A-Za-z0-9._-')

echo "safe-msg" > "$THROTTLE_DIR/status-msg-${SAFE_PROJECT}"
assert_true "Sanitized project name file exists" \
    [ -f "$THROTTLE_DIR/status-msg-my.app-v2_test" ]

# 7. Status files are independent from throttle/subagent files
echo "123" > "$THROTTLE_DIR/last-idle-busy-throttle-test"
echo "2" > "$THROTTLE_DIR/subagent-count-throttle-test"
echo "msg-abc" > "$THROTTLE_DIR/status-msg-throttle-test"
echo "idle" > "$THROTTLE_DIR/status-state-throttle-test"

assert_true "Throttle file exists" [ -f "$THROTTLE_DIR/last-idle-busy-throttle-test" ]
assert_true "Subagent file exists" [ -f "$THROTTLE_DIR/subagent-count-throttle-test" ]
assert_true "Status msg file exists" [ -f "$THROTTLE_DIR/status-msg-throttle-test" ]
assert_true "Status state file exists" [ -f "$THROTTLE_DIR/status-state-throttle-test" ]

assert_eq "Throttle file has correct value" "123" "$(cat "$THROTTLE_DIR/last-idle-busy-throttle-test")"
assert_eq "Status msg file has correct value" "msg-abc" "$(cat "$THROTTLE_DIR/status-msg-throttle-test")"
assert_eq "Status state file has correct value" "idle" "$(cat "$THROTTLE_DIR/status-state-throttle-test")"

# -- load_env_var tests --

NOTIFY_DIR="$TEST_TMPDIR/notify-config"
mkdir -p "$NOTIFY_DIR"
cat > "$NOTIFY_DIR/.env" << 'ENVFILE'
CLAUDE_NOTIFY_WEBHOOK=https://discord.com/api/webhooks/123/abc
CLAUDE_NOTIFY_BOT_NAME=Test Bot
ENVFILE

load_env_var() {
    local var_name="$1"
    eval "[ -z \"\${${var_name}:-}\" ]" || return 0
    local val
    val=$(grep -m1 "^${var_name}=" "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    [ -n "$val" ] && eval "${var_name}=\$val"
}

# Loads value from .env when not set
unset CLAUDE_NOTIFY_BOT_NAME 2>/dev/null || true
load_env_var CLAUDE_NOTIFY_BOT_NAME
assert_eq "load_env_var loads from .env" "Test Bot" "${CLAUDE_NOTIFY_BOT_NAME:-}"

# Env var takes precedence over .env
CLAUDE_NOTIFY_BOT_NAME="Override"
load_env_var CLAUDE_NOTIFY_BOT_NAME
assert_eq "Env var takes precedence over .env" "Override" "$CLAUDE_NOTIFY_BOT_NAME"

# Missing var in .env stays empty
unset CLAUDE_NOTIFY_SHOW_SESSION_INFO 2>/dev/null || true
load_env_var CLAUDE_NOTIFY_SHOW_SESSION_INFO
assert_eq "Missing var stays empty" "" "${CLAUDE_NOTIFY_SHOW_SESSION_INFO:-}"

# -- safe_write_file tests --

# Inline the function from main script for testing.
# NOTE: Must stay in sync with safe_write_file() in claude-notify.sh.
safe_write_file() {
    local file="$1"
    local content="$2"
    if ! echo "$content" > "$file" 2>/dev/null; then
        echo "claude-notify: warning: failed to write to $file" >&2
    fi
    return 0
}

# Successful write
WRITE_TEST_FILE="$THROTTLE_DIR/safe-write-test"
safe_write_file "$WRITE_TEST_FILE" "hello"
assert_eq "safe_write_file writes content" "hello" "$(cat "$WRITE_TEST_FILE")"

# Overwrite existing file
safe_write_file "$WRITE_TEST_FILE" "world"
assert_eq "safe_write_file overwrites content" "world" "$(cat "$WRITE_TEST_FILE")"

# Write to non-existent directory returns 0 (graceful, won't crash under set -e)
RESULT=0
safe_write_file "/nonexistent-path/test" "fail" 2>/dev/null || RESULT=$?
assert_eq "safe_write_file returns 0 even on failure" "0" "$RESULT"

# Failure emits warning to stderr
STDERR_OUTPUT=$(safe_write_file "/nonexistent-path/test" "fail" 2>&1 >/dev/null)
assert_match "safe_write_file warns on failure" "warning.*failed to write" "$STDERR_OUTPUT"

# Write empty content
safe_write_file "$WRITE_TEST_FILE" ""
EMPTY_CONTENT=$(cat "$WRITE_TEST_FILE")
assert_eq "safe_write_file handles empty content" "" "$EMPTY_CONTENT"

rm -f "$WRITE_TEST_FILE"

# -- JSON validation tests --

# Valid JSON passes
VALID_JSON='{"hook_event_name": "Notification"}'
assert_true "Valid JSON passes jq validation" bash -c "echo '$VALID_JSON' | jq empty 2>/dev/null"

# Invalid JSON fails
assert_false "Invalid JSON fails jq validation" bash -c "echo 'not json' | jq empty 2>/dev/null"

# Empty input passes (jq empty on empty = ok)
assert_true "Empty input passes jq validation" bash -c "echo '' | jq empty 2>/dev/null"

test_summary
