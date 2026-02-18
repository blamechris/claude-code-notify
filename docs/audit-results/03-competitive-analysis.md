# Competitive Analysis: claude-code-notify

**Agent**: Market Analyst -- Engineer tracking the AI coding tool ecosystem and notification/monitoring space
**Overall Rating**: N/A (positioning analysis)
**Date**: 2026-02-18

---

## Direct Competitors (Claude Code Notification Tools)

### claude-notifications-go (by 777genius)
- **URL:** https://github.com/777genius/claude-notifications-go
- **Stars:** ~103 | **Language:** Go binary
- **Channels:** Desktop, Discord, Slack, Telegram, Lark/Feishu, custom webhooks
- **Key differentiator:** Plugin marketplace distribution, custom sounds, click-to-focus, auto-updates, circuit breaker for webhooks
- **What they have that we don't:** Multi-channel support, marketplace listing, custom sounds, session naming ("[bold-cat]")

### claude-code-discord (by jubalm)
- **URL:** https://github.com/jubalm/claude-code-discord
- **Language:** Python + Shell | **Channels:** Discord
- **Key differentiator:** Discord thread support (organizes notifications by session)
- **What they have that we don't:** Thread-based organization, per-project webhook support out of the box

### CCNotify (by dazuiba)
- **URL:** https://github.com/dazuiba/CCNotify (~152 stars)
- **Language:** Shell | **Channels:** macOS desktop only
- **Key differentiator:** Click-to-jump (opens VS Code), session database logging, task duration display

### claude-code-notification (by wyattjoh)
- **URL:** https://github.com/wyattjoh/claude-code-notification
- **Language:** Rust binary | **Channels:** Desktop + custom sounds
- **Key differentiator:** High-performance Rust binary, advanced sound format support

### Toasty (by Scott Hanselman)
- **URL:** https://github.com/shanselman/toasty
- **Channels:** Windows toast + phone push (ntfy.sh)
- **Key differentiator:** Multi-agent support (Claude, Copilot, Gemini, Codex, Cursor), zero dependencies (229KB binary)

---

## Adjacent Solutions (Remote Control & Monitoring)

| Tool | What It Does | Key Feature |
|------|-------------|-------------|
| **ccremote** | Discord-based remote approvals | Approve permission prompts from Discord |
| **Claude-Code-Remote** | Email/Discord/Telegram control | Reply-to-command (send new commands via reply) |
| **Discode** | Full terminal relay to Discord/Slack | Bidirectional control from Discord |
| **claude-code-ui** | Kanban web dashboard | AI-generated session summaries |
| **ccboard** | TUI + Web dashboard | Cost analytics with 30-day forecasting |

---

## Feature Comparison Matrix

| Feature | claude-code-notify | claude-notifications-go | CCNotify | ccremote | Toasty |
|---|---|---|---|---|---|
| **Discord** | Yes (primary) | Yes | No | Yes | No |
| **Slack** | No | Yes | No | No | No |
| **Desktop** | No | Yes | Yes (macOS) | No | Yes (Windows) |
| **Mobile push** | No | No | No | No | Yes (ntfy.sh) |
| **Single msg/project** | **Yes (unique)** | No | N/A | No | N/A |
| **PATCH-in-place** | **Yes** | No | N/A | No | N/A |
| **State machine** | **6-state lifecycle** | 6 types | 2 types | N/A | N/A |
| **Subagent tracking** | **Yes** | No | No | No | No |
| **Activity metrics** | **Yes** | No | Yes (duration) | No | No |
| **Heartbeat/stale** | **Yes** | No | No | No | No |
| **Per-project colors** | **Yes** | No | No | No | No |
| **Remote approvals** | No | No | No | **Yes** | No |
| **Custom sounds** | No | Yes | No | No | No |
| **Multi-agent** | No | No | No | No | **Yes (5 agents)** |
| **Plugin marketplace** | No | **Yes** | No | No | No |
| **Dependencies** | jq + curl | None (Go) | terminal-notifier | Node.js | None (229KB) |

---

