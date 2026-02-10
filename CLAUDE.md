# Claude Development Notes — claude-code-notify

## Project Overview

**claude-code-notify** is a lightweight Discord notification system for Claude Code sessions. It hooks into Claude Code's event system to send color-coded embeds when agents go idle, need permission approval, or have subagents running.

- **Tech:** Bash scripts, jq, curl, Discord webhook API
- **License:** MIT
- **Author:** Christopher Pishaki

## Critical: Attribution Policy

**I am the sole author of all work in this repository.**

- NEVER include `Co-Authored-By` lines in commits
- NEVER add "Generated with Claude" or similar AI attribution
- NEVER add AI-related badges, links, or mentions in PR descriptions
- Commit messages should be clean and professional

## Git Workflow

- `main` branch, PRs for significant changes
- Direct commits OK for small fixes and refinements
- Commit format: `type(scope): description`
- Types: feat, fix, refactor, docs, chore

## Project Structure

```
claude-code-notify/
├── claude-notify.sh       # Main hook script (stdin JSON -> Discord embed)
├── install.sh             # Interactive setup (config dir, webhook, hooks registration)
├── README.md              # User documentation
├── colors.conf.example    # Example per-project color config
├── .env.example           # Example webhook URL config
├── .claude/commands/      # Claude Code skills (check-pr, agent-review)
├── scripts/               # Utility scripts
│   └── discord-bulk-delete.sh  # Bulk delete messages in a channel (requires bot token)
└── tests/                 # Pure bash test suite (53 tests, no framework)
    ├── run-tests.sh       # Test runner entry point
    ├── setup.sh           # Shared test environment setup
    ├── test-throttle.sh   # Throttle logic tests
    ├── test-colors.sh     # Color lookup tests
    ├── test-payload.sh    # Discord payload structure tests
    ├── test-subagent-count.sh  # Subagent tracking tests
    └── test-notification-cleanup*.sh  # Message cleanup feature tests
```

## Architecture

- **Hook pattern:** stdin JSON -> jq parse -> curl Discord webhook
- **Config hierarchy:** env var > `~/.claude-notify/.env` > hardcoded defaults
- **State:** `/tmp/claude-notify/` (ephemeral: throttle files, subagent counts)
- **Config:** `~/.claude-notify/` (persistent: webhook URL, colors, enabled state)

## Key Conventions

- `set -euo pipefail` in all scripts
- All JSON handling via `jq` (never raw shell substitution)
- All variables properly quoted
- Input sanitization: PROJECT_NAME stripped to `[A-Za-z0-9._-]`
- Color values validated as numeric before use
- Config dir `chmod 700`, .env file `chmod 600`
- Subagent count updates use mkdir-based locking (portable, no flock)
- Stdin read uses `read -t 5` timeout to prevent hanging

## Development

```bash
# Run tests
bash tests/run-tests.sh

# Run a single test file
bash tests/test-throttle.sh

# Bulk delete messages from Discord channel (requires bot token)
DISCORD_BOT_TOKEN=<token> bash scripts/discord-bulk-delete.sh <channel_id>
```

No build step, no dependencies beyond `jq` and `curl`.

## Discord Bot (Channel Management)

For bulk operations (clearing channels, etc.), we use a Discord bot separate from the webhook:

- **Bot ID:** 755255283692994591
- **Token location:** `~/.claude-notify/.env` (DISCORD_BOT_TOKEN)
- **Permissions needed:** `MANAGE_MESSAGES` (8192) or `ADMINISTRATOR` (8)
- **Invite URL:** `https://discord.com/oauth2/authorize?client_id=755255283692994591&permissions=8192&scope=bot`

**Note:** Bot token should NEVER be committed to git. Store in `.env` only.

## GitHub Issues

- Use labels: `enhancement`, `from-review`, `bug`
- Issues from code review get `from-review` label
