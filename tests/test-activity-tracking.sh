#!/bin/bash
# test-activity-tracking.sh -- Tests for session metrics (Tier 1 "Lively Updates")
#
# Covers:
#   - format_duration() — human-readable time formatting
#   - State file helpers — read/write for session-start, tool-count, peak-subagents
#   - Tool counter — increment logic
#   - Peak subagent tracking — high-water mark
#   - Payload footer — dynamic duration in footer
#   - Offline summary — Tools Used and Peak Subagents fields
#   - Cleanup — clear_status_files removes metric files

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

# -- Replicate helpers from claude-notify.sh --

PROJECT_NAME="test-proj-activity"

# Stub safe_write_file
safe_write_file() {
    local file="$1"
    local content="$2"
    printf '%s\n' "$content" > "$file" 2>/dev/null || true
}

format_duration() {
    local seconds="$1"
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$(( seconds / 60 ))m $(( seconds % 60 ))s"
    else
        echo "$(( seconds / 3600 ))h $(( (seconds % 3600) / 60 ))m"
    fi
}

read_session_start() {
    local file="$THROTTLE_DIR/session-start-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}
write_session_start() { safe_write_file "$THROTTLE_DIR/session-start-${PROJECT_NAME}" "$1"; }
read_tool_count() {
    local file="$THROTTLE_DIR/tool-count-${PROJECT_NAME}"
    if [ -f "$file" ]; then cat "$file" 2>/dev/null || echo "0"; else echo "0"; fi
}
write_tool_count() { safe_write_file "$THROTTLE_DIR/tool-count-${PROJECT_NAME}" "$1"; }
read_peak_subagents() {
    local file="$THROTTLE_DIR/peak-subagents-${PROJECT_NAME}"
    if [ -f "$file" ]; then cat "$file" 2>/dev/null || echo "0"; else echo "0"; fi
}
write_peak_subagents() { safe_write_file "$THROTTLE_DIR/peak-subagents-${PROJECT_NAME}" "$1"; }

validate_color() {
    local color="$1"
    if [ -n "$color" ] && [[ "$color" =~ ^[0-9]+$ ]] && [ "$color" -ge 0 ] && [ "$color" -le 16777215 ]; then
        return 0
    fi
    return 1
}

build_extra_fields() { echo "[]"; }

# Stub build_status_payload (offline case only, for summary tests)
build_offline_payload() {
    local bot_name="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"
    local extra_fields=$(build_extra_fields)

    local footer_text="$bot_name"
    local session_start=$(read_session_start)
    if [ -n "$session_start" ] && [ "$session_start" != "0" ]; then
        local now=$(date +%s)
        local elapsed=$(( now - session_start ))
        if [ "$elapsed" -ge 0 ]; then
            footer_text="${bot_name} · $(format_duration $elapsed)"
        fi
    fi

    local color="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"
    local title="🔴 ${PROJECT_NAME} — Session Offline"
    local summary='[]'
    local tc=$(read_tool_count)
    if [ "$tc" -gt 0 ] 2>/dev/null; then
        summary=$(echo "$summary" | jq -c --arg v "$tc" '. + [{"name": "Tools Used", "value": $v, "inline": true}]')
    fi
    local peak=$(read_peak_subagents)
    if [ "$peak" -gt 0 ] 2>/dev/null; then
        summary=$(echo "$summary" | jq -c --arg v "$peak" '. + [{"name": "Peak Subagents", "value": $v, "inline": true}]')
    fi
    local fields=$(jq -c -n --argjson summary "$summary" --argjson extra "$extra_fields" '$summary + $extra')

    jq -c -n \
        --arg username "Claude Code" \
        --arg title "$title" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --arg footer "$footer_text" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: $footer },
                timestamp: $ts
            }]
        }'
}

# Stub build_online_payload (for footer tests)
build_online_payload() {
    local bot_name="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"
    local extra_fields=$(build_extra_fields)

    local footer_text="$bot_name"
    local session_start=$(read_session_start)
    if [ -n "$session_start" ] && [ "$session_start" != "0" ]; then
        local now=$(date +%s)
        local elapsed=$(( now - session_start ))
        if [ "$elapsed" -ge 0 ]; then
            footer_text="${bot_name} · $(format_duration $elapsed)"
        fi
    fi

    local color="3066993"
    local title="🟢 ${PROJECT_NAME} — Session Online"
    local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
    local fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')

    jq -c -n \
        --arg username "Claude Code" \
        --arg title "$title" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --arg footer "$footer_text" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            username: $username,
            embeds: [{
                title: $title,
                color: $color,
                fields: $fields,
                footer: { text: $footer },
                timestamp: $ts
            }]
        }'
}

