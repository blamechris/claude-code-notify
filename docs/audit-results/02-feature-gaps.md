# Feature Gap Analysis: claude-code-notify

**Agent**: Feature Architect -- Product-minded engineer focused on user needs and enhancement opportunities
**Overall Rating**: 3.5 / 5 (current feature set vs. potential)
**Date**: 2026-02-18

---

## What the Project Does Exceptionally Well

- Single-message-per-project PATCH model avoids notification spam
- DELETE+POST repost for attention-requiring states triggers Discord pings
- Self-healing on PATCH 404 handles externally deleted messages gracefully
- Thorough test suite (13 files, 200+ assertions) for a bash project
- `set -euo pipefail` + proper quoting discipline throughout

---

## High-Priority Feature Gaps

### 1. Per-Project Webhook URLs
**Impact:** High | **Complexity:** Small

All projects share one webhook URL. Teams with 5+ concurrent sessions need routing to different channels (e.g., `#frontend-bots`, `#backend-bots`).

**Implementation:** Add per-project webhooks to `colors.conf` or a new `webhooks.conf`. Lookup mirrors `get_project_color()`.

### 2. Mention/Ping Configuration
**Impact:** High | **Complexity:** Small

No way to customize who gets pinged. Users want `@me` for permissions but silent idle notifications.

**Implementation:** Add `CLAUDE_NOTIFY_MENTION_IDLE` and `CLAUDE_NOTIFY_MENTION_PERMISSION` env vars. Inject into `content` field of POST payload.

### 3. Hex Color Support in colors.conf
**Impact:** High | **Complexity:** Small

Requiring decimal color conversion is friction every user hits. The README directs users to spycolor.com.

**Implementation:** Accept `#1ABC9C` or `1ABC9C` format, convert with `printf '%d' "0x${color#\#}"`. ~5 lines in `get_project_color()`.

### 4. Session History Log
**Impact:** High | **Complexity:** Small

All state is ephemeral in `/tmp/`. Users cannot answer "How many sessions did I run this week?" or "Average session duration?"

**Implementation:** On SessionEnd, append JSON line to `~/.claude-notify/history.jsonl`. ~10 lines of code. Transforms the tool from a real-time indicator into an analytics platform.

### 5. `--test` Mode for Install Verification
**Impact:** Medium | **Complexity:** Small

No immediate confirmation that the webhook works after install. Users must start a Claude Code session and wait.

**Implementation:** `claude-notify.sh --test` sends a test embed and immediately deletes it.

---

## Medium-Priority Feature Gaps

### 6. Notification State Filtering
**Impact:** Medium | **Complexity:** Small

Notifications are all-or-nothing. Users in `--dangerously-skip-permissions` mode never need permission notifications.

**Implementation:** `CLAUDE_NOTIFY_STATES=permission,idle,offline` whitelist env var.

### 7. Idle Duration in Embed
**Impact:** Medium | **Complexity:** Small

The idle embed shows "Waiting for input" but not how long. The `last-state-change` file already tracks this.

**Implementation:** Calculate `now - last_state_change` and display as "Waiting for input (15m 30s)".

### 8. Session Summary on Offline
**Impact:** Medium | **Complexity:** Medium

Offline embed shows basic metrics but lacks duration breakdown, state transition count, and permission prompt count.

**Implementation:** Track additional counters (permission-count, idle-count, total-idle-seconds).

### 9. Time-Aware Urgency Escalation
**Impact:** Medium | **Complexity:** Medium

All permission prompts get the same treatment regardless of wait time. A 30-second wait is not urgent; a 10-minute wait is critical.

**Implementation:** Heartbeat checks permission state age, escalates color to red and adds "Urgent" prefix after configurable threshold.

### 10. Operational Status Check
**Impact:** Medium | **Complexity:** Small

Silent failures when webhook stops working. No way to diagnose issues.

**Implementation:** `claude-notify.sh --status` checks webhook reachability, last successful API call, active sessions from state files. Optional `CLAUDE_NOTIFY_LOG_FILE` for persistent logging.

---

## Platform Expansion (Significant Market Impact)

### 11. Slack Webhook Support
**Impact:** High | **Complexity:** Medium

Discord-only excludes the large Slack-using developer population. Slack uses Block Kit (different payload format).

**Implementation:** Abstract behind a provider interface. Create `lib/providers/discord.sh` and `lib/providers/slack.sh`. Auto-detect from URL format.

### 12. Generic Webhook Provider
**Impact:** Medium | **Complexity:** Small

Simple JSON POST for custom dashboards, monitoring systems.

**Implementation:** POST-only provider with flat JSON payload: `{"project": "...", "state": "...", "timestamp": "...", "metrics": {...}}`.

### 13. Desktop Notifications
**Impact:** Low | **Complexity:** Small

For developers in full-screen terminals who don't watch Discord.

**Implementation:** `CLAUDE_NOTIFY_DESKTOP=true`, use `notify-send` (Linux) / `osascript` (macOS). Fire alongside Discord for actionable states only.

---

## Power User Features

### 14. Multi-Session Digest Message
**Impact:** Medium | **Complexity:** Large

With 10 active sessions, finding the one needing attention requires scanning. A single "dashboard message" summarizing all sessions would help.

### 15. Auto-Cleanup of Stale Messages
**Impact:** Medium | **Complexity:** Medium

Orphaned "Session Online (stale?)" messages after machine reboot or SSH disconnect persist indefinitely.

### 16. Session Statistics CLI
**Impact:** Medium | **Complexity:** Medium

`claude-notify.sh --stats` reading `history.jsonl` for usage reports.

---

## Prioritized Roadmap

| Phase | Features | Impact |
|-------|----------|--------|
| **Phase 1: Quick Wins** | Hex colors, --test mode, per-project webhooks, mention config, idle duration | High |
| **Phase 2: Core** | Session history log, state filtering, webhook validation, session summary, urgency escalation | High-Medium |
| **Phase 3: Platform** | Slack support, provider architecture, generic webhook, desktop notifications | High |
| **Phase 4: Power** | Statistics CLI, digest message, stale auto-cleanup, custom templates | Medium |

---

## Key Insight

The single highest-impact change is **session history logging**. It is ~10 lines of code, zero new dependencies, and transforms the tool from a real-time indicator into an analytics platform that grows more valuable over time.
