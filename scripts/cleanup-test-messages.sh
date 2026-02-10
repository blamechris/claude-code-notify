#!/bin/bash
# cleanup-test-messages.sh
# Delete all test messages (test-proj-* embeds) from Discord channel
#
# Environment variables:
#   DISCORD_BOT_TOKEN - Bot token from Discord Developer Portal (required)
#   DISCORD_CHANNEL_ID - Channel ID to clean (required, or pass as arg)
#   DISCORD_DELETE_DELAY - Seconds to wait between deletions (default: 0.5)
#   CLAUDE_NOTIFY_DIR - Config directory (default: ~/.claude-notify)

set -euo pipefail

# Load config
NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"

# Get credentials from args or env
BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
CHANNEL_ID="${1:-${DISCORD_CHANNEL_ID:-}}"
DELETE_DELAY="${DISCORD_DELETE_DELAY:-0.5}"

# Load from .env if not in environment
if [ -z "$BOT_TOKEN" ] && [ -f "$NOTIFY_DIR/.env" ]; then
    BOT_TOKEN=$(grep -m1 '^DISCORD_BOT_TOKEN=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -z "$CHANNEL_ID" ] && [ -f "$NOTIFY_DIR/.env" ]; then
    CHANNEL_ID=$(grep -m1 '^DISCORD_CHANNEL_ID=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -z "$BOT_TOKEN" ]; then
    echo "Error: DISCORD_BOT_TOKEN not set (provide via env var, .env, or export)" >&2
    exit 1
fi

if [ -z "$CHANNEL_ID" ]; then
    echo "Error: DISCORD_CHANNEL_ID not set (provide as arg or in .env)" >&2
    echo "Usage: $0 [channel_id]" >&2
    exit 1
fi

# Validate channel ID
if ! [[ "$CHANNEL_ID" =~ ^[0-9]{17,19}$ ]]; then
    echo "Error: Invalid channel ID '$CHANNEL_ID' (must be 17-19 digits)" >&2
    exit 1
fi

echo "========================================"
echo "Cleanup Test Messages"
echo "========================================"
echo "Channel ID: $CHANNEL_ID"
echo "Pattern: test-proj-* embeds"
echo ""

# Fetch messages (up to 100 at a time)
echo "Fetching messages..."
MESSAGES=$(curl -s -H "Authorization: Bot $BOT_TOKEN" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID/messages?limit=100")

# Parse messages and filter for test-proj-* in embed titles
if ! TEST_MESSAGE_IDS=$(echo "$MESSAGES" | jq -r '
    .[] |
    select(.embeds? | length > 0) |
    select(.embeds[0].title? // "" | test("test-proj-")) |
    .id
' 2>&1); then
    echo "Error: Failed to parse Discord API response. Check token and channel ID." >&2
    exit 1
fi

if [ -z "$TEST_MESSAGE_IDS" ]; then
    echo "No test messages found."
    exit 0
fi

MESSAGE_COUNT=$(echo "$TEST_MESSAGE_IDS" | wc -l | tr -d ' ')
echo "Found $MESSAGE_COUNT test messages to delete"
echo ""

# Delete messages one by one
deleted=0
failed=0

while IFS= read -r msg_id; do
    [ -z "$msg_id" ] && continue

    echo -n "Deleting test message $msg_id... "
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -H "Authorization: Bot $BOT_TOKEN" \
        "https://discord.com/api/v10/channels/$CHANNEL_ID/messages/$msg_id")

    if [ "$HTTP_CODE" = "204" ]; then
        echo "✓"
        deleted=$((deleted + 1))
    else
        echo "✗ (HTTP $HTTP_CODE)"
        failed=$((failed + 1))
    fi

    # Rate limit: Discord allows ~5 deletes per second, be conservative
    sleep "$DELETE_DELAY"
done <<< "$TEST_MESSAGE_IDS"

echo ""
echo "========================================"
echo "Results:"
echo "  Deleted: $deleted test messages"
echo "  Failed: $failed messages"
echo "========================================"
