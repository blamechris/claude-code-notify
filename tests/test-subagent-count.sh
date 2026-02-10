#!/bin/bash
# test-subagent-count.sh -- Tests for subagent start/stop tracking
#
# Verifies that:
#   - SubagentStart increments counter from 0 to 1
#   - Multiple starts increment correctly
#   - SubagentStop decrements counter
#   - Counter never goes below 0
#   - Different projects have independent counters

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# We replicate the subagent tracking logic locally so we can test it
# without piping full JSON into the main script (which also tries to
# read stdin, check webhooks, etc.).

simulate_subagent_start() {
    local project="$1"
    local count_file="$THROTTLE_DIR/subagent-count-${project}"
    local count=0
    [ -f "$count_file" ] && count=$(cat "$count_file" 2>/dev/null || echo 0)
    echo $(( count + 1 )) > "$count_file"
}

simulate_subagent_stop() {
    local project="$1"
    local count_file="$THROTTLE_DIR/subagent-count-${project}"
    local count=0
    [ -f "$count_file" ] && count=$(cat "$count_file" 2>/dev/null || echo 0)
    local new_count=$(( count - 1 ))
    [ "$new_count" -lt 0 ] && new_count=0
    echo "$new_count" > "$count_file"
}

get_subagent_count() {
    local project="$1"
    local count_file="$THROTTLE_DIR/subagent-count-${project}"
    if [ -f "$count_file" ]; then
        cat "$count_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# -- Tests --

# 1. SubagentStart increments counter from 0 to 1
simulate_subagent_start "testproj1"
assert_eq "SubagentStart increments 0 -> 1" "1" "$(get_subagent_count testproj1)"

# 2. Multiple starts increment correctly
simulate_subagent_start "testproj1"
assert_eq "Second SubagentStart increments to 2" "2" "$(get_subagent_count testproj1)"

simulate_subagent_start "testproj1"
assert_eq "Third SubagentStart increments to 3" "3" "$(get_subagent_count testproj1)"

# 3. SubagentStop decrements counter
simulate_subagent_stop "testproj1"
assert_eq "SubagentStop decrements 3 -> 2" "2" "$(get_subagent_count testproj1)"

simulate_subagent_stop "testproj1"
assert_eq "SubagentStop decrements 2 -> 1" "1" "$(get_subagent_count testproj1)"

simulate_subagent_stop "testproj1"
assert_eq "SubagentStop decrements 1 -> 0" "0" "$(get_subagent_count testproj1)"

# 4. Counter never goes below 0
simulate_subagent_stop "testproj1"
assert_eq "Counter does not go below 0 (first extra stop)" "0" "$(get_subagent_count testproj1)"

simulate_subagent_stop "testproj1"
assert_eq "Counter does not go below 0 (second extra stop)" "0" "$(get_subagent_count testproj1)"

# 5. Different projects have independent counters
simulate_subagent_start "projA"
simulate_subagent_start "projA"
simulate_subagent_start "projB"

assert_eq "Project A has count 2" "2" "$(get_subagent_count projA)"
assert_eq "Project B has count 1" "1" "$(get_subagent_count projB)"

simulate_subagent_stop "projA"
assert_eq "Project A decremented to 1, B unchanged" "1" "$(get_subagent_count projA)"
assert_eq "Project B still 1 after A's stop" "1" "$(get_subagent_count projB)"

# 6. Starting from a missing count file
assert_eq "Missing count file reads as 0" "0" "$(get_subagent_count freshproj)"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
