#!/bin/bash
# test-project-name.sh -- Tests for git-based project name resolution
#
# Verifies that:
#   - Git repo root is used when CWD is inside a git repo
#   - basename fallback works for non-git directories
#   - Monorepo subdirectories resolve to repo root name
#   - Empty/missing CWD still resolves to "unknown"

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# Helper to extract PROJECT_NAME, mirroring the script's logic
extract_project_name() {
    local input="$1"
    local cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
    local project_name="unknown"
    if [ -n "$cwd" ]; then
        local git_root
        git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
        if [ -n "$git_root" ]; then
            project_name=$(basename "$git_root")
        else
            project_name=$(basename "$cwd")
        fi
    fi
    project_name=$(echo "$project_name" | tr -cd 'A-Za-z0-9._-')
    [ -z "$project_name" ] && project_name="unknown"
    echo "$project_name"
}

# -- Tests --

# 1. Git repo root: CWD inside a git repo resolves to repo name
# Use this project's own directory as a known git repo
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
result=$(extract_project_name "{\"cwd\": \"$TESTS_DIR\"}")
assert_eq "Git subdir resolves to repo root name" "claude-code-notify" "$result"

# 2. Git repo root: CWD is the repo root itself
result=$(extract_project_name "{\"cwd\": \"$PROJECT_DIR\"}")
assert_eq "Git repo root resolves to repo name" "claude-code-notify" "$result"

# 3. Non-git directory falls back to basename
NONGIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/my-plain-dir.XXXXXX")
result=$(extract_project_name "{\"cwd\": \"$NONGIT_DIR\"}")
expected=$(basename "$NONGIT_DIR")
# Sanitize expected the same way
expected=$(echo "$expected" | tr -cd 'A-Za-z0-9._-')
assert_eq "Non-git dir falls back to basename" "$expected" "$result"
rm -rf "$NONGIT_DIR"

# 4. Empty CWD still gives "unknown"
result=$(extract_project_name '{"cwd": ""}')
assert_eq "Empty CWD → unknown" "unknown" "$result"

# 5. Missing CWD still gives "unknown"
result=$(extract_project_name '{"hook_event_name": "Notification"}')
assert_eq "Missing CWD → unknown" "unknown" "$result"

# 6. Monorepo simulation: deep subdirectory resolves to repo root
# Use this project's tests/  as a nested path
result=$(extract_project_name "{\"cwd\": \"$TESTS_DIR\"}")
assert_eq "Monorepo subdir resolves to repo root" "claude-code-notify" "$result"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
