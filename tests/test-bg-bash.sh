#!/bin/bash
# test-bg-bash.sh -- Tests for background bash tracking
#
# Verifies that:
#   - read/write bg bash count round-trips correctly
#   - read/write peak bg bash round-trips correctly
#   - clear_status_files removes bg bash files
#   - jq parsing of run_in_background from tool_input works
#   - Payload: online with bg bashes shows BG Bashes field
#   - Payload: idle with bg bashes shows in status text
#   - Payload: idle_busy with bg bashes shows BG Bashes field
#   - Payload: offline with peak bg bashes shows Peak BG Bashes field

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

PROJECT_NAME="test-proj-bgbash"
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# -- Helper tests --

# 1. read_bg_bash_count defaults to 0
rm -f "$THROTTLE_DIR/bg-bash-count-${PROJECT_NAME}"
assert_eq "read_bg_bash_count default is 0" "0" "$(read_bg_bash_count)"

# 2. write/read bg bash count round-trip
write_bg_bash_count "5"
assert_eq "read_bg_bash_count reads written value" "5" "$(read_bg_bash_count)"

# 3. read_peak_bg_bash defaults to 0
rm -f "$THROTTLE_DIR/peak-bg-bash-${PROJECT_NAME}"
assert_eq "read_peak_bg_bash default is 0" "0" "$(read_peak_bg_bash)"

# 4. write/read peak bg bash round-trip
write_peak_bg_bash "3"
assert_eq "read_peak_bg_bash reads written value" "3" "$(read_peak_bg_bash)"

# 5. clear_status_files removes bg bash files
write_bg_bash_count "2"
write_peak_bg_bash "4"
clear_status_files
assert_false "bg-bash-count file removed by clear" [ -f "$THROTTLE_DIR/bg-bash-count-${PROJECT_NAME}" ]
assert_false "peak-bg-bash file removed by clear" [ -f "$THROTTLE_DIR/peak-bg-bash-${PROJECT_NAME}" ]

# 6. jq parsing of run_in_background from tool_input
TOOL_INPUT_BG='{"command":"sleep 100","run_in_background":true}'
RUN_IN_BG=$(echo "$TOOL_INPUT_BG" | jq -r '.run_in_background // false' 2>/dev/null)
assert_eq "jq parses run_in_background=true" "true" "$RUN_IN_BG"

TOOL_INPUT_FG='{"command":"ls"}'
RUN_IN_FG=$(echo "$TOOL_INPUT_FG" | jq -r '.run_in_background // false' 2>/dev/null)
assert_eq "jq parses missing run_in_background as false" "false" "$RUN_IN_FG"

# -- Payload tests --

# 7. online with bg bashes shows BG Bashes field
write_bg_bash_count "2"
payload=$(build_status_payload "online")
bg_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "BG Bashes") | .value')
assert_eq "online payload shows BG Bashes field" "2" "$bg_field"

# 8. online with 0 bg bashes has no BG Bashes field
write_bg_bash_count "0"
payload=$(build_status_payload "online")
bg_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "BG Bashes") | .value' 2>/dev/null)
assert_eq "online payload hides BG Bashes when 0" "" "$bg_field"

# 9. idle with bg bashes shows count in status text
write_bg_bash_count "3"
payload=$(build_status_payload "idle")
status_val=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Status") | .value')
assert_match "idle status text includes bg bash count" "3 bg bashes launched" "$status_val"

# 10. idle with 0 bg bashes shows plain status
write_bg_bash_count "0"
payload=$(build_status_payload "idle")
status_val=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Status") | .value')
assert_eq "idle status text is plain when 0 bg bashes" "Waiting for input" "$status_val"

# 11. idle_busy with bg bashes shows BG Bashes field
write_bg_bash_count "2"
payload=$(build_status_payload "idle_busy" "3")
bg_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "BG Bashes") | .value')
assert_eq "idle_busy payload shows BG Bashes field" "2" "$bg_field"

# 12. offline with peak bg bashes shows Peak BG Bashes field
write_peak_bg_bash "5"
payload=$(build_status_payload "offline")
peak_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Peak BG Bashes") | .value')
assert_eq "offline payload shows Peak BG Bashes" "5" "$peak_field"

# 13. offline with 0 peak bg bashes has no Peak BG Bashes field
write_peak_bg_bash "0"
payload=$(build_status_payload "offline")
peak_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Peak BG Bashes") | .value' 2>/dev/null)
assert_eq "offline payload hides Peak BG Bashes when 0" "" "$peak_field"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
