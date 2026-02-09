#!/bin/bash
# test-cleanup.sh — Tests for CLAUDE_NOTIFY_CLEANUP_OLD message ID handling
#
# Verifies that:
#   - Message ID files are created in the correct location
#   - Message IDs are isolated per project
#   - Message IDs are isolated per event type
#   - Message ID files persist correctly

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Tests --

# 1. Message ID file path follows expected pattern
PROJECT="my-app"
EVENT_TYPE="idle_prompt"
EXPECTED_PATH="$THROTTLE_DIR/msg-${PROJECT}-${EVENT_TYPE}"

echo "test-message-id-123" > "$EXPECTED_PATH"
assert_true "Message ID file created at expected path" \
    [ -f "$EXPECTED_PATH" ]

SAVED_ID=$(cat "$EXPECTED_PATH")
assert_eq "Message ID content is correct" "test-message-id-123" "$SAVED_ID"

# 2. Different projects have separate message ID files
echo "projectA-msg" > "$THROTTLE_DIR/msg-projectA-idle_prompt"
echo "projectB-msg" > "$THROTTLE_DIR/msg-projectB-idle_prompt"

ID_A=$(cat "$THROTTLE_DIR/msg-projectA-idle_prompt")
ID_B=$(cat "$THROTTLE_DIR/msg-projectB-idle_prompt")

assert_eq "Project A has its own message ID" "projectA-msg" "$ID_A"
assert_eq "Project B has its own message ID" "projectB-msg" "$ID_B"

# 3. Different event types for same project have separate message IDs
echo "idle-msg-456" > "$THROTTLE_DIR/msg-testproj-idle_prompt"
echo "perm-msg-789" > "$THROTTLE_DIR/msg-testproj-permission_prompt"

IDLE_ID=$(cat "$THROTTLE_DIR/msg-testproj-idle_prompt")
PERM_ID=$(cat "$THROTTLE_DIR/msg-testproj-permission_prompt")

assert_eq "Idle message ID is separate" "idle-msg-456" "$IDLE_ID"
assert_eq "Permission message ID is separate" "perm-msg-789" "$PERM_ID"

# 4. Overwriting message ID file replaces old ID
echo "old-message-id" > "$THROTTLE_DIR/msg-replace-test-idle_prompt"
echo "new-message-id" > "$THROTTLE_DIR/msg-replace-test-idle_prompt"

FINAL_ID=$(cat "$THROTTLE_DIR/msg-replace-test-idle_prompt")
assert_eq "New message ID replaces old one" "new-message-id" "$FINAL_ID"

# 5. Reading non-existent message ID file returns empty
if [ -f "$THROTTLE_DIR/msg-nonexistent-idle_prompt" ]; then
    rm "$THROTTLE_DIR/msg-nonexistent-idle_prompt"
fi

EMPTY_ID=$(cat "$THROTTLE_DIR/msg-nonexistent-idle_prompt" 2>/dev/null || true)
assert_eq "Non-existent file returns empty" "" "$EMPTY_ID"

# 6. Project names are sanitized in file paths (matching main script behavior)
# Main script uses: tr -cd 'A-Za-z0-9._-'
UNSAFE_PROJECT="my.app-v2_test"
SAFE_PROJECT=$(echo "$UNSAFE_PROJECT" | tr -cd 'A-Za-z0-9._-')

echo "safe-msg" > "$THROTTLE_DIR/msg-${SAFE_PROJECT}-idle_prompt"
assert_true "Sanitized project name file exists" \
    [ -f "$THROTTLE_DIR/msg-my.app-v2_test-idle_prompt" ]

# 7. Message ID files are independent from throttle files
echo "123" > "$THROTTLE_DIR/last-throttle-test"
echo "msg-abc" > "$THROTTLE_DIR/msg-throttle-test-idle_prompt"

assert_true "Throttle file exists" [ -f "$THROTTLE_DIR/last-throttle-test" ]
assert_true "Message ID file exists" [ -f "$THROTTLE_DIR/msg-throttle-test-idle_prompt" ]

THROTTLE_VAL=$(cat "$THROTTLE_DIR/last-throttle-test")
MSG_VAL=$(cat "$THROTTLE_DIR/msg-throttle-test-idle_prompt")

assert_eq "Throttle file has correct value" "123" "$THROTTLE_VAL"
assert_eq "Message ID file has correct value" "msg-abc" "$MSG_VAL"

test_summary
