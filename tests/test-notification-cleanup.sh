#!/bin/bash
# test-notification-cleanup.sh
# Tests the CLAUDE_NOTIFY_CLEANUP_OLD feature to verify message replacement behavior

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SCRIPT="$PROJECT_ROOT/claude-notify.sh"

# Test configuration
export CLAUDE_NOTIFY_CLEANUP_OLD=true
export CLAUDE_NOTIFY_ENABLED=true

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
        echo -e "${GREEN}✓ PASS${NC}\n"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}\n"
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
}

echo "========================================"
echo "Notification Cleanup Behavior Tests"
echo "========================================"
echo ""
echo "These tests verify that CLAUDE_NOTIFY_CLEANUP_OLD correctly:"
echo "  1. Replaces messages for same project + event type"
echo "  2. Keeps separate messages for different projects"
echo "  3. Keeps separate messages for different event types"
echo ""
echo "⚠️  Note: These tests will post actual Discord messages!"
echo "    Check your Discord channel to verify visual behavior."
echo ""

# Wait for user confirmation
read -p "Press Enter to continue..." -r

cleanup_test_state

# TEST 1: Same project, same event type (should replace)
echo "========================================"
echo "TEST CATEGORY: Message Replacement"
echo "========================================"
echo ""

run_test "Same project + event should store message ID" '
    send_notification "/tmp/test-proj-a" "idle_prompt" && \
    sleep 2 && \
    check_message_id_exists "test-proj-a" "idle_prompt"
'

# Store first message ID
FIRST_MSG_ID=$(get_message_id "test-proj-a" "idle_prompt")

run_test "Second message to same project + event should update message ID" '
    sleep 2 && \
    send_notification "/tmp/test-proj-a" "idle_prompt" && \
    sleep 2 && \
    SECOND_MSG_ID=$(get_message_id "test-proj-a" "idle_prompt") && \
    [ "$SECOND_MSG_ID" != "$FIRST_MSG_ID" ]
'

echo "→ Check Discord: You should see ONE message for test-proj-a"
echo "  (The first message should have been deleted)"
echo ""
read -p "Press Enter to continue to next test..." -r

# TEST 2: Different projects (should NOT replace)
echo "========================================"
echo "TEST CATEGORY: Project Isolation"
echo "========================================"
echo ""

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

echo "→ Check Discord: You should see TWO messages"
echo "  (One for test-proj-b, one for test-proj-c)"
echo ""
read -p "Press Enter to continue to next test..." -r

# TEST 3: Same project, different event types (should NOT replace)
echo "========================================"
echo "TEST CATEGORY: Event Type Isolation"
echo "========================================"
echo ""

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

echo "→ Check Discord: You should see TWO messages for test-proj-d"
echo "  (One idle notification, one permission notification)"
echo ""
read -p "Press Enter to see final results..." -r

# Cleanup
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
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
