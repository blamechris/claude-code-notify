#!/bin/bash
# test-tmp-filter.sh -- Tests for ephemeral session path filtering
#
# Verifies that sessions from /tmp, /private/tmp, /var/tmp, and from
# any paths containing .claude/worktrees/agent-* are silently dropped (no state files).
# Also verifies that CLAUDE_NOTIFY_SKIP_TMP_FILTER=1 bypasses the filter.

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Mock curl setup --
MOCK_BIN="$TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/curl" << 'MOCK_CURL'
#!/bin/bash
BODY_OUT="/dev/stdout"
WRITE_OUT=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        -o) BODY_OUT="${args[$((i+1))]}"; i=$((i+2)) ;;
        -w) WRITE_OUT="${args[$((i+1))]}"; i=$((i+2)) ;;
        -D) touch "${args[$((i+1))]}" 2>/dev/null; i=$((i+2)) ;;
        *) i=$((i+1)) ;;
    esac
done
echo '{"id":"mock-msg-123"}' > "$BODY_OUT"
if [ -n "$WRITE_OUT" ]; then
    printf '%b' "${WRITE_OUT//%\{http_code\}/200}"
fi
MOCK_CURL
chmod +x "$MOCK_BIN/curl"

export PATH="$MOCK_BIN:$PATH"

# -- Test environment --
export CLAUDE_NOTIFY_THROTTLE_DIR="$THROTTLE_DIR"
export CLAUDE_NOTIFY_DIR="$NOTIFY_DIR"
export CLAUDE_NOTIFY_WEBHOOK="https://discord.com/api/webhooks/123456789012345678/test-token-abc123"
export CLAUDE_NOTIFY_HEARTBEAT_INTERVAL=0
# Ensure filter is ACTIVE (not bypassed) for these tests
unset CLAUDE_NOTIFY_SKIP_TMP_FILTER

# Helper: run main script with JSON input
run_hook() {
    echo "$1" | bash "$MAIN_SCRIPT" 2>/dev/null
    return 0
}

# Helper: check if any state files exist for a project name
has_state_files() {
    local project="$1"
    ls "$THROTTLE_DIR"/*"${project}"* 2>/dev/null | grep -q .
}

# -- Tests: /tmp paths should be filtered --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/tmp","session_id":"tmp-test-1"}'
assert_false "/tmp CWD produces no state files" has_state_files "tmp"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/tmp/some-subdir","session_id":"tmp-test-2"}'
assert_false "/tmp/some-subdir CWD produces no state files" has_state_files "some-subdir"

# -- Tests: /private/tmp paths should be filtered --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/private/tmp","session_id":"ptmp-test-1"}'
assert_false "/private/tmp CWD produces no state files" has_state_files "tmp"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/private/tmp/deep/path","session_id":"ptmp-test-2"}'
assert_false "/private/tmp/deep/path CWD produces no state files" has_state_files "path"

# -- Tests: non-existent /tmp subdir should still be filtered (cd fallback) --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/tmp/nonexistent-dir-12345","session_id":"noexist-test-1"}'
assert_false "Non-existent /tmp subdir still filtered" has_state_files "nonexistent"

# -- Tests: /var/tmp paths should be filtered --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"/var/tmp","session_id":"vtmp-test-1"}'
assert_false "/var/tmp CWD produces no state files" has_state_files "tmp"

# -- Tests: worktree agent paths should be filtered --
# Use a non-tmp base dir so the /tmp/* case doesn't match first — this ensures
# the */.claude/worktrees/agent-* pattern is the one doing the filtering.
WT_BASE=$(mktemp -d "$HOME/.claude-notify-test-wt.XXXXXX")
trap 'rm -rf "$WT_BASE"' EXIT

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
WORKTREE_DIR="$WT_BASE/fake-project/.claude/worktrees/agent-abc12345"
mkdir -p "$WORKTREE_DIR"
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$WORKTREE_DIR"'","session_id":"wt-test-1"}'
assert_false "Worktree agent CWD produces no state files" has_state_files "agent-abc12345"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
NESTED_WORKTREE="$WT_BASE/fake-project/.claude/worktrees/agent-aaa/.claude/worktrees/agent-bbb"
mkdir -p "$NESTED_WORKTREE"
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$NESTED_WORKTREE"'","session_id":"wt-test-2"}'
assert_false "Nested worktree agent CWD produces no state files" has_state_files "agent-bbb"

# -- Tests: exact home directory ($HOME) should be filtered, but not its subdirectories --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$HOME"'","session_id":"home-test-1"}'
assert_false "Home directory CWD produces no state files" has_state_files "$(basename "$HOME")"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
HOME_SUBDIR="$HOME/some-project-test-$$"
mkdir -p "$HOME_SUBDIR"
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$HOME_SUBDIR"'","session_id":"home-subdir-test-1"}'
assert_true "Home subdirectory CWD is NOT filtered" has_state_files "some-project-test-$$"
rm -rf "$HOME_SUBDIR"

# -- Tests: normal paths should pass through (filter active, no bypass) --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
NORMAL_DIR="$HOME/my-real-project-test-$$"
mkdir -p "$NORMAL_DIR"
run_hook '{"hook_event_name":"SessionStart","cwd":"'"$NORMAL_DIR"'","session_id":"normal-test-1"}'
assert_true "Normal CWD creates state files (filter active)" has_state_files "my-real-project-test-$$"
rm -rf "$NORMAL_DIR"

# -- Tests: CLAUDE_NOTIFY_SKIP_TMP_FILTER=1 bypasses filter --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
export CLAUDE_NOTIFY_SKIP_TMP_FILTER=1
run_hook '{"hook_event_name":"SessionStart","cwd":"/tmp/bypassed","session_id":"bypass-test-1"}'
unset CLAUDE_NOTIFY_SKIP_TMP_FILTER
assert_true "SKIP_TMP_FILTER=1 bypasses /tmp filter" has_state_files "bypassed"

# -- Tests: all hook event types are filtered --

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"SubagentStart","cwd":"/tmp"}'
assert_false "SubagentStart from /tmp produces no state files" has_state_files "tmp"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"PostToolUse","tool_name":"Bash","cwd":"/tmp"}'
assert_false "PostToolUse from /tmp produces no state files" has_state_files "tmp"

rm -f "$THROTTLE_DIR"/* 2>/dev/null || true
run_hook '{"hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"/tmp"}'
assert_false "Notification from /tmp produces no state files" has_state_files "tmp"

test_summary
