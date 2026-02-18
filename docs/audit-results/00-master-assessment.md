# Master Assessment: claude-code-notify Multi-Agent Audit

**Date**: 2026-02-18
**Agents**: 6 specialized auditors (parallel execution)
**Scope**: Full codebase review -- code quality, features, competition, architecture, security, testing

---

## a. Auditor Panel

| # | Agent | Perspective | Rating | Key Contribution |
|---|-------|-------------|--------|-----------------|
| 1 | Code Quality Auditor | Bugs, edge cases, bash best practices | 3.9/5 | Found .env quoting bug, stdin timeout mismatch, POST retry gap |
| 2 | Feature Architect | Missing features, UX gaps, roadmap | 3.5/5 | Identified 25+ feature opportunities, prioritized roadmap |
| 3 | Market Analyst | Competition, positioning, strategy | N/A | Mapped 15+ competitors, identified unique differentiators |
| 4 | Systems Architect | State machine, concurrency, scalability | 3.6/5 | Verified state machine correctness, found CI gaps |
| 5 | Security Guardian | Vulnerabilities, attack surface, threats | 3.4/5 | Found /tmp symlink risk, eval injection vector, secret exposure |
| 6 | Test Engineer | Coverage, quality, infrastructure | 3.5/5 | Mapped all coverage gaps, recommended 10 priority tests |

**Aggregate Rating: 3.6 / 5** (weighted average: core agents 1.0x)

---

## b. Consensus Findings (4+ agents agree)

### 1. `/tmp/claude-notify/` needs restrictive permissions
**Agents:** Security (High), Architecture (Low), Code Quality (Low), Testing (noted)

The state directory is created with default umask, making it world-readable. On shared systems, other users can read project names, Discord message IDs, and session timing. The path is predictable, enabling symlink attacks.

**Evidence:**
- `claude-notify.sh:32` -- hardcoded `/tmp/claude-notify`
- `claude-notify.sh:39` -- `mkdir -p` without `chmod`

**Recommended action:** Add `chmod 700 "$THROTTLE_DIR"` after creation. Consider using `$XDG_RUNTIME_DIR` or user-namespaced path.

### 2. `eval` in `load_env_var` should be replaced
**Agents:** Security (High), Code Quality (Medium), Architecture (noted), Testing (noted)

The `eval`-based config loader at `lib/notify-helpers.sh:27-35` is safe with current hardcoded callers but is a latent code injection vector if future changes pass user-controlled input.

**Recommended action:** Replace with Bash nameref (`local -n`) or `declare -g`.

### 3. No integration tests for main script
**Agents:** Testing (Critical), Architecture (Medium), Code Quality (Low), Feature (noted)

All 289 assertions test library functions in isolation. No test pipes JSON into `claude-notify.sh` to verify end-to-end behavior. State transition tests replicate production logic manually.

**Recommended action:** Create curl mock, add integration test piping events through the real main script.

### 4. No shellcheck or macOS testing in CI
**Agents:** Architecture (Medium), Testing (Medium), Security (noted), Code Quality (noted)

Pure bash project with no static analysis. CI runs only on ubuntu-latest despite targeting macOS as a primary platform.

**Recommended action:** Add shellcheck step and macOS to CI matrix.

### 5. `post_status_message` lacks retry logic
**Agents:** Code Quality (Medium), Architecture (noted), Security (noted via failure modes)

`patch_status_message` has 3-attempt retry with exponential backoff. `post_status_message` has none. A rate-limited POST silently loses the message, leaving the project in broken state.

**Recommended action:** Add retry logic matching `patch_status_message`.

### 6. Non-atomic file writes risk corruption
**Agents:** Security (Medium), Architecture (Low), Code Quality (noted)

`safe_write_file` uses `printf > file` which is not atomic. Concurrent readers (heartbeat, subagent events) can see partial content.

**Recommended action:** Write to temp file, then `mv` (atomic on same filesystem).

---

## c. Contested Points

### stdin timeout: Design vs. Implementation
- **Code Quality** says `cat` with no timeout contradicts CLAUDE.md's documented `read -t 5` design.
- **Security** classifies it as Low severity (stdin comes from Claude Code, a trusted source).
- **Assessment:** Code Quality is right -- the mismatch should be fixed. Even though the source is trusted, the timeout prevents hanging on edge cases (broken pipe, interrupted write). Use `timeout 5 cat` for simplicity.

### .env quoted values: Bug or user error?
- **Code Quality** classifies as Medium bug -- quoted values are a "very common convention."
- **No other agent** explicitly flagged this.
- **Assessment:** This is a real user-facing bug. `.env` files with quoted values (`VAR="value"`) are standard in many ecosystems. Stripping quotes is a small fix with outsized impact on user experience.

### Heartbeat locking: Needed or overkill?
- **Architecture** notes heartbeat has no locking (TOCTOU risk).
- **Security** does not flag this separately.
- **Assessment:** Architecture is right that it is a theoretical risk, but the practical impact is minimal (heartbeat runs every 300s, worst case a stale state is PATCHed and corrected by the next real event). Not worth adding locking complexity for the heartbeat.

---

## d. Factual Corrections

| Claim (from CLAUDE.md) | Reality | Found By |
|-------------------------|---------|----------|
| "Stdin read uses `read -t 5` timeout" | Actual code uses `cat 2>/dev/null` with no timeout | Code Quality |
| (Implicit) State files cover all cleanup | `clear_status_files` has 13 `rm -f` calls and must be manually kept in sync with new file types | Architecture |

---

## e. Risk Heatmap