clear_status_files() {
    local mode="${1:-}"
    if [ "$mode" != "keep_msg_id" ]; then
        rm -f "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" 2>/dev/null || true
    fi
    rm -f "$THROTTLE_DIR/status-state-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-idle-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/subagent-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-idle-busy-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/session-start-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/tool-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/peak-subagents-${PROJECT_NAME}" 2>/dev/null || true
}

# -- Clean state before tests --
clear_status_files

# ============================================================
# 1. format_duration tests
# ============================================================

assert_eq "format_duration 0 seconds" "0s" "$(format_duration 0)"
assert_eq "format_duration 45 seconds" "45s" "$(format_duration 45)"
assert_eq "format_duration 60 seconds" "1m 0s" "$(format_duration 60)"
assert_eq "format_duration 90 seconds" "1m 30s" "$(format_duration 90)"
assert_eq "format_duration 3600 seconds" "1h 0m" "$(format_duration 3600)"
assert_eq "format_duration 3661 seconds" "1h 1m" "$(format_duration 3661)"

# ============================================================
# 2. State file helpers — write/read round-trip and defaults
# ============================================================

# Defaults when files don't exist
assert_eq "read_session_start default is empty" "" "$(read_session_start)"
assert_eq "read_tool_count default is 0" "0" "$(read_tool_count)"
assert_eq "read_peak_subagents default is 0" "0" "$(read_peak_subagents)"

# Write/read round-trip
write_session_start "1700000000"
assert_eq "read_session_start round-trip" "1700000000" "$(read_session_start)"

write_tool_count "42"
assert_eq "read_tool_count round-trip" "42" "$(read_tool_count)"

write_peak_subagents "5"
assert_eq "read_peak_subagents round-trip" "5" "$(read_peak_subagents)"

# Clean up for next group
clear_status_files

# ============================================================
# 3. Tool counter — increment logic
# ============================================================

assert_eq "tool count starts at 0" "0" "$(read_tool_count)"

# Simulate PostToolUse increments
TOOL_COUNT=$(read_tool_count)
write_tool_count "$(( TOOL_COUNT + 1 ))"
assert_eq "tool count after 1 increment" "1" "$(read_tool_count)"

TOOL_COUNT=$(read_tool_count)
write_tool_count "$(( TOOL_COUNT + 1 ))"
assert_eq "tool count after 2 increments" "2" "$(read_tool_count)"

TOOL_COUNT=$(read_tool_count)
write_tool_count "$(( TOOL_COUNT + 1 ))"
assert_eq "tool count after 3 increments" "3" "$(read_tool_count)"

clear_status_files

# ============================================================
# 4. Peak subagent tracking — high-water mark
# ============================================================

assert_eq "peak starts at 0" "0" "$(read_peak_subagents)"

# Simulate SubagentStart: count goes 0->1, peak should update
NEW_COUNT=1
PEAK=$(read_peak_subagents)
[ "$NEW_COUNT" -gt "$PEAK" ] && write_peak_subagents "$NEW_COUNT"
assert_eq "peak updates to 1" "1" "$(read_peak_subagents)"

# Simulate SubagentStart: count goes 1->2, peak should update
NEW_COUNT=2
PEAK=$(read_peak_subagents)
[ "$NEW_COUNT" -gt "$PEAK" ] && write_peak_subagents "$NEW_COUNT"
assert_eq "peak updates to 2" "2" "$(read_peak_subagents)"

# Simulate SubagentStop then SubagentStart: count drops to 1 then back to 2
# Peak should NOT decrease
NEW_COUNT=1
PEAK=$(read_peak_subagents)
[ "$NEW_COUNT" -gt "$PEAK" ] && write_peak_subagents "$NEW_COUNT"
assert_eq "peak stays at 2 when count drops" "2" "$(read_peak_subagents)"

