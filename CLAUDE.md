# Claude Development Notes — claude-code-notify

## Project Overview

**claude-code-notify** is a lightweight Discord notification system for Claude Code sessions. It maintains a single status message per project, PATCHed in-place through the full session lifecycle (online → idle → permission → approved → offline).

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
├── claude-notify.sh       # Main hook script (sources lib, handles events)
├── lib/
│   └── notify-helpers.sh  # Shared function library (sourced by main + tests)
├── install.sh             # Interactive setup (config dir, webhook, hooks registration)
├── README.md              # User documentation
├── colors.conf.example    # Example per-project color config
├── .env.example           # Example webhook URL config
├── .claude/commands/      # Claude Code skills (check-pr, agent-review)
├── scripts/               # Utility scripts
│   ├── discord-bulk-delete.sh     # Bulk delete messages in a channel (requires bot token)
│   └── cleanup-test-messages.sh   # Clean up test-proj-* messages (auto-run by test suite)
└── tests/                 # Pure bash test suite (no framework)
    ├── run-tests.sh       # Test runner entry point
    ├── setup.sh           # Shared test environment setup
    ├── test-throttle.sh   # Throttle logic tests
    ├── test-colors.sh     # Color lookup tests
    ├── test-payload.sh    # Status payload structure tests (all 6 states)
    ├── test-session-lifecycle.sh   # Status file lifecycle tests
    ├── test-state-transitions.sh   # State machine transition tests
    ├── test-cleanup.sh    # Status file isolation tests
    └── test-subagent-count.sh  # Subagent tracking tests
```

## Architecture

- **Hook pattern:** stdin JSON → jq parse → curl Discord webhook (POST or PATCH)
- **Single message per project:** One Discord message PATCHed through the lifecycle
- **State machine:** `online` → `idle`/`idle_busy` → `permission` → `approved` → `offline`
- **State files:** `status-msg-PROJECT` (Discord message ID), `status-state-PROJECT` (current state)
- **Config hierarchy:** env var > `~/.claude-notify/.env` > hardcoded defaults
- **State:** `/tmp/claude-notify/` (ephemeral: status files, throttle files, subagent counts)
- **Config:** `~/.claude-notify/` (persistent: webhook URL, colors, enabled state)
- **Hooks registered:** SessionStart/End, Notification (idle/permission), PostToolUse, SubagentStart/Stop
- **Self-healing:** PATCH 404 → falls back to POST (handles externally deleted messages)

## Key Conventions

- `set -euo pipefail` in all scripts
- All JSON handling via `jq` (never raw shell substitution)
- All variables properly quoted
- Input sanitization: PROJECT_NAME stripped to `[A-Za-z0-9._-]`
- Color values validated as numeric before use
- Config dir `chmod 700`, .env file `chmod 600`
- Subagent count updates use mkdir-based locking (portable, no flock)
- Stdin read uses `timeout 5 cat` to prevent hanging

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
