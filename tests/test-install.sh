#!/bin/bash
# test-install.sh -- Tests for install.sh
#
# Verifies that:
#   - Config directory is created with correct permissions
#   - .env file is created from webhook input
#   - .env file has 600 permissions
#   - settings.json gets hooks registered for all 6 event types
#   - Idempotent: re-running doesn't duplicate hooks
#   - Uninstall removes hooks from settings.json
#   - Config preserved after uninstall
#   - colors.conf.example is copied
#   - Empty webhook creates placeholder .env
#   - Dependency checks (jq, curl, script presence)

set -uo pipefail

# Set up test environment if running standalone
[ -z "${HELPER_FILE:-}" ] && source "$(dirname "$0")/setup.sh"

source "$HELPER_FILE"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
INSTALL_SCRIPT="$PROJECT_DIR/install.sh"

# Override HOME to isolate from real config
ORIG_HOME="$HOME"
export HOME="$TEST_TMPDIR/home"
mkdir -p "$HOME/.claude"

# Use a dedicated config dir for install tests
INSTALL_CONFIG_DIR="$TEST_TMPDIR/install-config"
export CLAUDE_NOTIFY_DIR="$INSTALL_CONFIG_DIR"

# -- Tests --

# 1. Fresh install with webhook URL
echo "https://discord.com/api/webhooks/123456/test-token" | bash "$INSTALL_SCRIPT" >/dev/null 2>&1
assert_true "Config directory created" [ -d "$INSTALL_CONFIG_DIR" ]

# 2. .env file created with webhook
env_content=$(cat "$INSTALL_CONFIG_DIR/.env" 2>/dev/null || true)
assert_match ".env contains webhook URL" "CLAUDE_NOTIFY_WEBHOOK=https://discord.com/api/webhooks/123456/test-token" "$env_content"

# 3. .env file permissions (600)
env_perms=$(stat -c '%a' "$INSTALL_CONFIG_DIR/.env" 2>/dev/null || stat -f '%Lp' "$INSTALL_CONFIG_DIR/.env" 2>/dev/null)
assert_eq ".env has 600 permissions" "600" "$env_perms"

# 4. Config dir permissions (700)
dir_perms=$(stat -c '%a' "$INSTALL_CONFIG_DIR" 2>/dev/null || stat -f '%Lp' "$INSTALL_CONFIG_DIR" 2>/dev/null)
assert_eq "Config dir has 700 permissions" "700" "$dir_perms"

# 5. settings.json has hooks
settings_hooks=$(jq '.hooks | keys | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_true "settings.json has hooks" [ "$settings_hooks" -gt 0 ]

# 6. Hooks reference claude-notify.sh
has_script=$(jq -r '[.. | strings] | map(select(test("claude-notify.sh"))) | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_true "settings.json references claude-notify.sh" [ "$has_script" -gt 0 ]

# 7-12. All 6 hook events registered
for event in Notification SubagentStart SubagentStop SessionStart SessionEnd PostToolUse; do
    has_event=$(jq --arg e "$event" '.hooks[$e] | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
    assert_true "Hook event '$event' registered" [ "$has_event" -gt 0 ]
done

# 13. Notification has 2 matchers (idle_prompt + permission_prompt)
notif_count=$(jq '.hooks.Notification | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Notification has 2 matchers" "2" "$notif_count"

# 14. Notification matchers are idle_prompt and permission_prompt
idle_matcher=$(jq -r '.hooks.Notification[] | select(.matcher == "idle_prompt") | .matcher' "$HOME/.claude/settings.json" 2>/dev/null || true)
assert_eq "idle_prompt matcher present" "idle_prompt" "$idle_matcher"

perm_matcher=$(jq -r '.hooks.Notification[] | select(.matcher == "permission_prompt") | .matcher' "$HOME/.claude/settings.json" 2>/dev/null || true)
assert_eq "permission_prompt matcher present" "permission_prompt" "$perm_matcher"

# 15. Idempotent: re-running doesn't duplicate hooks
bash "$INSTALL_SCRIPT" >/dev/null 2>&1
notif_count_after=$(jq '.hooks.Notification | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Notification hooks not duplicated on re-run" "2" "$notif_count_after"

session_count=$(jq '.hooks.SessionStart | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "SessionStart hooks not duplicated on re-run" "1" "$session_count"

# 16. colors.conf copied from example
assert_true "colors.conf copied from example" [ -f "$INSTALL_CONFIG_DIR/colors.conf" ]

# 17. Uninstall removes hooks
bash "$INSTALL_SCRIPT" --uninstall >/dev/null 2>&1
has_script_after=$(jq -r '[.. | strings] | map(select(test("claude-notify.sh"))) | length' "$HOME/.claude/settings.json" 2>/dev/null || echo "0")
assert_eq "Uninstall removes hooks" "0" "$has_script_after"

# 18. Config preserved after uninstall
assert_true "Config dir preserved after uninstall" [ -f "$INSTALL_CONFIG_DIR/.env" ]

# 19. Empty webhook input creates placeholder .env
rm -f "$INSTALL_CONFIG_DIR/.env"
# Re-install with empty webhook (need to also reset settings.json so hooks get added)
echo '{}' > "$HOME/.claude/settings.json"
echo "" | bash "$INSTALL_SCRIPT" >/dev/null 2>&1
env_content=$(cat "$INSTALL_CONFIG_DIR/.env" 2>/dev/null || true)
assert_match "Empty webhook creates placeholder .env" "CLAUDE_NOTIFY_WEBHOOK=" "$env_content"

# 20. Webhook URL already configured skips prompt
rm -f "$INSTALL_CONFIG_DIR/.env"
echo "CLAUDE_NOTIFY_WEBHOOK=https://discord.com/api/webhooks/999/existing-token" > "$INSTALL_CONFIG_DIR/.env"
chmod 600 "$INSTALL_CONFIG_DIR/.env"
echo '{}' > "$HOME/.claude/settings.json"
bash "$INSTALL_SCRIPT" >/dev/null 2>&1
env_after=$(cat "$INSTALL_CONFIG_DIR/.env" 2>/dev/null || true)
assert_match "Existing webhook preserved" "existing-token" "$env_after"

# Restore HOME
export HOME="$ORIG_HOME"

# -- Cleanup and summary --

test_summary
rc=$?
[ "${STANDALONE:-0}" = "1" ] && rm -rf "$TEST_TMPDIR"
exit $rc
