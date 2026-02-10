#!/bin/bash
# test-notification-cleanup-auto.sh
# Non-interactive version for automated testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/claude-notify.sh"

# Test configuration
export CLAUDE_NOTIFY_CLEANUP_OLD=true
export CLAUDE_NOTIFY_ENABLED=true
# Use very short cooldowns for testing (normally 60 seconds)
export CLAUDE_NOTIFY_IDLE_COOLDOWN=3
export CLAUDE_NOTIFY_PERMISSION_COOLDOWN=3

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

# Helper function to run a test
run_test() {
    local test_name="$1"
    local test_command="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${YELLOW}[TEST $TESTS_RUN]${NC} $test_name"

    if eval "$test_command"; then
        echo -e "${GREEN}✓ PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}"
    fi
}

# Helper to send notification event
send_notification() {
    local project="$1"
    local event_type="$2"
    local extra_json="${3:-}"

    local json="{\"hook_event_name\":\"Notification\",\"notification_type\":\"$event_type\",\"cwd\":\"$project\"$extra_json}"
    echo "$json" | bash "$HOOK_SCRIPT"
}

# Helper to check if message ID file exists
check_message_id_exists() {
    local project_name="$1"
    local event_type="$2"
    local msg_file="/tmp/claude-notify/msg-${project_name}-${event_type}"

    [ -f "$msg_file" ] && [ -s "$msg_file" ]
}

# Helper to get message ID
get_message_id() {
    local project_name="$1"
    local event_type="$2"
    local msg_file="/tmp/claude-notify/msg-${project_name}-${event_type}"

    if [ -f "$msg_file" ]; then
        cat "$msg_file"
    else
        echo ""
    fi
}

# Clean up test state before starting
cleanup_test_state() {
    rm -f /tmp/claude-notify/msg-test-proj-*
    rm -f /tmp/claude-notify/last-idle-test-proj-*
    rm -f /tmp/claude-notify/last-permission-test-proj-*
    rm -f /tmp/claude-notify/subagent-count-test-proj-*
    rm -f /tmp/claude-notify/last-idle-count-test-proj-*
}

echo "========================================"
echo "Notification Cleanup Behavior Tests"
echo "========================================"
echo ""
echo "Testing message replacement behavior:"
echo "  ✓ Same project + event → replaces"
echo "  ✓ Different projects → separate"
echo "  ✓ Different events → separate"
echo ""

cleanup_test_state

# TEST 1: Same project, same event type (should replace)
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}TEST CATEGORY: Message Replacement${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

run_test "Same project + event should store message ID" '
    send_notification "/tmp/test-proj-a" "idle_prompt" && \
    sleep 2 && \
    check_message_id_exists "test-proj-a" "idle_prompt"
'

# Store first message ID
FIRST_MSG_ID=$(get_message_id "test-proj-a" "idle_prompt")
echo "  First message ID: $FIRST_MSG_ID"

run_test "Second message to same project + event should update message ID" '
    sleep 4 && \
    send_notification "/tmp/test-proj-a" "idle_prompt" && \
    sleep 2 && \
    SECOND_MSG_ID=$(get_message_id "test-proj-a" "idle_prompt") && \
    [ "$SECOND_MSG_ID" != "$FIRST_MSG_ID" ]
'

SECOND_MSG_ID=$(get_message_id "test-proj-a" "idle_prompt")
echo "  Second message ID: $SECOND_MSG_ID"
echo ""
echo -e "${BLUE}→ Discord check: Should see ONE message for test-proj-a${NC}"
echo -e "${BLUE}  (First message should be deleted)${NC}"

# TEST 2: Different projects (should NOT replace)
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}TEST CATEGORY: Project Isolation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

cleanup_test_state

run_test "Message to project B should have its own message ID" '
    send_notification "/tmp/test-proj-b" "idle_prompt" && \
    sleep 2 && \
    check_message_id_exists "test-proj-b" "idle_prompt"
'

run_test "Message to project C should have separate message ID" '
    sleep 2 && \
    send_notification "/tmp/test-proj-c" "idle_prompt" && \
    sleep 2 && \
    check_message_id_exists "test-proj-c" "idle_prompt"
'

PROJ_B_MSG=$(get_message_id "test-proj-b" "idle_prompt")
PROJ_C_MSG=$(get_message_id "test-proj-c" "idle_prompt")

run_test "Different projects should have different message IDs" '
    [ -n "$PROJ_B_MSG" ] && [ -n "$PROJ_C_MSG" ] && [ "$PROJ_B_MSG" != "$PROJ_C_MSG" ]
