#!/bin/bash
# lib/notify-helpers.sh -- Shared functions for claude-code-notify
#
# Sourced by claude-notify.sh and test files. NOT meant to be executed directly.
#
# Required variables (set before sourcing):
#   THROTTLE_DIR  -- path to state/throttle directory
#
# Optional variables:
#   PROJECT_NAME  -- sanitized project name (needed by state helpers)
#   NOTIFY_DIR    -- config directory (needed by load_env_var, get_project_color)
#   SUBAGENT_COUNT_FILE -- path to subagent count file (needed by build_status_payload)

# Guard: must be sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: notify-helpers.sh must be sourced, not executed directly." >&2
    exit 1
fi

# Prevent double-sourcing
[ -n "${_NOTIFY_HELPERS_LOADED:-}" ] && return 0
_NOTIFY_HELPERS_LOADED=1

# -- Config helpers --

# Load a variable from .env file if not already set via environment
load_env_var() {
    local var_name="$1"
    eval "[ -z \"\${${var_name}:-}\" ]" || return 0
    local val
    val=$(grep -m1 "^${var_name}=" "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$val" ]; then
        eval "${var_name}=\$val"
    fi
}

# -- Validation helpers --

# Validate Discord color is in range 0-16777215 (24-bit RGB)
validate_color() {
    local color="$1"
    if [ -n "$color" ] && [[ "$color" =~ ^[0-9]+$ ]] && [ "$color" -ge 0 ] && [ "$color" -le 16777215 ]; then
        return 0
    fi
    return 1
}

# Extract and validate webhook ID/token from Discord webhook URL
# Handles variations: query params, trailing slashes, fragments
extract_webhook_id_token() {
    local webhook_url="$1"

    # Extract ID/TOKEN from URL, removing query params and fragments
    local id_token=$(echo "$webhook_url" | jq -R 'split("/webhooks/")[1] | split("?")[0] | split("#")[0] | gsub("/$"; "")' 2>/dev/null || true)

    # Remove jq's JSON quotes if present
    id_token="${id_token%\"}"
    id_token="${id_token#\"}"

    # Validate format: ID (numeric) / TOKEN (alphanumeric, dashes, underscores)
    if [[ "$id_token" =~ ^[0-9]+/[A-Za-z0-9_-]+$ ]]; then
        echo "$id_token"
        return 0
    else
        return 1
    fi
}

# -- Project name extraction --

# Extract and sanitize project name from hook input JSON
extract_project_name() {
    local input="$1"
    local cwd=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)
    local project_name="unknown"
    if [ -n "$cwd" ]; then
        # Prefer git repo root name (fixes monorepo paths like chroxy/packages/app → chroxy)
        local git_root
        git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
        if [ -n "$git_root" ]; then
            project_name=$(basename "$git_root")
        else
            project_name=$(basename "$cwd")
        fi
    fi
    project_name=$(echo "$project_name" | tr -cd 'A-Za-z0-9._-')
    # Ensure PROJECT_NAME is never empty after sanitization (fixes Issue #38)
    [ -z "$project_name" ] && project_name="unknown"
    echo "$project_name"
}

# -- Formatting --

# Format seconds into human-readable duration (e.g. "5m 30s", "1h 15m")
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

# -- Safe file write helper --

# Write content to a file, logging a warning on failure.
# Always returns 0 — hook should continue even if state files fail.
# (Returning non-zero under set -euo pipefail would crash the script.)
safe_write_file() {
    local file="$1"
    local content="$2"
    if ! printf '%s\n' "$content" > "$file" 2>/dev/null; then
        echo "claude-notify: warning: failed to write to $file" >&2
    fi
    return 0
}

# -- Status state helpers --

read_status_state() {
    local file="$THROTTLE_DIR/status-state-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_status_state() {
    safe_write_file "$THROTTLE_DIR/status-state-${PROJECT_NAME}" "$1"
}

read_status_msg_id() {
    local file="$THROTTLE_DIR/status-msg-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_status_msg_id() {
    safe_write_file "$THROTTLE_DIR/status-msg-${PROJECT_NAME}" "$1"
}

# -- Session metric helpers --

read_session_start() {
    local file="$THROTTLE_DIR/session-start-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_session_start() {
    safe_write_file "$THROTTLE_DIR/session-start-${PROJECT_NAME}" "$1"
}

