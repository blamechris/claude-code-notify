#!/bin/bash
# cleanup-old-approvals.sh
# Deletes old approved permission messages from Discord to reduce clutter
#
# Environment variables:
#   CLAUDE_NOTIFY_WEBHOOK - Discord webhook URL (required)
#   CLAUDE_NOTIFY_APPROVAL_TTL - Hours before deleting approvals (default: 1)
#   CLAUDE_NOTIFY_DIR - Config directory (default: ~/.claude-notify)

set -euo pipefail

# Configuration
NOTIFY_DIR="${CLAUDE_NOTIFY_DIR:-$HOME/.claude-notify}"
THROTTLE_DIR="/tmp/claude-notify"
TTL_HOURS="${CLAUDE_NOTIFY_APPROVAL_TTL:-1}"
TTL_SECONDS=$((TTL_HOURS * 3600))

# Load webhook URL
WEBHOOK_URL="${CLAUDE_NOTIFY_WEBHOOK:-}"
if [ -z "$WEBHOOK_URL" ] && [ -f "$NOTIFY_DIR/.env" ]; then
    WEBHOOK_URL=$(grep -m1 '^CLAUDE_NOTIFY_WEBHOOK=' "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -z "$WEBHOOK_URL" ]; then
    echo "Error: CLAUDE_NOTIFY_WEBHOOK not set" >&2
    exit 1
fi

# Extract webhook ID and token
WEBHOOK_ID_TOKEN=$(echo "$WEBHOOK_URL" | sed -n 's|.*/webhooks/\([0-9]*/[^/?]*\).*|\1|p')
if [ -z "$WEBHOOK_ID_TOKEN" ]; then
    echo "Error: Invalid webhook URL format" >&2
    exit 1
fi

echo "========================================"
echo "Cleanup Old Approved Permissions"
echo "========================================"
echo "TTL: $TTL_HOURS hours ($TTL_SECONDS seconds)"
echo ""

# Find all permission message ID files
MESSAGE_FILES=$(find "$THROTTLE_DIR" -name "msg-*-permission_prompt" 2>/dev/null || true)

if [ -z "$MESSAGE_FILES" ]; then
    echo "No permission messages found."
    exit 0
fi

NOW=$(date +%s)
deleted=0
kept=0

while IFS= read -r msg_file; do
    [ -z "$msg_file" ] && continue
    
    # Extract project name from filename
    PROJECT=$(basename "$msg_file" | sed 's/^msg-//;s/-permission_prompt$//')
    
    # Get message ID
    MESSAGE_ID=$(cat "$msg_file" 2>/dev/null || true)
    [ -z "$MESSAGE_ID" ] && continue
    
    # Check if this permission was approved (has a last-permission timestamp)
    TIMESTAMP_FILE="$THROTTLE_DIR/last-permission-$PROJECT"
    if [ ! -f "$TIMESTAMP_FILE" ]; then
        echo "  $PROJECT: No timestamp, skipping"
        kept=$((kept + 1))
        continue
    fi
    
    TIMESTAMP=$(cat "$TIMESTAMP_FILE" 2>/dev/null || echo 0)
    AGE=$((NOW - TIMESTAMP))
    
    if [ "$AGE" -gt "$TTL_SECONDS" ]; then
        echo -n "  $PROJECT: ${AGE}s old (> ${TTL_SECONDS}s) - Deleting... "
        
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE \
            "https://discord.com/api/webhooks/${WEBHOOK_ID_TOKEN}/messages/${MESSAGE_ID}")
        
        if [ "$HTTP_CODE" = "204" ]; then
            echo "✓"
            deleted=$((deleted + 1))
            # Clean up the message ID file
            rm -f "$msg_file" 2>/dev/null || true
        else
            echo "✗ (HTTP $HTTP_CODE)"
        fi
    else
        echo "  $PROJECT: ${AGE}s old (< ${TTL_SECONDS}s) - Keeping"
        kept=$((kept + 1))
    fi
done <<< "$MESSAGE_FILES"

echo ""
echo "========================================"
echo "Results:"
echo "  Deleted: $deleted messages"
echo "  Kept: $kept messages"
echo "========================================"