'

echo "  Project B message ID: $PROJ_B_MSG"
echo "  Project C message ID: $PROJ_C_MSG"
echo ""
echo -e "${BLUE}→ Discord check: Should see TWO messages${NC}"
echo -e "${BLUE}  (One for test-proj-b, one for test-proj-c)${NC}"

# TEST 3: Same project, different event types (should NOT replace)
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}TEST CATEGORY: Event Type Isolation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

cleanup_test_state

run_test "Idle event should create message ID for idle_prompt" '
    send_notification "/tmp/test-proj-d" "idle_prompt" && \
    sleep 2 && \
    check_message_id_exists "test-proj-d" "idle_prompt"
'

run_test "Permission event should create separate message ID for permission_prompt" '
    sleep 2 && \
    send_notification "/tmp/test-proj-d" "permission_prompt" ",\"message\":\"Test permission\"" && \
    sleep 2 && \
    check_message_id_exists "test-proj-d" "permission_prompt"
'

IDLE_MSG=$(get_message_id "test-proj-d" "idle_prompt")
PERM_MSG=$(get_message_id "test-proj-d" "permission_prompt")

run_test "Different event types should have different message IDs" '
    [ -n "$IDLE_MSG" ] && [ -n "$PERM_MSG" ] && [ "$IDLE_MSG" != "$PERM_MSG" ]
'

echo "  Idle message ID: $IDLE_MSG"
echo "  Permission message ID: $PERM_MSG"
echo ""
echo -e "${BLUE}→ Discord check: Should see TWO messages for test-proj-d${NC}"
echo -e "${BLUE}  (One idle, one permission)${NC}"

# TEST 4: Permission messages should NOT be cleaned up (audit trail)
echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}TEST CATEGORY: Permission Cleanup Exemption${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

cleanup_test_state

run_test "First permission message should create message ID" '
    send_notification "/tmp/test-proj-e" "permission_prompt" ",\"message\":\"First permission\"" && \
    sleep 2 && \
    check_message_id_exists "test-proj-e" "permission_prompt"
'

FIRST_PERM_MSG=$(get_message_id "test-proj-e" "permission_prompt")
echo "  First permission message ID: $FIRST_PERM_MSG"

run_test "Second permission message should create NEW message (not replace)" '
    sleep 4 && \
    send_notification "/tmp/test-proj-e" "permission_prompt" ",\"message\":\"Second permission\"" && \
    sleep 2 && \
    SECOND_PERM_MSG=$(get_message_id "test-proj-e" "permission_prompt") && \
    [ -n "$SECOND_PERM_MSG" ] && [ "$SECOND_PERM_MSG" != "$FIRST_PERM_MSG" ]
'

SECOND_PERM_MSG=$(get_message_id "test-proj-e" "permission_prompt")
echo "  Second permission message ID: $SECOND_PERM_MSG"
echo ""
echo -e "${BLUE}→ Discord check: Should see TWO permission messages for test-proj-e${NC}"
echo -e "${BLUE}  (Permission messages are NOT cleaned up - they persist as audit history)${NC}"

# Compare: Idle messages DO get cleaned up
run_test "Idle messages should be replaced (cleanup enabled)" '
    send_notification "/tmp/test-proj-f" "idle_prompt" && \
    sleep 2 && \
    FIRST_IDLE=$(get_message_id "test-proj-f" "idle_prompt") && \
    sleep 4 && \
    send_notification "/tmp/test-proj-f" "idle_prompt" && \
    sleep 2 && \
    SECOND_IDLE=$(get_message_id "test-proj-f" "idle_prompt") && \
    [ -n "$FIRST_IDLE" ] && [ -n "$SECOND_IDLE" ] && [ "$FIRST_IDLE" != "$SECOND_IDLE" ]
'

echo ""
echo -e "${BLUE}→ Discord check: Should see ONE idle message for test-proj-f${NC}"
echo -e "${BLUE}  (Idle messages ARE cleaned up - only latest visible)${NC}"

# Cleanup
echo ""
echo "Cleaning up test state..."
cleanup_test_state

# Final results
echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo "Tests run: $TESTS_RUN"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $((TESTS_RUN - TESTS_PASSED))"
echo ""

if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    echo "Check Discord to verify visual behavior:"
    echo "  • Old messages should be deleted when replaced"
    echo "  • Different projects should have separate messages"
    echo "  • Different event types should coexist"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
