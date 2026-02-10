#!/bin/bash
# discord-bulk-delete.sh
# Bulk delete messages in a Discord channel using bot token
#
# Paginates through all messages using Discord's `before` parameter,
# deleting them one by one. Handles channels with any number of messages.
#
# Environment variables:
#   DISCORD_BOT_TOKEN - Bot token from Discord Developer Portal (required)
#   DISCORD_DELETE_DELAY - Seconds to wait between deletions (default: 0.5)

set -euo pipefail

BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
CHANNEL_ID="${1:-}"
DELETE_DELAY="${DISCORD_DELETE_DELAY:-0.5}"

if [ -z "$BOT_TOKEN" ]; then
    echo "Error: DISCORD_BOT_TOKEN environment variable not set" >&2
    exit 1
fi

if [ -z "$CHANNEL_ID" ]; then
    echo "Usage: DISCORD_BOT_TOKEN=<token> $0 <channel_id>" >&2
    exit 1
fi

# Validate channel ID is numeric (Discord IDs are 17-19 digit snowflakes)
if ! [[ "$CHANNEL_ID" =~ ^[0-9]{17,19}$ ]]; then
    echo "Error: Invalid channel ID '$CHANNEL_ID' (must be 17-19 digits)" >&2
    exit 1
fi

echo "========================================"
echo "Discord Bulk Delete"
echo "========================================"
echo "Channel ID: $CHANNEL_ID"
echo ""

deleted=0
failed=0
batch=0
before_param=""

while true; do
    batch=$((batch + 1))
    url="https://discord.com/api/v10/channels/$CHANNEL_ID/messages?limit=100"
    [ -n "$before_param" ] && url="${url}&before=${before_param}"

    echo "Fetching batch $batch..."
    MESSAGES=$(curl -s -H "Authorization: Bot $BOT_TOKEN" "$url")

    # Parse message IDs (jq errors indicate API failure, not empty results)
    if ! MESSAGE_IDS=$(echo "$MESSAGES" | jq -r '.[].id' 2>&1); then
        echo "Error: Failed to parse Discord API response. Check token and channel ID." >&2
        TRUNCATED_RESPONSE=$(echo "$MESSAGES" | head -c 200)
        if [ "${#MESSAGES}" -gt 200 ]; then
            echo "Response: ${TRUNCATED_RESPONSE}... (truncated)" >&2
        else
            echo "Response: $MESSAGES" >&2
        fi
        exit 1
    fi

    # No more messages — done
    if [ -z "$MESSAGE_IDS" ]; then
        [ "$batch" -eq 1 ] && echo "No messages found in channel."
        break
    fi

    MESSAGE_COUNT=$(echo "$MESSAGE_IDS" | wc -l | tr -d ' ')
    echo "Found $MESSAGE_COUNT messages in batch $batch"

    # Discord returns messages newest-first by default.
    # Track the last (oldest) message ID for `before=` pagination.
    LAST_ID=""

    while IFS= read -r msg_id; do
        [ -z "$msg_id" ] && continue
        LAST_ID="$msg_id"

        echo -n "  Deleting $msg_id... "
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE \
            -H "Authorization: Bot $BOT_TOKEN" \
            "https://discord.com/api/v10/channels/$CHANNEL_ID/messages/$msg_id")

        if [ "$HTTP_CODE" = "204" ]; then
            echo "done"
            deleted=$((deleted + 1))
        elif [ "$HTTP_CODE" = "429" ]; then
            echo "rate limited, waiting..."
            sleep 5
            # Retry once
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -X DELETE \
                -H "Authorization: Bot $BOT_TOKEN" \
                "https://discord.com/api/v10/channels/$CHANNEL_ID/messages/$msg_id")
            if [ "$HTTP_CODE" = "204" ]; then
                echo "  Retry: done"
                deleted=$((deleted + 1))
            else
                echo "  Retry: failed (HTTP $HTTP_CODE)"
                failed=$((failed + 1))
            fi
        else
            echo "failed (HTTP $HTTP_CODE)"
            failed=$((failed + 1))
        fi

        sleep "$DELETE_DELAY"
    done <<< "$MESSAGE_IDS"

    # If we got fewer than 100 messages, this was the last page
    [ "$MESSAGE_COUNT" -lt 100 ] && break

    # Set before= to oldest message ID for next page
    before_param="$LAST_ID"
done

echo ""
echo "========================================"
echo "Results:"
echo "  Deleted: $deleted messages"
echo "  Failed:  $failed messages"
echo "  Batches: $batch"
echo "========================================"
