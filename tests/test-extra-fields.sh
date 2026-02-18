#!/bin/bash
# test-extra-fields.sh -- Tests for build_extra_fields()
#
# Verifies that:
#   - Default (all SHOW_* off) returns empty array
#   - SHOW_SESSION_INFO adds Session and Permission Mode fields
#   - SHOW_FULL_PATH adds Path field
#   - SHOW_TOOL_INFO adds Tool and Command fields
#   - Tool input truncation at 1000 characters
#   - Empty/null/non-object TOOL_INPUT handled gracefully

set -uo pipefail

[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# -- Set up globals that build_extra_fields reads --

SESSION_ID="abcdef1234567890"
PERMISSION_MODE="default"
CWD="/Users/test/Projects/my-project"
TOOL_NAME=""
TOOL_INPUT=""

# Source the real build_extra_fields from the main script (extract just the function)
# We can't source the whole script (it runs immediately), so define it here
# matching the implementation in claude-notify.sh:114-152
build_extra_fields() {
    local extra_fields="[]"

    if [ "${CLAUDE_NOTIFY_SHOW_SESSION_INFO:-false}" = "true" ]; then
        if [ -n "$SESSION_ID" ]; then
            local short_id="${SESSION_ID:0:8}"
            extra_fields=$(echo "$extra_fields" | jq -c --arg id "$short_id" '. + [{"name": "Session", "value": $id, "inline": true}]')
        fi
        if [ -n "$PERMISSION_MODE" ]; then
            extra_fields=$(echo "$extra_fields" | jq -c --arg mode "$PERMISSION_MODE" '. + [{"name": "Permission Mode", "value": $mode, "inline": true}]')
        fi
    fi

    if [ "${CLAUDE_NOTIFY_SHOW_FULL_PATH:-false}" = "true" ] && [ -n "$CWD" ]; then
        extra_fields=$(echo "$extra_fields" | jq -c --arg path "$CWD" '. + [{"name": "Path", "value": $path, "inline": false}]')
    fi

    # WARNING: commands may contain secrets (API keys, tokens). See README security considerations.
    if [ "${CLAUDE_NOTIFY_SHOW_TOOL_INFO:-false}" = "true" ] && [ -n "$TOOL_NAME" ]; then
        extra_fields=$(echo "$extra_fields" | jq -c --arg tool "$TOOL_NAME" '. + [{"name": "Tool", "value": $tool, "inline": true}]')

        if [ -n "$TOOL_INPUT" ] && [ "$TOOL_INPUT" != "null" ]; then
            local raw_detail=$(echo "$TOOL_INPUT" | jq -r 'if type == "object" then (.command // .file_path // "...") else . end' 2>/dev/null)
            local tool_detail="$raw_detail"
            if [ "${#raw_detail}" -gt 1000 ]; then
                tool_detail="${raw_detail:0:997}..."
            fi
            if [ -n "$tool_detail" ] && [ "$tool_detail" != "null" ]; then
                extra_fields=$(echo "$extra_fields" | jq -c --arg detail "$tool_detail" '. + [{"name": "Command", "value": $detail, "inline": false}]')
            fi
        fi
    fi

    echo "$extra_fields"
}

# -- Tests --

# 1. Default: all SHOW_* flags off → empty array
unset CLAUDE_NOTIFY_SHOW_SESSION_INFO CLAUDE_NOTIFY_SHOW_FULL_PATH CLAUDE_NOTIFY_SHOW_TOOL_INFO 2>/dev/null || true
result=$(build_extra_fields)
assert_eq "All flags off returns empty array" "[]" "$result"

# 2. SHOW_SESSION_INFO adds Session field (truncated to 8 chars)
export CLAUDE_NOTIFY_SHOW_SESSION_INFO="true"
result=$(build_extra_fields)
session_val=$(echo "$result" | jq -r '.[] | select(.name == "Session") | .value')
assert_eq "Session ID truncated to 8 chars" "abcdef12" "$session_val"

# 3. SHOW_SESSION_INFO adds Permission Mode field
perm_val=$(echo "$result" | jq -r '.[] | select(.name == "Permission Mode") | .value')
assert_eq "Permission Mode field present" "default" "$perm_val"

# 4. Session field is inline
session_inline=$(echo "$result" | jq -r '.[] | select(.name == "Session") | .inline')
assert_eq "Session field is inline" "true" "$session_inline"

# 5. Empty SESSION_ID omits Session field
OLD_SESSION="$SESSION_ID"
SESSION_ID=""
result=$(build_extra_fields)
session_count=$(echo "$result" | jq '[.[] | select(.name == "Session")] | length')
assert_eq "Empty SESSION_ID omits Session field" "0" "$session_count"
SESSION_ID="$OLD_SESSION"

# 6. Empty PERMISSION_MODE omits Permission Mode field
OLD_PERM="$PERMISSION_MODE"
PERMISSION_MODE=""
result=$(build_extra_fields)
perm_count=$(echo "$result" | jq '[.[] | select(.name == "Permission Mode")] | length')
assert_eq "Empty PERMISSION_MODE omits field" "0" "$perm_count"
PERMISSION_MODE="$OLD_PERM"
unset CLAUDE_NOTIFY_SHOW_SESSION_INFO

# 7. SHOW_FULL_PATH adds Path field
export CLAUDE_NOTIFY_SHOW_FULL_PATH="true"
result=$(build_extra_fields)
path_val=$(echo "$result" | jq -r '.[] | select(.name == "Path") | .value')
assert_eq "Path field has CWD value" "/Users/test/Projects/my-project" "$path_val"

# 8. Path field is not inline
path_inline=$(echo "$result" | jq -r '.[] | select(.name == "Path") | .inline')
assert_eq "Path field is not inline" "false" "$path_inline"

# 9. Empty CWD omits Path field
OLD_CWD="$CWD"
CWD=""
result=$(build_extra_fields)
path_count=$(echo "$result" | jq '[.[] | select(.name == "Path")] | length')
assert_eq "Empty CWD omits Path field" "0" "$path_count"
CWD="$OLD_CWD"
unset CLAUDE_NOTIFY_SHOW_FULL_PATH

# 10. SHOW_TOOL_INFO adds Tool field
export CLAUDE_NOTIFY_SHOW_TOOL_INFO="true"
TOOL_NAME="Bash"
TOOL_INPUT='{"command":"ls -la"}'
result=$(build_extra_fields)
tool_val=$(echo "$result" | jq -r '.[] | select(.name == "Tool") | .value')
assert_eq "Tool field has tool name" "Bash" "$tool_val"

# 11. Tool info includes Command field from .command
cmd_val=$(echo "$result" | jq -r '.[] | select(.name == "Command") | .value')
assert_eq "Command field extracted from .command" "ls -la" "$cmd_val"

# 12. Tool input with .file_path instead of .command
TOOL_INPUT='{"file_path":"/etc/hosts"}'
result=$(build_extra_fields)
cmd_val=$(echo "$result" | jq -r '.[] | select(.name == "Command") | .value')
assert_eq "Command field extracted from .file_path" "/etc/hosts" "$cmd_val"

# 13. Tool input truncation at 1000 chars
long_cmd=$(printf 'x%.0s' {1..1500})
TOOL_INPUT=$(jq -c -n --arg cmd "$long_cmd" '{"command": $cmd}')
result=$(build_extra_fields)
cmd_val=$(echo "$result" | jq -r '.[] | select(.name == "Command") | .value')
cmd_len=${#cmd_val}
if [ "$cmd_len" -le 1000 ]; then
    printf "  PASS: Tool input truncated to %d chars (<= 1000)\n" "$cmd_len"
    ((pass++))
else
    printf "  FAIL: Tool input not truncated (length = %d, expected <= 1000)\n" "$cmd_len"
    ((fail++))
fi

# 14. Truncated tool input ends with ellipsis
assert_match "Truncated tool input ends with '...'" '\.\.\.$' "$cmd_val"

# 15. Empty TOOL_INPUT omits Command field
TOOL_INPUT=""
result=$(build_extra_fields)
cmd_count=$(echo "$result" | jq '[.[] | select(.name == "Command")] | length')
assert_eq "Empty TOOL_INPUT omits Command field" "0" "$cmd_count"
# But Tool field is still present
tool_count=$(echo "$result" | jq '[.[] | select(.name == "Tool")] | length')
assert_eq "Tool field still present with empty input" "1" "$tool_count"

# 16. TOOL_INPUT="null" omits Command field
TOOL_INPUT="null"
result=$(build_extra_fields)
cmd_count=$(echo "$result" | jq '[.[] | select(.name == "Command")] | length')
assert_eq "TOOL_INPUT=null omits Command field" "0" "$cmd_count"

# 17. Non-object TOOL_INPUT (plain string) uses value directly
TOOL_INPUT='"just a string"'
result=$(build_extra_fields)
cmd_val=$(echo "$result" | jq -r '.[] | select(.name == "Command") | .value')
assert_eq "Non-object TOOL_INPUT used directly" "just a string" "$cmd_val"

# 18. Empty TOOL_NAME omits both Tool and Command fields
TOOL_NAME=""
TOOL_INPUT='{"command":"ls"}'
result=$(build_extra_fields)
field_count=$(echo "$result" | jq 'length')
assert_eq "Empty TOOL_NAME omits all tool fields" "0" "$field_count"

# 19. All flags enabled simultaneously
export CLAUDE_NOTIFY_SHOW_SESSION_INFO="true"
export CLAUDE_NOTIFY_SHOW_FULL_PATH="true"
TOOL_NAME="Edit"
TOOL_INPUT='{"file_path":"/tmp/test.txt"}'
SESSION_ID="abcdef1234567890"
PERMISSION_MODE="default"
CWD="/Users/test/Projects/my-project"
result=$(build_extra_fields)
total_fields=$(echo "$result" | jq 'length')
assert_eq "All flags on produces 5 fields" "5" "$total_fields"

unset CLAUDE_NOTIFY_SHOW_SESSION_INFO CLAUDE_NOTIFY_SHOW_FULL_PATH CLAUDE_NOTIFY_SHOW_TOOL_INFO
TOOL_NAME=""
TOOL_INPUT=""

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
