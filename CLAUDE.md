# Claude Development Notes — claude-code-notify

## Project Overview

**claude-code-notify** is a lightweight Discord notification system for Claude Code sessions. It hooks into Claude Code's event system to send color-coded embeds when agents go idle, need permission approval, or have subagents running. Features approval tracking with automatic status updates (orange → green when approved).

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

**Branch Protection:**
- Required status check: `check` (CI workflow)
- Required pull requests for all changes
- Admin enforcement: DISABLED (backdoor exists for emergencies)
- **CRITICAL:** Never push directly to main without user's express permission
- Always create PRs for features, even if you have bypass permissions

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
│   ├── discord-bulk-delete.sh     # Bulk delete messages in a channel (requires bot token)
│   ├── cleanup-old-approvals.sh   # Time-based cleanup for old approved permissions
│   └── cleanup-test-messages.sh   # Clean up test-proj-* messages (auto-run by test suite)
└── tests/                 # Pure bash test suite (11 automated tests, no framework)
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
- **State:** `/tmp/claude-notify/` (ephemeral: throttle files, subagent counts, message IDs)
- **Config:** `~/.claude-notify/` (persistent: webhook URL, colors, enabled state)
- **Hooks registered:** Notification (idle/permission), SubagentStart/Stop, PostToolUse (approval detection)
- **Approval flow:** Permission prompt (orange) → User approves → PostToolUse fires → PATCH to green

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
# Run tests (auto-cleans test messages from Discord if credentials available)
bash tests/run-tests.sh

# Run a single test file
bash tests/test-throttle.sh

# Clean up test messages from Discord (test-proj-* embeds)
bash scripts/cleanup-test-messages.sh

# Bulk delete ALL messages from Discord channel (requires bot token)
DISCORD_BOT_TOKEN=<token> bash scripts/discord-bulk-delete.sh <channel_id>

# Clean up old approved permissions (time-based, default 1 hour TTL)
bash scripts/cleanup-old-approvals.sh
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
