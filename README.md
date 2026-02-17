# claude-code-notify

Discord notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions.

Get notified when your Claude Code agents go idle or need permission approval — so you stop leaving them waiting.

![Discord embed example](https://img.shields.io/badge/Discord-Webhook%20Embeds-5865F2?logo=discord&logoColor=white)

## What it does

Maintains a **single status message per project** in your Discord channel, updated in-place through the full session lifecycle:

- **Session Online** — green embed when Claude Code starts (`🟢`)
- **Ready for input** — project-colored embed when the agent goes idle (`🦀`)
- **Idle with subagents** — project-colored embed when background agents are running (`🔄`)
- **Background bashes** — shows count of background bash commands launched in the session
- **Needs Approval** — orange embed when a permission prompt appears (`🔐`)
- **Permission Approved** — green embed after you approve (`✅`)
- **Session Offline** — red embed when the session ends (`🔴`)

Each project gets one message that PATCHes through these states. No message spam, no cleanup needed — just a live dashboard of your active sessions.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (uses the hooks system)
- `jq` — `brew install jq` / `apt install jq`
- `curl`
- A Discord webhook URL

## Quick start

```bash
git clone https://github.com/blamechris/claude-code-notify.git
cd claude-code-notify
./install.sh
```

The installer will:
1. Create `~/.claude-notify/` config directory
2. Prompt for your Discord webhook URL
3. Add hooks to `~/.claude/settings.json`

## Configuration

All config lives in `~/.claude-notify/` (override with `CLAUDE_NOTIFY_DIR` env var).

| File | Purpose |
|------|---------|
| `.env` | `CLAUDE_NOTIFY_WEBHOOK=https://discord.com/api/webhooks/...` |
| `colors.conf` | Per-project embed colors (see below) |
| `.disabled` | Touch this file to disable notifications |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_NOTIFY_WEBHOOK` | *(required)* | Discord webhook URL |
| `CLAUDE_NOTIFY_DIR` | `~/.claude-notify` | Config directory path |
| `CLAUDE_NOTIFY_BOT_NAME` | `Claude Code` | Webhook bot display name |
| `CLAUDE_NOTIFY_PERMISSION_COLOR` | `16753920` | Color for permission prompts (orange #FFA500) |
| `CLAUDE_NOTIFY_APPROVAL_COLOR` | `3066993` | Color for approved permissions (green #2ECC71) |
| `CLAUDE_NOTIFY_ONLINE_COLOR` | `3066993` | Color for session online (green #2ECC71) |
| `CLAUDE_NOTIFY_OFFLINE_COLOR` | `15158332` | Color for session offline (red #E74C3C) |
| `CLAUDE_NOTIFY_ENABLED` | `true` | Set to `false` to disable |
| `CLAUDE_NOTIFY_SHOW_SESSION_INFO` | `false` | Show session ID and permission mode in notifications |
| `CLAUDE_NOTIFY_SHOW_TOOL_INFO` | `false` | Show tool name and command details (for permissions) |
| `CLAUDE_NOTIFY_SHOW_FULL_PATH` | `false` | Show full working directory path instead of project name |
| `CLAUDE_NOTIFY_SHOW_ACTIVITY` | `false` | Show activity metrics (Tools Used, Last Tool) in online embed. Enables periodic heartbeat PATCHes |
| `CLAUDE_NOTIFY_ACTIVITY_THROTTLE` | `30` | Seconds between heartbeat updates when activity tracking is enabled |
| `CLAUDE_NOTIFY_HEARTBEAT_INTERVAL` | `300` | Seconds between background heartbeat PATCHes (keeps elapsed time fresh). Set to `0` to disable. Min effective: 10 |
| `CLAUDE_NOTIFY_STALE_THRESHOLD` | `18000` | Seconds before a session in the same state gets a "(stale?)" title suffix (default 5 hours) |
| `DISCORD_BOT_TOKEN` | *(optional)* | Bot token for bulk operations (channel cleanup, not needed for hooks) |
| `DISCORD_DELETE_DELAY` | `0.5` | Seconds between deletions in bulk delete script (rate limiting) |

### Project colors

Edit `~/.claude-notify/colors.conf` to assign Discord embed sidebar colors per project:

```
my-app=1752220
backend-api=3447003
docs-site=3066993
```

Colors are decimal RGB integers. The project name is the basename of the working directory. Default color is Discord blurple (`5865F2` = `5793266`).

Convert hex to decimal at [spycolor.com](https://www.spycolor.com).

### Cleaning up test messages

When running tests, `test-proj-*` messages are created in your Discord channel. These are automatically cleaned up when you run the full test suite:

```bash
# Test suite automatically cleans up test messages at the end
bash tests/run-tests.sh
```

You can also manually clean up test messages:

```bash
# Run manually
bash scripts/cleanup-test-messages.sh

# Or with explicit credentials
DISCORD_BOT_TOKEN=<token> bash scripts/cleanup-test-messages.sh <channel_id>
```

This script:
- Searches for messages with embed titles containing `test-proj-`
- Deletes them from your Discord channel
- Requires `DISCORD_BOT_TOKEN` and `DISCORD_CHANNEL_ID` (from `.env` or env vars)

### Extra context in notifications

By default, notifications show minimal information (project name, status). You can enable additional context fields:

```bash
# In ~/.claude-notify/.env

# Show session ID and permission mode
CLAUDE_NOTIFY_SHOW_SESSION_INFO=true

# Show tool name and command details (for permissions)
CLAUDE_NOTIFY_SHOW_TOOL_INFO=true

# Show full working directory path instead of just project name
CLAUDE_NOTIFY_SHOW_FULL_PATH=true

# Show activity metrics (tool count, last tool) in online embed
CLAUDE_NOTIFY_SHOW_ACTIVITY=true

# Seconds between heartbeat updates (default 30)
# CLAUDE_NOTIFY_ACTIVITY_THROTTLE=30
```

**What you'll see with these enabled:**

**Session info:**
- Session ID (shortened to 8 chars for brevity)
- Permission mode (default, permissive, auto-approve, etc.)

**Tool info (permissions only):**
- Tool name (Bash, Edit, Write, etc.)
- Command or operation details (truncated to 1000 chars for safety)

**Full path:**
- Complete working directory path instead of basename

**Activity tracking:**
- Tools Used — total tool calls in the session
- Last Tool — most recent tool name
- Subagent count (always shown when > 0, even without activity tracking)
- BG Bashes — background bash commands launched (always shown when > 0)

These flags default to `false` to keep notifications clean. Enable them when you need more diagnostic information or are managing multiple sessions.

Common colors:
| Color | Hex | Decimal |
|-------|-----|---------|
| Teal | `#1ABC9C` | `1752220` |
| Purple | `#9B59B6` | `10181046` |
| Blue | `#3498DB` | `3447003` |
| Green | `#2ECC71` | `3066993` |
| Orange | `#E67E22` | `15105570` |
| Red | `#E74C3C` | `15158332` |
| Blurple | `#5865F2` | `5793266` |

## Manual setup

If you prefer not to use the installer:

1. Copy `claude-notify.sh` somewhere permanent
2. Make it executable: `chmod +x claude-notify.sh`
3. Create `~/.claude-notify/.env` with your webhook URL
4. Add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ],
    "SessionStart": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [{ "type": "command", "command": "/path/to/claude-notify.sh" }]
      }
    ]
  }
}
```

## Enable / disable

```bash
# Disable notifications
touch ~/.claude-notify/.disabled

