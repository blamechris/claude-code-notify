# Architecture Audit: claude-code-notify

**Agent**: Systems Architect -- Senior infrastructure engineer evaluating system design, state management, and operational patterns
**Overall Rating**: 3.6 / 5
**Date**: 2026-02-18

---

## Area Ratings

| Area | Rating | Notes |
|------|--------|-------|
| State Machine Design | 4/5 | Correct, complete, no impossible states |
| Concurrency Model | 3/5 | mkdir lock for subagents is good; state transitions unlocked |
| File-Based State | 3/5 | /tmp is appropriate; 13+ files per project is manageable |
| Error Handling | 4/5 | "Never crash" philosophy is exactly right for hooks |
| API Integration | 4/5 | Multi-layered throttling, self-healing 404 fallback |
| Configuration | 4/5 | Clean three-tier hierarchy following 12-Factor conventions |
| Separation of Concerns | 4/5 | Logical split; build_extra_fields coupling is fragile |
| Test Architecture | 3/5 | Strong unit tests; no integration tests |
| CI/CD | 2/5 | Minimal -- no shellcheck, no macOS testing |
| Scalability | 3/5 | Works for intended use; jq spawning is bottleneck at scale |

---

## State Machine Diagram

```
                         SessionStart
                              |
                              v
                     +--------+--------+
                     |     online      |<--------------------------+
                     +--------+--------+                           |
                              |                                    |
              +---------------+---------------+                    |
              |                               |                    |
        idle_prompt                     PostToolUse                |
        (Notification)                  (state=approved)           |
              |                               |                    |
              v                               |                    |
     +--------+--------+                      |                    |
     |      idle        |-----PostToolUse-----+                    |
     +--------+---------+  (0 subagents)      |                    |
              |                               |                    |
        SubagentStart                         |                    |
        (while idle)                          |                    |
              |                               |                    |
              v                               |                    |
     +--------+---------+                     |                    |
     |   idle_busy      |-----PostToolUse-----+                    |
     +---------+---------+ (0 subagents)                           |
              |                                                    |
         SubagentStop                                              |
         (count -> 0)                                              |
              |                                                    |
              v                                                    |
     +--------+---------+                                          |
     |      idle        |                                          |
     +------------------+                                          |
                                                                   |
        permission_prompt                                          |
        (Notification)                                             |
              |                                                    |
              v                                                    |
     +--------+---------+                                          |
     |   permission     |-----PostToolUse----> approved -----------+
     +------------------+
                         SessionEnd
                    (from any active state)
                              |
                              v
                     +--------+--------+
                     |    offline      |
                     +-----------------+
```

All transitions verified against source code. No impossible or unreachable states found.

---

## Top 10 Findings

### 1. No integration tests (Medium)
State machine routing in main script is untested end-to-end. Tests simulate logic manually rather than invoking actual code paths.

### 2. No shellcheck in CI (Medium)
Pure bash project with no static analysis. `eval` usage and other patterns would benefit from automated linting.
**File:** `.github/workflows/ci.yml:13-22`

### 3. Heartbeat has no locking (Medium)
The heartbeat can PATCH Discord with stale state if the main script transitions between the heartbeat's state read and PATCH.
**File:** `lib/heartbeat.sh:56-82`

### 4. No 429 rate-limit handling in main PATCH/POST paths (Low-Medium)
Only bulk-delete script handles `Retry-After`. Main script retries blindly.
**File:** `claude-notify.sh:207-229`

### 5. TOCTOU race in PostToolUse handler (Low-Medium)
State is read at line 379, then acted upon at lines 381-399. Another event could change state between these lines.
**File:** `claude-notify.sh:379-401`

### 6. File proliferation: 13+ files per project (Low-Medium)
If SessionEnd never fires, files persist until reboot or next SessionStart.
**File:** `notify-helpers.sh:241-258`

### 7. Non-atomic file writes (Low)
`safe_write_file` uses `printf > file` rather than write-to-temp + atomic `mv`.
**File:** `notify-helpers.sh:114`

### 8. `/tmp/claude-notify/` directory without restrictive permissions (Low)
On shared systems, other users could read Discord message IDs.
**File:** `claude-notify.sh:39`

### 9. `build_extra_fields()` implicit global contract (Low)
Callers must define this function before calling `build_status_payload`. Missing definition causes runtime failure.
**File:** `notify-helpers.sh:287,294`

### 10. No macOS CI testing (Low)
Project targets macOS but CI runs only on ubuntu-latest. `stat` command fallback at line 240 only validated on Linux.
**File:** `.github/workflows/ci.yml:10`

---

## Summary

The architecture is well-designed for its intended use case: a single developer running one or a few Claude Code sessions. The state machine is correct and complete. The "never crash" error philosophy is exactly right for a hook script. The self-healing patterns show mature operational thinking.

Primary improvement areas: test depth (integration tests exercising actual main script), CI rigor (shellcheck, macOS runners), and minor hardening (429 handling, atomic writes, restricted `/tmp` permissions).
