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

# -- Helper: replicate build_status_payload from claude-notify.sh --
# We test payload building in isolation (no curl, no webhook)

PROJECT_NAME="my-project"
SESSION_ID=""
PERMISSION_MODE=""
TOOL_NAME=""
TOOL_INPUT=""
CWD=""
NOTIFY_DIR="$TEST_TMPDIR/notify-config"

# Stub build_extra_fields (no extra context in tests)
build_extra_fields() { echo "[]"; }

# Stub validate_color
validate_color() {
    local color="$1"
    if [ -n "$color" ] && [[ "$color" =~ ^[0-9]+$ ]] && [ "$color" -ge 0 ] && [ "$color" -le 16777215 ]; then
        return 0
    fi
    return 1
}

# Stub get_project_color
get_project_color() { echo 5793266; }

build_status_payload() {
    local state="$1"
    local extra="${2:-}"
    local title color fields
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local bot_name="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"
    local extra_fields=$(build_extra_fields)

    case "$state" in
        online)
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then color="3066993"; fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        idle)
            color=$(get_project_color "$PROJECT_NAME")
            title="🦀 ${PROJECT_NAME} — Ready for input"
            local base=$(jq -c -n '[{"name": "Status", "value": "Waiting for input", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        idle_busy)
            color=$(get_project_color "$PROJECT_NAME")
            title="🔄 ${PROJECT_NAME} — Idle"
            local base=$(jq -c -n \
                --arg subs "**${extra}** running" \
                '[
                    {"name": "Status", "value": "Main loop idle, waiting for subagents", "inline": false},
                    {"name": "Subagents", "value": $subs, "inline": true}
                ]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        permission)
            color="${CLAUDE_NOTIFY_PERMISSION_COLOR:-16753920}"
            if ! validate_color "$color"; then color="16753920"; fi
            title="🔐 ${PROJECT_NAME} — Needs Approval"
            local detail=""
            if [ -n "$extra" ]; then
                if [ "${#extra}" -gt 1000 ]; then
                    detail="${extra:0:997}..."
                else
                    detail="$extra"
                fi
            fi
            local base=$(jq -c -n \
                --arg detail "$detail" \
                'if $detail != "" then
                    [{"name": "Detail", "value": $detail, "inline": false}]
                 else [] end')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        approved)
            color="${CLAUDE_NOTIFY_APPROVAL_COLOR:-3066993}"
            if ! validate_color "$color"; then color="3066993"; fi
            title="✅ ${PROJECT_NAME} — Permission Approved"
            local base=$(jq -c -n '[{"name": "Status", "value": "Permission granted, tool executed successfully", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        offline)
            color="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"
            if ! validate_color "$color"; then color="15158332"; fi
            title="🔴 ${PROJECT_NAME} — Session Offline"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session ended", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        *)
            echo "claude-notify: warning: unknown state '$state', defaulting to online" >&2
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then color="3066993"; fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
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
