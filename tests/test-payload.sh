#!/bin/bash
# test-payload.sh -- Tests for Discord webhook payload construction
#
# Verifies that:
#   - idle_prompt generates valid JSON with correct title format
#   - permission_prompt generates valid JSON with detail field
#   - Long messages get truncated to 300 chars
#   - jq can parse the generated payload
#   - Embed structure has required fields (title, color, fields, footer, timestamp)
#
# We reconstruct the payload-building logic from claude-notify.sh to test it
# in isolation, without needing a real webhook URL or curl.

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Helper functions replicated from claude-notify.sh --

get_status_emoji() {
    case "$1" in
        idle_ready)    echo "🟢" ;;
        idle_busy)     echo "🔄" ;;
        permission)    echo "🔐" ;;
        *)             echo "📝" ;;
    esac
}

# Build a payload the same way the main script does.
build_payload() {
    local notification_type="$1"
    local project_name="$2"
    local message="${3:-}"
    local subagents="${4:-0}"
    local color="${5:-5793266}"
    local bot_name="${6:-Claude Code}"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local title fields emoji

    case "$notification_type" in
        idle_prompt)
            if [ "$subagents" -gt 0 ]; then
                emoji=$(get_status_emoji "idle_busy")
                title="${emoji} ${project_name} — Idle"
                fields=$(jq -c -n \
                    --arg subs "**${subagents}** running" \
                    '[
                        {"name": "Status",    "value": "Main loop idle, waiting for subagents", "inline": false},
                        {"name": "Subagents", "value": $subs, "inline": true}
                    ]')
            else
                emoji=$(get_status_emoji "idle_ready")
                title="${emoji} ${project_name} — Ready for input"
                fields=$(jq -c -n \
                    '[{"name": "Status", "value": "Waiting for input", "inline": false}]')
            fi
            ;;

        permission_prompt)
            emoji=$(get_status_emoji "permission")
            title="${emoji} ${project_name} — Needs Approval"
            local detail=""
            [ -n "$message" ] && detail=$(echo "$message" | head -c 300)
            fields=$(jq -c -n \
                --arg detail "$detail" \
                'if $detail != "" then
                    [{"name": "Detail", "value": $detail, "inline": false}]
                 else [] end')
            ;;

        *)
            emoji=$(get_status_emoji "other")
            title="${emoji} ${project_name} — ${notification_type:-notification}"
            fields="[]"
            ;;
    esac

    jq -c -n \
        --arg username "$bot_name" \
        --arg title "$title" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --arg ts "$timestamp" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: "Claude Code" },
                timestamp: $ts
            }]
        }'
}

# -- Tests --

# 1. idle_prompt generates valid JSON that jq can parse
payload=$(build_payload "idle_prompt" "my-project" "" 0)
assert_true "idle_prompt payload is valid JSON" \
    jq -e . <<< "$payload" > /dev/null 2>&1

# 2. idle_prompt title contains project name and "Ready for input"
title=$(echo "$payload" | jq -r '.embeds[0].title')
assert_match "idle_prompt title contains project name" "my-project" "$title"
assert_match "idle_prompt title contains 'Ready for input'" "Ready for input" "$title"

# 3. idle_prompt with subagents shows "Idle" title and subagent count
payload_busy=$(build_payload "idle_prompt" "my-project" "" 3)
title_busy=$(echo "$payload_busy" | jq -r '.embeds[0].title')
assert_match "idle_prompt with subagents shows 'Idle'" "Idle" "$title_busy"

subagent_field=$(echo "$payload_busy" | jq -r '.embeds[0].fields[] | select(.name == "Subagents") | .value')
assert_match "idle_prompt subagent field contains count" "3" "$subagent_field"

# 4. permission_prompt generates valid JSON with Detail field
payload_perm=$(build_payload "permission_prompt" "test-proj" "Allow read access to /etc/hosts?")
assert_true "permission_prompt payload is valid JSON" \
    jq -e . <<< "$payload_perm" > /dev/null 2>&1

title_perm=$(echo "$payload_perm" | jq -r '.embeds[0].title')
assert_match "permission_prompt title contains 'Needs Approval'" "Needs Approval" "$title_perm"

detail_val=$(echo "$payload_perm" | jq -r '.embeds[0].fields[0].value')
assert_eq "permission_prompt detail field has message" \
    "Allow read access to /etc/hosts?" "$detail_val"

# 5. permission_prompt with empty message has no Detail field
payload_nomsg=$(build_payload "permission_prompt" "test-proj" "")
field_count=$(echo "$payload_nomsg" | jq '.embeds[0].fields | length')
assert_eq "permission_prompt with no message has empty fields array" "0" "$field_count"

# 6. Message truncation -- messages longer than 300 chars are truncated
long_message=$(printf 'A%.0s' {1..500})  # 500 'A' characters
payload_long=$(build_payload "permission_prompt" "test-proj" "$long_message")
detail_long=$(echo "$payload_long" | jq -r '.embeds[0].fields[0].value')
detail_len=${#detail_long}

if [ "$detail_len" -le 300 ]; then
    printf "  PASS: Long message truncated to %d chars (<= 300)\n" "$detail_len"
    ((pass++))
else
    printf "  FAIL: Long message not truncated (length = %d, expected <= 300)\n" "$detail_len"
    ((fail++))
fi

# 7. Embed structure has required fields: title, color, fields, footer, timestamp
required_keys=("title" "color" "fields" "footer" "timestamp")
for key in "${required_keys[@]}"; do
    has_key=$(echo "$payload" | jq -r ".embeds[0] | has(\"$key\")")
    assert_eq "Embed has required field '$key'" "true" "$has_key"
done

# 8. Footer text is "Claude Code"
footer=$(echo "$payload" | jq -r '.embeds[0].footer.text')
assert_eq "Footer text is 'Claude Code'" "Claude Code" "$footer"

# 9. Timestamp matches ISO 8601 format
ts=$(echo "$payload" | jq -r '.embeds[0].timestamp')
assert_match "Timestamp is ISO 8601 format" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$ts"

# 10. Username is set correctly
username=$(echo "$payload" | jq -r '.username')
assert_eq "Username defaults to 'Claude Code'" "Claude Code" "$username"

# 11. Custom bot name
payload_custom=$(build_payload "idle_prompt" "proj" "" 0 5793266 "My Bot")
custom_username=$(echo "$payload_custom" | jq -r '.username')
assert_eq "Custom bot name is set" "My Bot" "$custom_username"

# 12. Color value is a number
color_val=$(echo "$payload" | jq -r '.embeds[0].color')
assert_eq "Default color is Discord blurple" "5793266" "$color_val"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
