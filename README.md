# claude-code-notify

Discord notifications for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions.

Get notified when your Claude Code agents go idle or need permission approval — so you stop leaving them waiting.

![Discord embed example](https://img.shields.io/badge/Discord-Webhook%20Embeds-5865F2?logo=discord&logoColor=white)

## What it does

Sends color-coded Discord embeds when Claude Code:

- **Goes idle** — waiting for your input (green indicator)
- **Has subagents running** — main loop idle but background agents active (blue indicator)
- **Needs permission** — waiting for approval to run a tool (lock indicator)

Each project gets its own embed color, and notifications are throttled to avoid spam (idle: 120s, permission: 60s cooldowns, per-project).

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
| `CLAUDE_NOTIFY_IDLE_COOLDOWN` | `120` | Seconds between idle notifications (per project) |
| `CLAUDE_NOTIFY_PERMISSION_COOLDOWN` | `60` | Seconds between permission notifications (per project) |
| `CLAUDE_NOTIFY_ENABLED` | `true` | Set to `false` to disable |

### Project colors

Edit `~/.claude-notify/colors.conf` to assign Discord embed sidebar colors per project:

```
my-app=1752220
backend-api=3447003
docs-site=3066993
```

Colors are decimal RGB integers. The project name is the basename of the working directory. Default color is Discord blurple (`5865F2` = `5793266`).

Convert hex to decimal at [spycolor.com](https://www.spycolor.com).

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

## How it works

Claude Code's [hooks system](https://docs.anthropic.com/en/docs/claude-code) fires events as JSON on stdin. This script handles three hook types:

- **`Notification`** (with `idle_prompt` or `permission_prompt` matcher) — builds and sends a Discord embed
- **`SubagentStart`** / **`SubagentStop`** — tracks per-project subagent counts in `/tmp/claude-notify/`

Throttle state is stored in `/tmp/claude-notify/` and resets on reboot.

## License

MIT
