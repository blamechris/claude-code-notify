# Integration Tests

These tests post **real Discord messages** and require webhook credentials. They are not run in CI.

## Running Integration Tests

```bash
# Make sure your webhook is configured
grep CLAUDE_NOTIFY_WEBHOOK ~/.claude-notify/.env

# Run integration tests
bash tests/integration/test-notification-cleanup.sh
bash tests/integration/test-notification-cleanup-auto.sh
```

## Tests

- `test-notification-cleanup.sh` - Tests CLAUDE_NOTIFY_CLEANUP_OLD feature (message replacement)
- `test-notification-cleanup-auto.sh` - Non-interactive version for automated testing

These tests verify that:
1. Same project + event type replaces messages
2. Different projects keep separate messages
3. Different event types keep separate messages
4. Message IDs are tracked correctly

**Note:** These will create test-proj-* embeds in your Discord channel. Run `bash scripts/cleanup-test-messages.sh` to clean them up.
