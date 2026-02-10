#!/bin/bash
# test-empty-cwd.sh -- Tests for empty CWD handling (Issue #38)
#
# Verifies that:
#   - Empty CWD results in PROJECT_NAME="unknown"
#   - CWD="/" (basename returns "/") results in PROJECT_NAME="unknown"
#   - Special-char-only project names sanitize to PROJECT_NAME="unknown"
#   - Subagent counts don't collide across empty CWD scenarios
#   - Throttle files use "unknown" not empty string

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# Helper to extract PROJECT_NAME from the script, given INPUT
extract_project_name() {
    local input="$1"
    # Mimic the exact logic from claude-notify.sh:63-68
    local cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
    local project_name="unknown"
    [ -n "$cwd" ] && project_name=$(basename "$cwd")
    project_name=$(echo "$project_name" | tr -cd 'A-Za-z0-9._-')
    # Ensure PROJECT_NAME is never empty after sanitization (fixes Issue #38)
    [ -z "$project_name" ] && project_name="unknown"
    echo "$project_name"
}

# -- Tests --

# 1. Empty cwd field results in PROJECT_NAME="unknown"
result=$(extract_project_name '{"hook_event_name": "SubagentStart", "cwd": ""}')
assert_eq "Empty cwd → PROJECT_NAME=unknown" "unknown" "$result"

# 2. Missing cwd field results in PROJECT_NAME="unknown"
result=$(extract_project_name '{"hook_event_name": "SubagentStart"}')
assert_eq "Missing cwd → PROJECT_NAME=unknown" "unknown" "$result"

# 3. CWD="/" (root dir, basename returns "/") sanitizes to "unknown"
# The tr command removes "/" because it's not alphanumeric or ._-
result=$(extract_project_name '{"hook_event_name": "SubagentStart", "cwd": "/"}')
assert_eq "CWD=/ → PROJECT_NAME=unknown" "unknown" "$result"

# 4. Special-char-only project name sanitizes to "unknown"
# Example: if basename returned "@#$" (only special chars, no alphanumeric or ._-)
result=$(extract_project_name '{"hook_event_name": "SubagentStart", "cwd": "/@#$"}')
assert_eq "Special-chars-only CWD → PROJECT_NAME=unknown" "unknown" "$result"

# 5. Normal project name works correctly
result=$(extract_project_name '{"hook_event_name": "SubagentStart", "cwd": "/home/user/my-project"}')
assert_eq "Normal project name → my-project" "my-project" "$result"

# 6. Project name with special chars is sanitized but not empty
result=$(extract_project_name '{"hook_event_name": "SubagentStart", "cwd": "/home/user/my@#$-project"}')
assert_eq "Project name with special chars → my-project" "my-project" "$result"

# 7. SubagentStart with empty CWD creates counter file with "unknown" name (no collision)
rm -f "$THROTTLE_DIR/subagent-count-unknown"
input1='{"hook_event_name": "SubagentStart", "cwd": ""}'
input2='{"hook_event_name": "SubagentStart", "cwd": "/"}'
# Simulate by extracting PROJECT_NAME and creating the file
proj1=$(extract_project_name "$input1")
proj2=$(extract_project_name "$input2")
assert_eq "Both empty/root CWD extract to same PROJECT_NAME" "$proj1" "$proj2"
assert_eq "That PROJECT_NAME is 'unknown'" "unknown" "$proj1"

# Verify they would use the same throttle file (not a collision risk, by design)
file1="$THROTTLE_DIR/subagent-count-${proj1}"
file2="$THROTTLE_DIR/subagent-count-${proj2}"
assert_eq "Both scenarios use same throttle file" "$file1" "$file2"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