## What We Have That They Don't

1. **Single-message-per-project PATCH architecture** -- No other tool maintains a live dashboard message. Competitors POST new messages creating spam.
2. **Strategic DELETE+POST for important states** -- Idle and permission notifications appear at channel bottom and trigger pings. Background transitions are quiet PATCHes.
3. **Full 6-state lifecycle machine** -- Most competitors differentiate 2-3 states.
4. **Subagent tracking** with per-project counts and peak metrics.
5. **Background bash tracking** -- Monotonic counter unique to our tool.
6. **Heartbeat with stale detection** -- Background process keeps elapsed time accurate, flags abandoned sessions.
7. **Per-project embed colors** for visual distinction.
8. **Zero runtime dependencies** beyond bash, jq, curl.
9. **Comprehensive test suite** -- 13 test files, 200+ assertions. Most competitors have minimal tests.
10. **Self-healing** (PATCH 404 -> POST fallback).

---

## What They Have That We Don't

1. **Multi-channel support** -- claude-notifications-go supports 6 channels vs. our 1
2. **Desktop/native notifications** -- 4+ competitors have this
3. **Click-to-focus** -- CCNotify and claude-notifications-go activate the right window
4. **Custom sounds/TTS** -- Multiple competitors offer audio alerts
5. **Remote control** -- ccremote allows Discord-based permission approval
6. **Plugin marketplace distribution** -- Primary discovery channel we're missing
7. **Multi-agent support** -- Toasty works with 5 different AI coding tools
8. **Auto-update mechanism** -- Both claude-notifications-go and Toasty auto-update

---

## Market Positioning

```
Tier 1: Simple event notifications (gist hooks, basic scripts)
Tier 2: Smart notifications (desktop + webhook, sounds)
Tier 3: Lifecycle-aware dashboards  <-- claude-code-notify is HERE
Tier 4: Remote control & monitoring platforms
```

Our unique position: **Discord-native live operational dashboard** -- one message per project, always up-to-date, no spam. This is fundamentally different from every competitor.

---

## Strategic Recommendations

### Short-term (0-3 months)
1. **Get listed on Claude Code plugin marketplace** -- Primary discovery channel
2. **Add ntfy.sh support** -- One curl call gives mobile push, minimal effort
3. **Market the single-message architecture** -- "Live dashboard, not message spam"

### Medium-term (3-6 months)
4. **Add Slack webhook support** -- Reuse state machine with Block Kit formatting
5. **Add desktop notifications** -- `notify-send` / `osascript` as secondary channel
6. **Discord reaction-based remote approvals** -- Leverages our single-message architecture perfectly

### Long-term (6-12 months)
7. **Abstract notification channels** -- Pluggable backend for community contributions
8. **Multi-agent support** -- As other tools add hook systems, expand
9. **Web dashboard companion** -- Lightweight status page aggregating project states

### What NOT To Do
- Do not become a remote control tool (different market)
- Do not add a compiled binary dependency (simplicity is an advantage)
- Do not add TTS/voice features (stay in "glanceable status" lane)

---

## Sources

- [claude-notifications-go](https://github.com/777genius/claude-notifications-go)
- [claude-code-discord](https://github.com/jubalm/claude-code-discord)
- [CCNotify (dazuiba)](https://github.com/dazuiba/CCNotify)
- [claude-code-notification (wyattjoh)](https://github.com/wyattjoh/claude-code-notification)
- [Toasty (shanselman)](https://github.com/shanselman/toasty)
- [ccremote](https://github.com/generativereality/ccremote)
- [Claude-Code-Remote](https://github.com/JessyTsui/Claude-Code-Remote)
- [Discode](https://github.com/siisee11/discode)
- [claude-code-ui](https://github.com/KyleAMathews/claude-code-ui)
- [ccboard](https://github.com/FlorianBruniaux/ccboard)
- [Aider notifications](https://aider.chat/docs/usage/notifications.html)
- [ntfy.sh](https://docs.ntfy.sh/)
- [Apprise](https://github.com/caronc/apprise)