# Re-enable
rm ~/.claude-notify/.disabled

# Or via env var
export CLAUDE_NOTIFY_ENABLED=false
```

## Uninstall

```bash
cd claude-code-notify
./install.sh --uninstall
```

This removes hooks from `settings.json` but leaves your config in `~/.claude-notify/`.

## Troubleshooting

**Notifications aren't showing up in Discord**
1. Verify your webhook URL: `curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d '{"content":"test"}' "YOUR_WEBHOOK_URL"` — should return `204`
2. Check if notifications are disabled: `ls ~/.claude-notify/.disabled` — if this file exists, remove it
3. Check the webhook URL is set: `cat ~/.claude-notify/.env`
4. Verify hooks are registered: `cat ~/.claude/settings.json | jq '.hooks'`

**Getting "jq is required" error**
- macOS: `brew install jq`
- Ubuntu/Debian: `sudo apt install jq`
- Other: see [jq downloads](https://jqlang.github.io/jq/download/)

**Webhook returns HTTP 429 (rate limited)**
- Discord webhooks have a rate limit of ~30 requests per minute per webhook
- Since we PATCH a single message instead of posting new ones, rate limiting should be rare
- If you have many projects active simultaneously, consider using separate webhooks per project

**Subagent count seems wrong**
- Subagent counts are tracked in `/tmp/claude-notify/` and reset on reboot
- To manually reset: `rm /tmp/claude-notify/subagent-count-*`

**Stale indicator showing incorrectly**
- The "(stale?)" suffix appears when a session stays in the same state for >5 hours (configurable via `CLAUDE_NOTIFY_STALE_THRESHOLD`)
- To reset: the indicator clears automatically when the state changes
- To adjust the threshold: set `CLAUDE_NOTIFY_STALE_THRESHOLD` in `~/.claude-notify/.env` (seconds)

## How it works

Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code) fires events as JSON on stdin. This script maintains a **single Discord message per project** through a state machine. Important states (idle, permission) DELETE the old message and POST a new one so they appear at the bottom of the channel and trigger Discord pings. Background transitions (online, approved, offline) use PATCH to update quietly in place.

```
SessionStart   → DELETE old + POST  "🟢 Session Online"
Agent idle     → DELETE old + POST  "🦀 Ready for input"   (ping)
User input     → PATCH               "🟢 Session Online"
Permission     → DELETE old + POST  "🔐 Needs Approval"   (ping)
User approves  → PATCH               "✅ Permission Approved"
Agent works    → PATCH               "🟢 Session Online"
SessionEnd     → PATCH               "🔴 Session Offline"
```

Hook types used:
- **`SessionStart`** — deletes previous offline message, creates new status message (DELETE + POST)
- **`Notification`** (`idle_prompt`, `permission_prompt`) — repost for visibility (DELETE + POST)
- **`PostToolUse`** — detects approvals, user activity, and background bash commands (PATCH, quiet)
- **`SessionEnd`** — marks offline (PATCH), cleans up state files
- **`SubagentStart`** / **`SubagentStop`** — tracks per-project subagent counts

### Subagent tracking

Subagent counts always display in the online embed when greater than zero — no configuration flags needed. When a `SubagentStart` or `SubagentStop` event fires, the script increments/decrements the count and PATCHes the embed (throttled to one update per 10 seconds to avoid Discord rate limits). The count resets automatically at session end.

### Background bash tracking

Background bash commands (launched with `run_in_background: true`) are counted automatically. The count is a monotonic counter — it increments when a background bash is launched but cannot decrement since no hook fires when a background bash completes. Think of it as "background bashes launched this session."

The count displays as:
- **Online embed** — "BG Bashes" field (when > 0)
- **Idle embed** — included in status text (when > 0)
- **Offline embed** — "Peak BG Bashes" field showing the session maximum

The counter resets on session start.

### Heartbeat & stale detection

A background process (`lib/heartbeat.sh`) spawns on `SessionStart` and is killed on `SessionEnd`. It PATCHes the embed at a regular interval (default every 5 minutes) to keep the footer's elapsed time accurate between hook events.

**Configuration:**
- `CLAUDE_NOTIFY_HEARTBEAT_INTERVAL` — seconds between PATCHes (default `300`, set to `0` to disable, minimum effective value: `10`)
- `CLAUDE_NOTIFY_STALE_THRESHOLD` — seconds before a session in the same state gets a "(stale?)" title suffix (default `18000` = 5 hours)

Stale detection flags sessions that may have been abandoned — if the state hasn't changed for longer than the threshold, the embed title gets a "(stale?)" suffix. The suffix clears automatically when the state changes.

### Activity tracking

When `CLAUDE_NOTIFY_SHOW_ACTIVITY=true`, the online embed also shows **Tools Used** (total count) and **Last Tool** (most recent tool name). Each `PostToolUse` event triggers a throttled heartbeat PATCH (default 30s interval, configurable via `CLAUDE_NOTIFY_ACTIVITY_THROTTLE`).

State is stored in `/tmp/claude-notify/` (`status-msg-PROJECT`, `status-state-PROJECT`) and resets on reboot.

## FAQ

**Can I use this with Slack instead of Discord?**
Not currently. The script is designed specifically for Discord webhook embeds. Slack support could be added as a future enhancement.

**Does this work on Linux?**
Yes. The script uses standard POSIX utilities plus `jq` and `curl`. Install dependencies with your package manager.

**Does this work on Windows?**
Only through WSL (Windows Subsystem for Linux). Native Windows is not supported.

**Can I have different webhook URLs per project?**
Not currently — all projects share the same webhook URL. You can differentiate projects visually using per-project colors in `~/.claude-notify/colors.conf`.

**Will this slow down Claude Code?**
No. Hook scripts run asynchronously and the notification script executes in under 100ms typically. Most PostToolUse calls are instant no-ops (state check + exit).

## License

MIT
