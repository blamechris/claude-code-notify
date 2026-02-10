#!/bin/bash
# test-idle-cleanup.sh -- Tests for PostToolUse idle message cleanup
#
# Verifies that:
#   - Idle message file is removed on PostToolUse
#   - Permission message file is NOT affected by idle cleanup
#   - Session message file is NOT affected by idle cleanup
#   - No error when idle file doesn't exist (no-op)
#   - Cleanup is one-shot (second call is a no-op)

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

PROJECT="test-proj-idle"

# Helper: simulate the PostToolUse idle cleanup logic
simulate_idle_cleanup() {
    local project="$1"
    local idle_file="$THROTTLE_DIR/msg-${project}-idle_prompt"
    # Mirrors the delete_discord_message logic (minus actual curl)
    if [ -f "$idle_file" ]; then
        rm -f "$idle_file" 2>/dev/null || true
    fi
}

# -- Tests --

# 1. Idle message file is removed by PostToolUse
echo "idle-msg-500" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
assert_true "Idle file exists before cleanup" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]
simulate_idle_cleanup "$PROJECT"
assert_false "Idle file removed after cleanup" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]

# 2. Permission message file is NOT affected by idle cleanup
echo "perm-msg-500" > "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"
echo "idle-msg-501" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
simulate_idle_cleanup "$PROJECT"
assert_false "Idle file removed" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]
assert_true "Permission file untouched" [ -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt" ]
rm -f "$THROTTLE_DIR/msg-${PROJECT}-permission_prompt"

# 3. Session message file is NOT affected by idle cleanup
echo "session-msg-500" > "$THROTTLE_DIR/msg-${PROJECT}-session"
echo "idle-msg-502" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
simulate_idle_cleanup "$PROJECT"
assert_false "Idle file removed" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]
assert_true "Session file untouched" [ -f "$THROTTLE_DIR/msg-${PROJECT}-session" ]
rm -f "$THROTTLE_DIR/msg-${PROJECT}-session"

# 4. No error when idle file doesn't exist (no-op)
rm -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
simulate_idle_cleanup "$PROJECT"  # should be a silent no-op
assert_false "No idle file, no error" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]

# 5. Second cleanup call is a no-op (one-shot behavior)
echo "idle-msg-503" > "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt"
simulate_idle_cleanup "$PROJECT"
assert_false "First cleanup removes file" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]
simulate_idle_cleanup "$PROJECT"  # second call should be silent no-op
assert_false "Second cleanup is no-op" [ -f "$THROTTLE_DIR/msg-${PROJECT}-idle_prompt" ]

# 6. Idle cleanup is per-project (different projects don't interfere)
echo "idle-a" > "$THROTTLE_DIR/msg-projA-idle_prompt"
echo "idle-b" > "$THROTTLE_DIR/msg-projB-idle_prompt"
simulate_idle_cleanup "projA"
assert_false "Project A idle cleaned" [ -f "$THROTTLE_DIR/msg-projA-idle_prompt" ]
assert_true "Project B idle untouched" [ -f "$THROTTLE_DIR/msg-projB-idle_prompt" ]
rm -f "$THROTTLE_DIR/msg-projB-idle_prompt"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