```
                    IMPACT
           Low    Medium    High    Critical
         +--------+--------+--------+--------+
  High   |        |        | /tmp   | eval   |
         |        |        | perms  | inject |
         +--------+--------+--------+--------+
Likely   |        | no POST| PATCH  |        |
  Med    |        | retry  | 404    |        |
         |        |        | untestd|        |
         +--------+--------+--------+--------+
  Low    | jq     | no     | PID    |        |
         | perf   | macOS  | recycle|        |
         |        | CI     |        |        |
         +--------+--------+--------+--------+
  Very   | format | color  | secret |        |
  Low    | dur.   | regex  | in ps  |        |
         | input  |        |        |        |
         +--------+--------+--------+--------+
```

---

## f. Recommended Action Plan

### Phase 1: Hardening (Immediate -- fixes existing issues)

| # | Action | Source | Impact | Effort |
|---|--------|--------|--------|--------|
| 1 | `chmod 700 "$THROTTLE_DIR"` after mkdir | Security, Architecture | High | Trivial |
| 2 | Replace `eval` in `load_env_var` with nameref | Security, Code Quality | High | Small |
| 3 | Strip quotes from .env values | Code Quality | Medium | Trivial |
| 4 | Add `timeout 5 cat` for stdin reading | Code Quality, Security | Medium | Trivial |
| 5 | Add retry logic to `post_status_message` | Code Quality, Architecture | Medium | Small |
| 6 | Make `safe_write_file` atomic (write-to-temp + mv) | Security, Architecture | Medium | Small |
| 7 | Escape regex in `get_project_color` grep | Code Quality | Low | Trivial |

### Phase 2: Testing & CI (Short-term -- improves confidence)

| # | Action | Source | Impact | Effort |
|---|--------|--------|--------|--------|
| 8 | Add integration tests with curl mock | Testing, Architecture | High | Medium |
| 9 | Add shellcheck to CI | Architecture, Testing | Medium | Trivial |
| 10 | Add macOS to CI matrix | Architecture, Testing | Medium | Trivial |
| 11 | Test PATCH 404 self-heal flow | Testing | Medium | Small |
| 12 | Test disabled state (.disabled + env var) | Testing | Medium | Small |
| 13 | Test heartbeat process lifecycle | Testing | Medium | Small |

### Phase 3: Quick-Win Features (Short-term -- high user impact)

| # | Action | Source | Impact | Effort |
|---|--------|--------|--------|--------|
| 14 | Hex color support in colors.conf | Features | High | Small |
| 15 | `claude-notify.sh --test` mode | Features | Medium | Small |
| 16 | Per-project webhook URLs | Features | High | Small |
| 17 | Mention/ping configuration | Features | High | Small |
| 18 | Idle duration in embed ("Waiting for 5m 30s") | Features | Medium | Trivial |
| 19 | Session history log (JSONL on SessionEnd) | Features | High | Small |

### Phase 4: Platform & Growth (Medium-term -- market expansion)

| # | Action | Source | Impact | Effort |
|---|--------|--------|--------|--------|
| 20 | Plugin marketplace listing | Competition | High | Medium |
| 21 | ntfy.sh support for mobile push | Competition, Features | Medium | Small |
| 22 | Slack webhook support | Features, Competition | High | Medium |
| 23 | Desktop notifications (notify-send/osascript) | Features, Competition | Medium | Small |
| 24 | Provider plugin architecture | Features | Medium | Medium |
| 25 | Session statistics CLI | Features | Medium | Medium |

---

## g. Final Verdict

**Aggregate Rating: 3.6 / 5 -- Good. Ship with fixes.**

claude-code-notify is a well-engineered bash project that solves a real problem with an elegant design. The single-message-per-project PATCH architecture is genuinely unique in a crowded competitive landscape of 15+ notification tools. The state machine is correct. The error handling philosophy ("never crash the hook") is exactly right. The test suite is unusually thorough for a bash project.

**What makes it stand out:** No other tool maintains a live dashboard message per project. The DELETE+POST repost for attention-requiring states is a clever UX pattern. Self-healing on 404, subagent tracking, heartbeat with stale detection, and per-project colors are differentiators no competitor replicates.

**What holds it back:** Discord-only channel support limits the addressable market. Several medium-severity security and robustness issues (`/tmp` permissions, `eval` usage, non-atomic writes) should be addressed before recommending for shared/multi-user environments. The absence of integration tests means the state machine routing -- the project's core value -- is validated only by manual logic replication, not by exercising real code paths.

**Recommended priority:**
1. Fix the 7 hardening items in Phase 1 (all trivial/small effort)
2. Add integration tests and shellcheck (Phase 2)
3. Ship the quick-win features in Phase 3 (hex colors, --test mode, per-project webhooks, session history)
4. Pursue plugin marketplace listing and Slack support in Phase 4

The project is in a strong position. The core architecture is sound, the competition is fragmented (no single tool dominates), and the "live dashboard, not message spam" value proposition resonates. The 25+ identified feature opportunities provide a clear growth path without requiring architectural changes.

---

## h. Appendix: Individual Reports

| # | Report | Agent | File |
|---|--------|-------|------|
| 1 | Code Quality Audit | Code Quality Auditor | [01-code-quality.md](01-code-quality.md) |
| 2 | Feature Gap Analysis | Feature Architect | [02-feature-gaps.md](02-feature-gaps.md) |
| 3 | Competitive Analysis | Market Analyst | [03-competitive-analysis.md](03-competitive-analysis.md) |
| 4 | Architecture Audit | Systems Architect | [04-architecture.md](04-architecture.md) |
| 5 | Security Audit | Security Guardian | [05-security.md](05-security.md) |
| 6 | Testing Audit | Test Engineer | [06-testing.md](06-testing.md) |

---

## Appendix: Generalized Skill

A reusable `/project-audit` skill was designed during this audit. See:
- Skill definition: `.claude/commands/project-audit.md`
- Design document: `.claude/commands/project-audit-design.md`
