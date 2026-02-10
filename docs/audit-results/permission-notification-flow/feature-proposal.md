# Permission Notification Interactive Flow - Feature Proposal

## Overview

Enhance permission approval notifications with visual status tracking and automatic cleanup to reduce channel clutter while surfacing important approval states.

## Current Behavior

- Permission prompts appear as Discord embeds when Claude Code needs approval
- Color determined by project (same as idle notifications)
- No visual distinction from idle notifications
- Notifications persist indefinitely (or get cleaned up on next event for same project+event)
- No indication when approval is granted

## Proposed Behavior

### Phase 1: Visual Distinction (Orange for Pending)

**When permission is requested:**
- Embed color: **Orange** (#FFA500 / 16753920) - regardless of project
- Status: "🔐 Needs Approval"
- Rationale: Orange signals urgency and distinguishes from idle (blue/teal)

### Phase 2: Status Update on Approval

**When permission is granted:**
- Update the SAME embed (edit in place)
- Change color to **Green** (#2ECC71 / 3066993)
- Update status: "✅ Approved"
- Timestamp of approval
- Keep visible until next project update

### Phase 3: Cleanup Strategy

**When project goes idle again:**
- Delete old "✅ Approved" permission messages
- OR: Move them into a threaded reply under the idle message
- Rationale: Keep channel clean while maintaining audit trail

## User Goals

1. **Distinguish approval prompts** - Stand out visually from idle notifications
2. **Track approval flow** - See when something was approved without scrolling
3. **Reduce clutter** - Don't accumulate stale approval messages
4. **Single channel** - All project notifications in one place

## Implementation Challenges

### Challenge 1: Detecting Approval Events

Claude Code may not fire a hook event when permission is granted.

**Options:**
- Check if Claude Code emits an event after permission granted (investigate docs/test)
- Poll permission state (fragile, adds complexity)
- Accept that we can only update on next event (simpler, good enough?)

### Challenge 2: Editing Discord Messages

**Requirements:**
- Need message ID (already tracked in `/tmp/claude-notify/msg-{project}-permission_prompt`)
- Need to PATCH webhook message (not DELETE + POST)
- Discord API: `PATCH /webhooks/{webhook.id}/{webhook.token}/messages/{message.id}`

**Implementation:**
```bash
# Store message ID when posting permission prompt
echo "$MESSAGE_ID" > "$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt"

# On approval event (if detectable):
OLD_MSG_ID=$(cat "$THROTTLE_DIR/msg-${PROJECT_NAME}-permission_prompt")
curl -X PATCH "$WEBHOOK_URL/messages/$OLD_MSG_ID" \
  -H "Content-Type: application/json" \
  -d '{"embeds": [{ new green embed }]}'
```

### Challenge 3: Cleanup Without Clutter

**Option A: Delete approved messages**
- Pro: Clean channel
- Con: No audit trail

**Option B: Thread approved messages**
- Pro: Audit trail preserved
- Con: Discord webhook API may not support threading
- Needs investigation: Can webhooks create threads?

**Option C: Keep until next idle (current behavior)**
- Pro: Simple, no new logic
- Con: Accumulates if permissions requested frequently

### Challenge 4: Message Type Scoping

Current cleanup is scoped per `{project}-{event_type}`:
- `msg-chroxy-idle_prompt` → separate from
- `msg-chroxy-permission_prompt`

With Phase 3 cleanup, need to:
- Delete permission messages when idle arrives
- Cross-event-type cleanup (idle deletes permission)

## Technical Constraints

1. **Webhook limitations**: Can only edit messages posted by same webhook
2. **No guaranteed approval event**: May need to work around lack of hook
3. **Race conditions**: Multiple rapid permissions could conflict
4. **Message ID persistence**: `/tmp` files cleared on reboot

## Open Questions

1. Does Claude Code fire a hook event when permission is granted?
2. Can Discord webhooks create/reply to threads?
3. Should approved messages have a TTL (e.g., delete after 5 minutes)?
4. What if user denies permission? Different color/status?

## Success Criteria

- [ ] Permission prompts always show orange (regardless of project)
- [ ] Approved permissions show green (if hook event exists)
- [ ] Old approved permissions cleaned up on next idle
- [ ] No more than 1 permission message per project visible at a time
- [ ] Audit trail preserved (either in Discord history or logs)
