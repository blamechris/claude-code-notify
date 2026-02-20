#!/bin/bash
# lib/notify-helpers.sh -- Shared functions for claude-code-notify
#
# Sourced by claude-notify.sh and test files. NOT meant to be executed directly.
#
# Required variables (set before calling helpers that need them):
#   THROTTLE_DIR  -- path to state/throttle directory
#
# Optional variables (only required before calling helpers that use them):
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
    # Guard: only allow valid shell variable names (prevents eval injection)
    [[ "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    eval "[ -z \"\${${var_name}:-}\" ]" || return 0
    local val
    val=$(grep -m1 "^${var_name}=" "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
    # Strip surrounding quotes (double or single) — common .env convention
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
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
    [[ "$seconds" =~ ^[0-9]+$ ]] || { echo "0s"; return; }
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
    # Atomic write: temp file + mv (same dir = same filesystem = atomic rename)
    local tmp
    if tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) && printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
        if ! mv -f "$tmp" "$file" 2>/dev/null; then
            rm -f "$tmp" 2>/dev/null || true
            # Fallback to direct write
            printf '%s\n' "$content" > "$file" 2>/dev/null || \
                echo "claude-notify: warning: failed to write to $file" >&2
        fi
    else
        # mktemp or printf failed — fallback to direct write
        [ -n "${tmp:-}" ] && rm -f "$tmp" 2>/dev/null || true
        if ! printf '%s\n' "$content" > "$file" 2>/dev/null; then
            echo "claude-notify: warning: failed to write to $file" >&2
        fi
    fi
    return 0
}

# -- Status state helpers --

read_status_state() {
    local file="$THROTTLE_DIR/status-state-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_status_state() {
    local new_state="$1"
    local current_state
    current_state="$(read_status_state)"

    safe_write_file "$THROTTLE_DIR/status-state-${PROJECT_NAME}" "$new_state"
    # Only update last-state-change on actual transitions (not same-state writes)
    if [ "$current_state" != "$new_state" ]; then
        write_last_state_change "$(date +%s)"
    fi
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

read_subagent_count() {
    local scf="${SUBAGENT_COUNT_FILE:-}"
    if [ -n "$scf" ] && [ -f "$scf" ]; then
        cat "$scf" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

read_bg_bash_count() {
    local file="$THROTTLE_DIR/bg-bash-count-${PROJECT_NAME}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

write_bg_bash_count() {
    safe_write_file "$THROTTLE_DIR/bg-bash-count-${PROJECT_NAME}" "$1"
}

read_peak_bg_bash() {
    local file="$THROTTLE_DIR/peak-bg-bash-${PROJECT_NAME}"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

write_peak_bg_bash() {
    safe_write_file "$THROTTLE_DIR/peak-bg-bash-${PROJECT_NAME}" "$1"
}

read_session_id() {
    local file="$THROTTLE_DIR/session-id-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_session_id() {
    safe_write_file "$THROTTLE_DIR/session-id-${PROJECT_NAME}" "$1"
}

read_last_state_change() {
    local file="$THROTTLE_DIR/last-state-change-${PROJECT_NAME}"
    [ -f "$file" ] && cat "$file" 2>/dev/null || true
}

write_last_state_change() {
    safe_write_file "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}" "$1"
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
    rm -f "$THROTTLE_DIR/bg-bash-count-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/peak-bg-bash-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/last-state-change-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/heartbeat-pid-${PROJECT_NAME}" 2>/dev/null || true
    rm -f "$THROTTLE_DIR/session-id-${PROJECT_NAME}" 2>/dev/null || true
}

# -- Project colors (Discord embed sidebar, decimal RGB) --
# Customize these for your projects. Color values are decimal integers.
# Use https://www.spycolor.com to convert hex → decimal.
get_project_color() {
    local project="$1"

    # Check for user overrides in config file
    if [ -f "$NOTIFY_DIR/colors.conf" ]; then
        local escaped_project="${project//./\\.}"
        local color
        color=$(grep -m1 "^${escaped_project}=" "$NOTIFY_DIR/colors.conf" 2>/dev/null | cut -d= -f2- || true)
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

# -- Disabled state check --

# Check whether notifications are disabled (via .disabled file or env var).
# Returns 0 if disabled, 1 if enabled. Requires $NOTIFY_DIR to be set.
check_disabled() {
    [ -f "$NOTIFY_DIR/.disabled" ] || [ "${CLAUDE_NOTIFY_ENABLED:-}" = "false" ]
}

# -- Build extra context fields --

# Builds optional Discord embed fields from session context.
# Accepts context values as parameters instead of reading globals.
# Args: session_id, permission_mode, cwd, tool_name, tool_input
build_extra_fields() {
    local session_id="${1:-}"
    local permission_mode="${2:-}"
    local cwd="${3:-}"
    local tool_name="${4:-}"
    local tool_input="${5:-}"
    local show_session="${CLAUDE_NOTIFY_SHOW_SESSION_INFO:-false}"
    local show_path="${CLAUDE_NOTIFY_SHOW_FULL_PATH:-false}"
    local show_tool="${CLAUDE_NOTIFY_SHOW_TOOL_INFO:-false}"

    # Fast path: skip jq entirely when no optional fields are enabled
    if [ "$show_session" != "true" ] && [ "$show_path" != "true" ] && [ "$show_tool" != "true" ]; then
        echo "[]"
        return
    fi

    # Pre-process tool detail (needs separate jq for tool_input parsing)
    # WARNING: commands may contain secrets (API keys, tokens). See README security considerations.
    local tool_detail=""
    if [ "$show_tool" = "true" ] && [ -n "$tool_name" ] && [ -n "$tool_input" ] && [ "$tool_input" != "null" ]; then
        tool_detail=$(echo "$tool_input" | jq -r 'if type == "object" then (.command // .file_path // "...") else . end' 2>/dev/null)
        if [ "${#tool_detail}" -gt 1000 ]; then
            tool_detail="${tool_detail:0:997}..."
        fi
        [ "$tool_detail" = "null" ] && tool_detail=""
    fi

    # Build all fields in a single jq call (replaces up to 5 incremental jq calls)
    jq -c -n \
        --arg show_session "$show_session" \
        --arg sid "${session_id:0:8}" \
        --arg perm "$permission_mode" \
        --arg show_path "$show_path" \
        --arg cwd "$cwd" \
        --arg show_tool "$show_tool" \
        --arg tool "$tool_name" \
        --arg detail "$tool_detail" \
        '[
            if $show_session == "true" and ($sid | length) > 0 then
                {"name": "Session", "value": $sid, "inline": true}
            else empty end,
            if $show_session == "true" and ($perm | length) > 0 then
                {"name": "Permission Mode", "value": $perm, "inline": true}
            else empty end,
            if $show_path == "true" and ($cwd | length) > 0 then
                {"name": "Path", "value": $cwd, "inline": false}
            else empty end,
            if $show_tool == "true" and ($tool | length) > 0 then
                {"name": "Tool", "value": $tool, "inline": true}
            else empty end,
            if $show_tool == "true" and ($tool | length) > 0 and ($detail | length) > 0 then
                {"name": "Command", "value": $detail, "inline": false}
            else empty end
        ]'
}

# -- Build status payload --
# Builds a Discord embed payload for any state in the lifecycle.
# Caller must set $SUBAGENT_COUNT_FILE and pass extra_fields (from build_extra_fields).
build_status_payload() {
    local state="$1"
    local extra="${2:-}"
    local extra_fields="${3:-[]}"
    local title color fields
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local bot_name="${CLAUDE_NOTIFY_BOT_NAME:-Claude Code}"

    local footer_text="$bot_name"
    local session_start=$(read_session_start)
    if [ -n "$session_start" ] && [ "$session_start" != "0" ]; then
        local now=$(date +%s)
        local elapsed=$(( now - session_start ))
        if [ "$elapsed" -ge 0 ]; then
            footer_text="${bot_name} · $(format_duration $elapsed)"
        fi
    fi

    # Stale detection: append "(stale?)" to title if state unchanged for too long
    local stale_suffix=""
    local stale_threshold="${CLAUDE_NOTIFY_STALE_THRESHOLD:-18000}"
    if ! [[ "$stale_threshold" =~ ^[0-9]+$ ]]; then
        stale_threshold=18000
    fi
    local last_change=$(read_last_state_change)
    if [ -n "$last_change" ] && [[ "$last_change" =~ ^[0-9]+$ ]]; then
        local now_stale=$(date +%s)
        local state_age=$(( now_stale - last_change ))
        if [ "$state_age" -gt "$stale_threshold" ]; then
            stale_suffix=" (stale?)"
        fi
    fi

    case "$state" in
        online)
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_ONLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="🟢 ${PROJECT_NAME} — Session Online${stale_suffix}"
            local tc=$(read_tool_count)
            local bg_bashes=$(read_bg_bash_count)
            local subs=$(read_subagent_count)
            if [ "${CLAUDE_NOTIFY_SHOW_ACTIVITY:-false}" = "true" ] && [ "$tc" -gt 0 ] 2>/dev/null; then
                local last_tool=$(read_last_tool)
                fields=$(jq -c -n \
                    --arg tc "$tc" \
                    --arg last_tool "${last_tool:-}" \
                    --arg subs "${subs:-0}" \
                    --arg bg "${bg_bashes:-0}" \
                    --argjson ef "$extra_fields" \
                    '[
                        {"name": "Tools Used", "value": $tc, "inline": true},
                        if ($last_tool | length) > 0 then
                            {"name": "Last Tool", "value": $last_tool, "inline": true}
                        else empty end,
                        if ($subs | tonumber) > 0 then
                            {"name": "Subagents", "value": $subs, "inline": true}
                        else empty end,
                        if ($bg | tonumber) > 0 then
                            {"name": "BG Bashes", "value": $bg, "inline": true}
                        else empty end
                    ] + $ef')
            else
                fields=$(jq -c -n \
                    --arg subs "${subs:-0}" \
                    --arg bg "${bg_bashes:-0}" \
                    --argjson ef "$extra_fields" \
                    '[
                        {"name": "Status", "value": "Session started", "inline": false},
                        if ($subs | tonumber) > 0 then
                            {"name": "Subagents", "value": $subs, "inline": true}
                        else empty end,
                        if ($bg | tonumber) > 0 then
                            {"name": "BG Bashes", "value": $bg, "inline": true}
                        else empty end
                    ] + $ef')
            fi
            ;;
        idle)
            color=$(get_project_color "$PROJECT_NAME")
            title="🦀 ${PROJECT_NAME} — Ready for input${stale_suffix}"
            local bg_bashes=$(read_bg_bash_count)
            local status_text="Waiting for input"
            if [ "$bg_bashes" -gt 0 ] 2>/dev/null; then
                local bg_label="bg bashes launched"
                [ "$bg_bashes" -eq 1 ] && bg_label="bg bash launched"
                status_text="Waiting for input (${bg_bashes} ${bg_label})"
            fi
            fields=$(jq -c -n --arg v "$status_text" --argjson ef "$extra_fields" \
                '[{"name": "Status", "value": $v, "inline": false}] + $ef')
            ;;
        idle_busy)
            color=$(get_project_color "$PROJECT_NAME")
            title="🔄 ${PROJECT_NAME} — Idle${stale_suffix}"
            local bg_bashes=$(read_bg_bash_count)
            fields=$(jq -c -n \
                --arg subs_text "**${extra}** running" \
                --arg bg "${bg_bashes:-0}" \
                --argjson ef "$extra_fields" \
                '[
                    {"name": "Status", "value": "Main loop idle, waiting for subagents", "inline": false},
                    {"name": "Subagents", "value": $subs_text, "inline": true},
                    if ($bg | tonumber) > 0 then
                        {"name": "BG Bashes", "value": $bg, "inline": true}
                    else empty end
                ] + $ef')
            ;;
        permission)
            color="${CLAUDE_NOTIFY_PERMISSION_COLOR:-16753920}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_PERMISSION_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="16753920"
            fi
            title="🔐 ${PROJECT_NAME} — Needs Approval${stale_suffix}"
            local detail=""
            if [ -n "$extra" ]; then
                if [ "${#extra}" -gt 1000 ]; then
                    detail="${extra:0:997}..."
                else
                    detail="$extra"
                fi
            fi
            fields=$(jq -c -n --arg detail "$detail" --argjson ef "$extra_fields" \
                '(if $detail != "" then
                    [{"name": "Detail", "value": $detail, "inline": false}]
                 else [] end) + $ef')
            ;;
        approved)
            color="${CLAUDE_NOTIFY_APPROVAL_COLOR:-3066993}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_APPROVAL_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="3066993"
            fi
            title="✅ ${PROJECT_NAME} — Permission Approved${stale_suffix}"
            local subs=$(read_subagent_count)
            local bg_bashes=$(read_bg_bash_count)
            fields=$(jq -c -n \
                --arg subs "${subs:-0}" \
                --arg bg "${bg_bashes:-0}" \
                --argjson ef "$extra_fields" \
                '[
                    {"name": "Status", "value": "Permission granted, tool executed successfully", "inline": false},
                    if ($subs | tonumber) > 0 then
                        {"name": "Subagents", "value": $subs, "inline": true}
                    else empty end,
                    if ($bg | tonumber) > 0 then
                        {"name": "BG Bashes", "value": $bg, "inline": true}
                    else empty end
                ] + $ef')
            ;;
        offline)
            color="${CLAUDE_NOTIFY_OFFLINE_COLOR:-15158332}"
            if ! validate_color "$color"; then
                echo "claude-notify: warning: CLAUDE_NOTIFY_OFFLINE_COLOR '$color' is out of range (0-16777215), using default" >&2
                color="15158332"
            fi
            title="🔴 ${PROJECT_NAME} — Session Offline"
            local tc=$(read_tool_count)
            local peak=$(read_peak_subagents)
            local peak_bg=$(read_peak_bg_bash)
            fields=$(jq -c -n \
                --arg tc "${tc:-0}" \
                --arg peak "${peak:-0}" \
                --arg peak_bg "${peak_bg:-0}" \
                --argjson ef "$extra_fields" \
                '[
                    if ($tc | tonumber) > 0 then
                        {"name": "Tools Used", "value": $tc, "inline": true}
                    else empty end,
                    if ($peak | tonumber) > 0 then
                        {"name": "Peak Subagents", "value": $peak, "inline": true}
                    else empty end,
                    if ($peak_bg | tonumber) > 0 then
                        {"name": "Peak BG Bashes", "value": $peak_bg, "inline": true}
                    else empty end
                ] + $ef')
            ;;
        *)
            echo "claude-notify: warning: unknown state '$state', defaulting to online" >&2
            color="${CLAUDE_NOTIFY_ONLINE_COLOR:-3066993}"
            if ! validate_color "$color"; then color="3066993"; fi
            title="🟢 ${PROJECT_NAME} — Session Online"
            fields=$(jq -c -n --argjson ef "$extra_fields" \
                '[{"name": "Status", "value": "Session started", "inline": false}] + $ef')
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

# -- Subagent PATCH decision helper --
# Determines whether a SubagentStart/Stop event should trigger a Discord PATCH.
# Returns 0 (should PATCH) or 1 (should not). Caller handles the actual PATCH.
# Accepts optional $1 = pre-read state (avoids double-read race with caller).
# Accepts optional $2 = new subagent count (bypasses throttle when 0).
should_patch_subagent_update() {
    [ -z "${CLAUDE_NOTIFY_WEBHOOK:-}" ] && return 1
    local state="${1:-$(read_status_state)}"
    local new_count="${2:-}"
    case "$state" in
        online|idle_busy|approved)
            # Count reaching 0 = all agents done; always let it through
            if [ "$new_count" = "0" ]; then
                return 0
            fi
            # idle_busy: subagent count is the primary embed content — always
            # PATCH on change to avoid stale counts from throttle collisions
            if [ "$state" = "idle_busy" ]; then
                return 0
            fi
            throttle_check "subagent-${PROJECT_NAME}" 10
            return $?
            ;;
        *) return 1 ;;
    esac
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