read_tool_count() {
    local file="$THROTTLE_DIR/tool-count-${PROJECT_NAME}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

write_tool_count() {
    safe_write_file "$THROTTLE_DIR/tool-count-${PROJECT_NAME}" "$1"
}

read_peak_subagents() {
    local file="$THROTTLE_DIR/peak-subagents-${PROJECT_NAME}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

write_peak_subagents() {
    safe_write_file "$THROTTLE_DIR/peak-subagents-${PROJECT_NAME}" "$1"
}

read_last_tool() {
    local file="$THROTTLE_DIR/last-tool-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_last_tool() {
    safe_write_file "$THROTTLE_DIR/last-tool-${PROJECT_NAME}" "$1"
}

# Clear status/throttle/subagent files for a project.
# Pass "keep_msg_id" to preserve the Discord message ID
# (SessionEnd needs this so the next SessionStart can delete the offline message).
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
    rm -f "$THROTTLE_DIR/last-tool-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-activity-${PROJECT_NAME}" 2>/dev/null || true
}

# -- Project colors (Discord embed sidebar, decimal RGB) --
# Customize these for your projects. Color values are decimal integers.
# Use https://www.spycolor.com to convert hex → decimal.
get_project_color() {
    local project="$1"

    # Check for user overrides in config file
    if [ -f "$NOTIFY_DIR/colors.conf" ]; then
        local color
        color=$(grep -m1 "^${project}=" "$NOTIFY_DIR/colors.conf" 2>/dev/null | cut -d= -f2- || true)
        if [ -n "$color" ]; then
            if validate_color "$color"; then
                echo "$color"
                return
            else
                echo "claude-notify: warning: color for project '$project' is out of range '$color' (0-16777215), using default" >&2
            fi
        fi
    fi

    # Default: Discord blurple #5865F2
    echo 5793266
}

# -- Build status payload --
# Builds a Discord embed payload for any state in the lifecycle.
# Caller must define build_extra_fields() and set $SUBAGENT_COUNT_FILE.
build_status_payload() {
    local state="$1"
    local extra="${2:-}"
    local title color fields
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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

    case "$state" in
        online)
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_ONLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            local tc=$(read_tool_count)
            if [ "${CLAUDE_NOTIFY_SHOW_ACTIVITY:-false}" = "true" ] && [ "$tc" -gt 0 ] 2>/dev/null; then
                local base='[]'
                base=$(echo "$base" | jq -c --arg v "$tc" '. + [{"name": "Tools Used", "value": $v, "inline": true}]')
                local last_tool=$(read_last_tool)
                if [ -n "$last_tool" ]; then
                    base=$(echo "$base" | jq -c --arg v "$last_tool" '. + [{"name": "Last Tool", "value": $v, "inline": true}]')
                fi
                local subs=0
                [ -f "$SUBAGENT_COUNT_FILE" ] && subs=$(cat "$SUBAGENT_COUNT_FILE" 2>/dev/null || echo 0)
                if [ "$subs" -gt 0 ] 2>/dev/null; then
                    base=$(echo "$base" | jq -c --arg v "$subs" '. + [{"name": "Subagents", "value": $v, "inline": true}]')
                fi
                fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            else
                local base=$(jq -c -n '[{"name": "Status", "value": "Session started", "inline": false}]')
                fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            fi
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
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_PERMISSION_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="16753920"
            fi
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
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_APPROVAL_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="✅ ${PROJECT_NAME} — Permission Approved"
            local base=$(jq -c -n '[{"name": "Status", "value": "Permission granted, tool executed successfully", "inline": false}]')
            fields=$(jq -c -n --argjson base "$base" --argjson extra "$extra_fields" '$base + $extra')
            ;;
        offline)
            color="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_OFFLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="15158332"
            fi
            title="🔴 ${PROJECT_NAME} — Session Offline"
            # Build summary fields with session metrics
            local summary='[]'
            local tc=$(read_tool_count)
            if [ "$tc" -gt 0 ] 2>/dev/null; then
                summary=$(echo "$summary" | jq -c --arg v "$tc" '. + [{"name": "Tools Used", "value": $v, "inline": true}]')
            fi
            local peak=$(read_peak_subagents)
            if [ "$peak" -gt 0 ] 2>/dev/null; then
                summary=$(echo "$summary" | jq -c --arg v "$peak" '. + [{"name": "Peak Subagents", "value": $v, "inline": true}]')
            fi
            fields=$(jq -c -n --argjson summary "$summary" --argjson extra "$extra_fields" '$summary + $extra')
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
        --arg footer "$footer_text" \
        --arg ts "$timestamp" \
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

# -- Throttle helper --
throttle_check() {
    local lock_file="$THROTTLE_DIR/last-${1}"
    local cooldown="$2"
    # Validate cooldown is numeric; fall back to 30s with a warning
    if ! [[ "$cooldown" =~ ^[0-9]+$ ]]; then
        echo "claude-notify: warning: throttle cooldown '$cooldown' is not numeric, using 30s" >&2
        cooldown=30
    fi
    if [ -f "$lock_file" ]; then
        local last_sent=$(cat "$lock_file" 2>/dev/null || echo 0)
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        local now=$(date +%s)
        [ $(( now - last_sent )) -lt "$cooldown" ] && return 1
    fi
    safe_write_file "$lock_file" "$(date +%s)"
    return 0
}
