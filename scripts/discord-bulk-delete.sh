#!/bin/bash
# discord-bulk-delete.sh
# Bulk delete messages in a Discord channel using bot token

set -euo pipefail

BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
CHANNEL_ID="${1:-}"

if [ -z "$BOT_TOKEN" ]; then
    echo "Error: DISCORD_BOT_TOKEN environment variable not set" >&2
    exit 1
fi

if [ -z "$CHANNEL_ID" ]; then
    echo "Usage: DISCORD_BOT_TOKEN=<token> $0 <channel_id>" >&2
    exit 1
fi

echo "========================================"
echo "Discord Bulk Delete"
echo "========================================"
echo "Channel ID: $CHANNEL_ID"
echo ""

# Fetch messages (up to 100 at a time)
echo "Fetching messages..."
MESSAGES=$(curl -s -H "Authorization: Bot $BOT_TOKEN" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID/messages?limit=100")

MESSAGE_IDS=$(echo "$MESSAGES" | jq -r '.[].id' 2>/dev/null || true)

if [ -z "$MESSAGE_IDS" ]; then
    echo "No messages found or error fetching messages."
    exit 0
fi

MESSAGE_COUNT=$(echo "$MESSAGE_IDS" | wc -l | tr -d ' ')
echo "Found $MESSAGE_COUNT messages to delete"
echo ""

# Delete messages one by one
deleted=0
failed=0

while IFS= read -r msg_id; do
    [ -z "$msg_id" ] && continue

    echo -n "Deleting message $msg_id... "
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

    # Rate limit: Discord allows ~5 deletes per second, be more conservative
    sleep 0.5
done <<< "$MESSAGE_IDS"

echo ""
echo "========================================"
echo "Results:"
echo "  Deleted: $deleted messages"
echo "  Failed: $failed messages"
echo "========================================"
