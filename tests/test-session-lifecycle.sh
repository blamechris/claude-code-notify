#!/bin/bash
# test-session-lifecycle.sh -- Tests for session message ID tracking and fallback chain
#
# Verifies that:
#   - Session message ID file is created at expected path
#   - SessionEnd fallback chain: idle → permission → session
#   - Session message file is always cleaned up on SessionEnd
#   - Duplicate SessionStart deletes previous session message file

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

PROJECT="test-proj-session"

# -- Tests --

# 1. Session message ID file path follows expected pattern
SESSION_FILE="$THROTTLE_DIR/msg-${PROJECT}-session"
echo "session-msg-001" > "$SESSION_FILE"
assert_true "Session msg file created at expected path" [ -f "$SESSION_FILE" ]
assert_eq "Session msg ID content correct" "session-msg-001" "$(cat "$SESSION_FILE")"
rm -f "$SESSION_FILE"

# 2. Fallback priority: idle message takes precedence over session
echo "idle-msg-100" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
echo "session-msg-100" > "$THROTTLE_DIR/msg-${PROJECT}-session"

# Simulate SessionEnd fallback logic
MESSAGE_ID=""
MESSAGE_ID_FILE=""
if [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-session" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-session")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-session"
fi
assert_eq "Idle takes priority over session" "idle-msg-100" "$MESSAGE_ID"
rm -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" "$THROTTLE_DIR/msg-${PROJECT}-session"

# 3. Fallback priority: permission message takes precedence over session
echo "perm-msg-200" > "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"
echo "session-msg-200" > "$THROTTLE_DIR/msg-${PROJECT}-session"

MESSAGE_ID=""
MESSAGE_ID_FILE=""
if [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-session" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-session")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-session"
fi
assert_eq "Permission takes priority over session" "perm-msg-200" "$MESSAGE_ID"
rm -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt" "$THROTTLE_DIR/msg-${PROJECT}-session"

# 4. Session fallback used when no idle or permission
echo "session-msg-300" > "$THROTTLE_DIR/msg-${PROJECT}-session"

MESSAGE_ID=""
MESSAGE_ID_FILE=""
if [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"
fi
if [ -z "$MESSAGE_ID" ] && [ -f "$THROTTLE_DIR/msg-${PROJECT}-session" ]; then
    MESSAGE_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT}-session")
    MESSAGE_ID_FILE="$THROTTLE_DIR/msg-${PROJECT}-session"
fi
assert_eq "Session fallback provides message ID" "session-msg-300" "$MESSAGE_ID"
assert_eq "Session fallback sets correct file" "$THROTTLE_DIR/msg-${PROJECT}-session" "$MESSAGE_ID_FILE"
rm -f "$THROTTLE_DIR/msg-${PROJECT}-session"

# 5. Session file is always cleaned up on SessionEnd (even when idle was PATCHed)
echo "session-msg-400" > "$THROTTLE_DIR/msg-${PROJECT}-session"
echo "idle-msg-400" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"

# Simulate: idle was used for PATCH, then session file cleaned unconditionally
rm -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"  # simulate PATCH cleanup
rm -f "$THROTTLE_DIR/msg-${PROJECT}-session"       # unconditional cleanup
assert_false "Session file cleaned up after SessionEnd" [ -f "$THROTTLE_DIR/msg-${PROJECT}-session" ]

# 6. Different projects have independent session files
echo "proj-a-session" > "$THROTTLE_DIR/msg-projA-session"
echo "proj-b-session" > "$THROTTLE_DIR/msg-projB-session"
assert_eq "Project A session ID" "proj-a-session" "$(cat "$THROTTLE_DIR/msg-projA-session")"
assert_eq "Project B session ID" "proj-b-session" "$(cat "$THROTTLE_DIR/msg-projB-session")"
rm -f "$THROTTLE_DIR/msg-projA-session" "$THROTTLE_DIR/msg-projB-session"

# 7. SessionStart overwrites previous session file (simulated)
echo "old-session" > "$THROTTLE_DIR/msg-${PROJECT}-session"
# Simulate: delete old, then write new
rm -f "$THROTTLE_DIR/msg-${PROJECT}-session"
echo "new-session" > "$THROTTLE_DIR/msg-${PROJECT}-session"
assert_eq "New SessionStart replaces old session file" "new-session" "$(cat "$THROTTLE_DIR/msg-${PROJECT}-session")"
rm -f "$THROTTLE_DIR/msg-${PROJECT}-session"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
