# Testing Audit: claude-code-notify

**Agent**: Test Engineer -- QA specialist who believes untested code is broken code
**Overall Rating**: 3.5 / 5
**Date**: 2026-02-18

---

## Area Ratings

| Area | Rating |
|------|--------|
| Coverage Analysis | 3.0/5 |
| Test Quality | 3.5/5 |
| Edge Cases | 3.0/5 |
| Integration Tests | 1.5/5 |
| Test Infrastructure | 3.0/5 |
| Test Isolation | 3.5/5 |
| CI Integration | 2.5/5 |
| Missing Test Categories | 2.0/5 |
| Test Maintainability | 3.5/5 |

---

## Current Test Suite Summary

**13 test files** | **289 assertions** | **All passing**

| Test File | Assertions | Covers |
|-----------|-----------|--------|
| test-throttle.sh | 10 | Throttle cooldown, independence, edge cases |
| test-colors.sh | 13 | Color lookup, validation, fallbacks |
| test-payload.sh | ~33 | All 6 states, JSON structure, truncation |
| test-session-lifecycle.sh | ~42 | Status file creation/cleanup |
| test-state-transitions.sh | ~30 | FSM transitions, subagent PATCH logic |
| test-cleanup.sh | ~32 | File isolation, load_env_var, safe_write |
| test-subagent-count.sh | 13 | Counter increment/decrement/bounds |
| test-activity-tracking.sh | ~55 | Metrics, duration formatting, payload fields |
| test-bg-bash.sh | 15 | Background bash tracking, payload display |
| test-heartbeat.sh | 14 | Stale detection, state change timestamps |
| test-empty-cwd.sh | 9 | Empty/missing CWD handling |
| test-project-name.sh | 6 | Git-based name resolution |
| test-webhook-extraction.sh | 17 | URL parsing, validation |

---

## Critical Coverage Gaps

### Completely Untested

| Component | Why It Matters |
|-----------|---------------|
| `build_extra_fields()` (always stubbed) | Real function reads 4+ env vars, handles JSON objects -- zero coverage |
| `post_status_message()` | No curl mock exists -- HTTP POST untested |
| `repost_status_message()` | DELETE + POST sequence untested |
| `patch_status_message()` | Retry logic, 404 self-heal untested |
| Subagent lock mechanism | mkdir-based locking never tested under contention |
| `install.sh` | Setup, uninstall, hook registration -- zero tests |
| Heartbeat loop process | Only helpers tested, not the actual background loop |
| `.disabled` file / `CLAUDE_NOTIFY_ENABLED=false` | Enable/disable mechanism untested |

### Partially Tested (Integration Gaps)

State transitions in `test-state-transitions.sh` replicate the production `case` logic manually rather than invoking `claude-notify.sh`. A refactor changing the main script could pass tests while introducing regressions.

---

## Top 10 Recommended New Tests

### 1. Integration test: Full event flow with curl mock (Critical)
Pipe JSON through real `claude-notify.sh`, verify POST/PATCH/DELETE sequence, state file management, and message ID propagation.

### 2. PATCH 404 self-heal test (High)
Mock curl to return 404 on PATCH, verify fallback to POST and new message ID saved.

### 3. `build_extra_fields()` unit tests (High)
Test with all `SHOW_*` env var combinations, various `TOOL_INPUT` shapes, truncation at 1000 chars.

### 4. Disabled state tests (High)
Verify `.disabled` file and `CLAUDE_NOTIFY_ENABLED=false` cause immediate exit for all events.

### 5. Heartbeat process lifecycle test (High)
Test interval=0 exits, interval<10 fallback, self-termination on offline state, PID file cleanup.

### 6. Concurrent subagent locking test (Medium)
Spawn 20 parallel processes incrementing counter, verify final count = 20.

### 7. `validate_color()` boundary tests (Medium)
Test 0, 16777215, 16777216, -1, empty, float. Test custom color env vars with invalid values.

### 8. Add shellcheck to CI (Medium)
Static analysis catches bugs that unit tests cannot (unquoted variables, POSIX issues).

### 9. macOS CI matrix (Medium)
Test on macos-latest -- `stat` flags, `date` options differ between GNU and BSD.

### 10. Installer test (Medium)
Test install/uninstall with mock home directory. Verify permissions, hook structure, idempotency.

---

## CI Improvements Needed

| Current | Recommended |
|---------|-------------|
| Ubuntu only | Add macOS to matrix |
| No static analysis | Add shellcheck step |
| No structured output | Add TAP/JUnit for GitHub annotations |
| No job timeout | Add `timeout-minutes: 10` |
| actions/checkout@v4 (tag) | Pin to full SHA |

---

## Flaky Test Risks

1. **test-throttle.sh test 3**: Uses `sleep 1.1` for 1-second cooldown. 0.1s margin is thin on loaded CI runners.
2. **test-heartbeat.sh test 3b**: Relies on wall-clock `date +%s` timing across `sleep 1`.
3. **test-project-name.sh**: Depends on running inside a git repository.

---

## Conclusion

The test suite is strong at the unit level -- well-organized, thorough edge case coverage, and good assertion helpers. The primary weakness is the complete absence of integration tests that exercise the main `claude-notify.sh` entry point end-to-end. The custom test runner is adequate for the project's size. Adding a curl mock and a handful of integration tests would dramatically improve confidence in the state machine routing and HTTP interaction layers.
