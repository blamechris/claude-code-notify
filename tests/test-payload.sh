#!/bin/bash
# test-payload.sh -- Tests for build_status_payload across all 6 states
#
# Verifies that:
#   - All 6 states generate valid JSON
#   - Titles contain correct emoji and project name
#   - Colors match expected defaults
#   - Embed structure has required fields
#   - Permission detail truncation works
#   - idle_busy shows subagent count

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"
source "$LIB_FILE"

# -- Test setup --

PROJECT_NAME="my-project"
SUBAGENT_COUNT_FILE="$THROTTLE_DIR/subagent-count-${PROJECT_NAME}"

# Stub build_extra_fields (no extra context in tests)
build_extra_fields() { echo "[]"; }

# -- Tests --

# 1. "online" state generates valid JSON
payload_online=$(build_status_payload "online")
assert_true "online payload is valid JSON" \
    jq -e . <<< "$payload_online" > /dev/null 2>&1

title=$(echo "$payload_online" | jq -r '.embeds[0].title')
assert_match "online title contains project name" "my-project" "$title"
assert_match "online title contains 'Session Online'" "Session Online" "$title"

color=$(echo "$payload_online" | jq -r '.embeds[0].color')
assert_eq "online color is green" "3066993" "$color"

# 2. "idle" state generates valid JSON with correct title
payload_idle=$(build_status_payload "idle")
assert_true "idle payload is valid JSON" \
    jq -e . <<< "$payload_idle" > /dev/null 2>&1

title_idle=$(echo "$payload_idle" | jq -r '.embeds[0].title')
assert_match "idle title contains 'Ready for input'" "Ready for input" "$title_idle"

color_idle=$(echo "$payload_idle" | jq -r '.embeds[0].color')
assert_eq "idle color is project color (blurple)" "5793266" "$color_idle"

# 3. "idle_busy" state shows subagent count
payload_busy=$(build_status_payload "idle_busy" "3")
assert_true "idle_busy payload is valid JSON" \
    jq -e . <<< "$payload_busy" > /dev/null 2>&1

title_busy=$(echo "$payload_busy" | jq -r '.embeds[0].title')
assert_match "idle_busy title contains 'Idle'" "Idle" "$title_busy"

subagent_field=$(echo "$payload_busy" | jq -r '.embeds[0].fields[] | select(.name == "Subagents") | .value')
assert_match "idle_busy subagent field contains count" "3" "$subagent_field"

# 4. "permission" state with detail
payload_perm=$(build_status_payload "permission" "Allow read access to /etc/hosts?")
assert_true "permission payload is valid JSON" \
    jq -e . <<< "$payload_perm" > /dev/null 2>&1

title_perm=$(echo "$payload_perm" | jq -r '.embeds[0].title')
assert_match "permission title contains 'Needs Approval'" "Needs Approval" "$title_perm"

color_perm=$(echo "$payload_perm" | jq -r '.embeds[0].color')
assert_eq "permission color is orange" "16753920" "$color_perm"

detail_val=$(echo "$payload_perm" | jq -r '.embeds[0].fields[0].value')
assert_eq "permission detail field has message" \
    "Allow read access to /etc/hosts?" "$detail_val"

# 5. "permission" with empty detail has no Detail field
payload_nomsg=$(build_status_payload "permission" "")
field_count=$(echo "$payload_nomsg" | jq '.embeds[0].fields | length')
assert_eq "permission with no message has empty fields array" "0" "$field_count"