# Simulate SubagentStart: count goes 2->3, peak should update
NEW_COUNT=3
PEAK=$(read_peak_subagents)
[ "$NEW_COUNT" -gt "$PEAK" ] && write_peak_subagents "$NEW_COUNT"
assert_eq "peak updates to 3 on new high" "3" "$(read_peak_subagents)"

clear_status_files

# ============================================================
# 5. Payload footer — dynamic duration
# ============================================================

# No session-start file → footer is plain "Claude Code"
payload=$(build_online_payload)
footer=$(echo "$payload" | jq -r '.embeds[0].footer.text')
assert_eq "footer is 'Claude Code' with no session-start" "Claude Code" "$footer"

# With session-start file → footer contains duration
write_session_start "$(( $(date +%s) - 125 ))"
payload=$(build_online_payload)
footer=$(echo "$payload" | jq -r '.embeds[0].footer.text')
assert_match "footer contains 'Claude Code' with session-start" "^Claude Code" "$footer"
assert_match "footer contains duration" "[0-9]+m" "$footer"

clear_status_files

# ============================================================
# 6. Offline summary — Tools Used and Peak Subagents fields
# ============================================================

# With tool count > 0 → offline has Tools Used field
write_tool_count "57"
write_peak_subagents "0"
payload=$(build_offline_payload)
tc_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Tools Used") | .value')
assert_eq "offline has Tools Used field" "57" "$tc_field"
tc_inline=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Tools Used") | .inline')
assert_eq "Tools Used is inline" "true" "$tc_inline"

# No Peak Subagents field when peak is 0
peak_count=$(echo "$payload" | jq '[.embeds[0].fields[] | select(.name == "Peak Subagents")] | length')
assert_eq "no Peak Subagents when peak is 0" "0" "$peak_count"

clear_status_files

# With peak > 0 → offline has Peak Subagents field
write_tool_count "0"
write_peak_subagents "4"
payload=$(build_offline_payload)
peak_field=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Peak Subagents") | .value')
assert_eq "offline has Peak Subagents field" "4" "$peak_field"
peak_inline=$(echo "$payload" | jq -r '.embeds[0].fields[] | select(.name == "Peak Subagents") | .inline')
assert_eq "Peak Subagents is inline" "true" "$peak_inline"

clear_status_files

# Both metrics present
write_tool_count "100"
write_peak_subagents "3"
payload=$(build_offline_payload)
assert_true "offline payload with metrics is valid JSON" \
    jq -e . <<< "$payload" > /dev/null 2>&1
field_count=$(echo "$payload" | jq '.embeds[0].fields | length')
assert_eq "offline has 2 summary fields" "2" "$field_count"

clear_status_files

# No summary fields when counts are 0
write_tool_count "0"
write_peak_subagents "0"
payload=$(build_offline_payload)
field_count=$(echo "$payload" | jq '.embeds[0].fields | length')
assert_eq "offline has no fields when counts are 0" "0" "$field_count"

clear_status_files

# ============================================================
# 7. Cleanup — clear_status_files removes metric files
# ============================================================

# Write all metric files
write_session_start "1700000000"
write_tool_count "10"
write_peak_subagents "2"

# Verify files exist
assert_eq "session-start exists before clear" "1700000000" "$(read_session_start)"
assert_eq "tool-count exists before clear" "10" "$(read_tool_count)"
assert_eq "peak-subagents exists before clear" "2" "$(read_peak_subagents)"

# Clear and verify removal
clear_status_files
assert_eq "session-start cleared" "" "$(read_session_start)"
assert_eq "tool-count cleared to default" "0" "$(read_tool_count)"
assert_eq "peak-subagents cleared to default" "0" "$(read_peak_subagents)"

# clear_status_files with keep_msg_id still removes metric files
write_session_start "1700000000"
write_tool_count "10"
write_peak_subagents "2"
safe_write_file "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" "12345"

clear_status_files "keep_msg_id"
assert_eq "session-start cleared with keep_msg_id" "" "$(read_session_start)"
assert_eq "tool-count cleared with keep_msg_id" "0" "$(read_tool_count)"
assert_eq "peak-subagents cleared with keep_msg_id" "0" "$(read_peak_subagents)"
# msg_id should be preserved
msg_id=$(cat "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" 2>/dev/null || echo "")
assert_eq "msg_id preserved with keep_msg_id" "12345" "$msg_id"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