# 6. Permission detail truncation (1000 chars max with ellipsis)
long_message=$(printf 'A%.0s' {1..1500})
payload_long=$(build_status_payload "permission" "$long_message")
detail_long=$(echo "$payload_long" | jq -r '.embeds[0].fields[0].value')
detail_len=${#detail_long}

if [ "$detail_len" -le 1000 ]; then
    printf "  PASS: Long message truncated to %d chars (<= 1000)\n" "$detail_len"
    ((pass++))
else
    printf "  FAIL: Long message not truncated (length = %d, expected <= 1000)\n" "$detail_len"
    ((fail++))
fi

# 6b. Truncated message ends with ellipsis
assert_match "Truncated message ends with '...'" '\.\.\.$' "$detail_long"

# 6c. Message under limit is not truncated
short_message=$(printf 'B%.0s' {1..500})
payload_short=$(build_status_payload "permission" "$short_message")
detail_short=$(echo "$payload_short" | jq -r '.embeds[0].fields[0].value')
assert_eq "Short message not truncated" "500" "${#detail_short}"

# 7. "approved" state
payload_approved=$(build_status_payload "approved")
assert_true "approved payload is valid JSON" \
    jq -e . <<< "$payload_approved" > /dev/null 2>&1

title_approved=$(echo "$payload_approved" | jq -r '.embeds[0].title')
assert_match "approved title contains 'Permission Approved'" "Permission Approved" "$title_approved"

color_approved=$(echo "$payload_approved" | jq -r '.embeds[0].color')
assert_eq "approved color is green" "3066993" "$color_approved"

# 7b. Approved state shows subagent count when > 0 (#101)
echo "2" > "$SUBAGENT_COUNT_FILE"
write_bg_bash_count "3"
payload_approved_counts=$(build_status_payload "approved")
approved_subs=$(echo "$payload_approved_counts" | jq -r '.embeds[0].fields[] | select(.name == "Subagents") | .value')
assert_eq "approved shows Subagents when > 0" "2" "$approved_subs"

approved_bg=$(echo "$payload_approved_counts" | jq -r '.embeds[0].fields[] | select(.name == "BG Bashes") | .value')
assert_eq "approved shows BG Bashes when > 0" "3" "$approved_bg"

# 7c. Approved state hides counts when 0
echo "0" > "$SUBAGENT_COUNT_FILE"
write_bg_bash_count "0"
payload_approved_zero=$(build_status_payload "approved")
approved_no_subs=$(echo "$payload_approved_zero" | jq -r '.embeds[0].fields[] | select(.name == "Subagents") | .value')
assert_eq "approved hides Subagents when 0" "" "$approved_no_subs"

approved_no_bg=$(echo "$payload_approved_zero" | jq -r '.embeds[0].fields[] | select(.name == "BG Bashes") | .value')
assert_eq "approved hides BG Bashes when 0" "" "$approved_no_bg"

# 8. "offline" state
payload_offline=$(build_status_payload "offline")
assert_true "offline payload is valid JSON" \
    jq -e . <<< "$payload_offline" > /dev/null 2>&1

title_offline=$(echo "$payload_offline" | jq -r '.embeds[0].title')
assert_match "offline title contains 'Session Offline'" "Session Offline" "$title_offline"

color_offline=$(echo "$payload_offline" | jq -r '.embeds[0].color')
assert_eq "offline color is red" "15158332" "$color_offline"

# 9. Embed structure has required fields
required_keys=("title" "color" "fields" "footer" "timestamp")
for key in "${required_keys[@]}"; do
    has_key=$(echo "$payload_online" | jq -r ".embeds[0] | has(\"$key\")")
    assert_eq "Embed has required field '$key'" "true" "$has_key"
done

# 10. Footer text is "Claude Code"
footer=$(echo "$payload_online" | jq -r '.embeds[0].footer.text')
assert_eq "Footer text is 'Claude Code'" "Claude Code" "$footer"

# 11. Timestamp matches ISO 8601 format
ts=$(echo "$payload_online" | jq -r '.embeds[0].timestamp')
assert_match "Timestamp is ISO 8601 format" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$ts"

# 12. Username is set correctly
username=$(echo "$payload_online" | jq -r '.username')
assert_eq "Username defaults to 'Claude Code'" "Claude Code" "$username"

# 13. Custom bot name
CLAUDE_NOTIFY_BOT_NAME="My Bot"
payload_custom=$(build_status_payload "online")
custom_username=$(echo "$payload_custom" | jq -r '.username')
assert_eq "Custom bot name is set" "My Bot" "$custom_username"
unset CLAUDE_NOTIFY_BOT_NAME

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
