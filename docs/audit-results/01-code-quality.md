# Code Quality Audit: claude-code-notify

**Agent**: Code Quality Auditor -- Meticulous senior engineer focused on bugs, edge cases, and robustness
**Overall Rating**: 3.9 / 5
**Date**: 2026-02-18

---

## Area Ratings

| Area | Rating | Notes |
|------|--------|-------|
| Bugs & Edge Cases | 3.5/5 | `.env` quoting, `cat` timeout discrepancy, color regex matching |
| Bash Best Practices | 4.0/5 | Excellent quoting, proper `set -euo pipefail`, `safe_write_file` pattern |
| Security | 4.0/5 | Good permission handling, sanitization; `/tmp` world-readable is minor |
| Robustness | 3.5/5 | Missing POST retry, heartbeat latency, but self-healing PATCH is solid |
| Test Coverage | 4.0/5 | Strong unit tests, zero integration/HTTP/concurrency tests |
| Code Organization | 4.5/5 | Clean separation, good naming, well-documented |

---

## Findings

### 1. `.env` values with quotes include the quotes in the value (Medium)

**File:** `lib/notify-helpers.sh:31`

```bash
val=$(grep -m1 "^${var_name}=" "$NOTIFY_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
```

If a user writes `CLAUDE_NOTIFY_WEBHOOK="https://..."` (extremely common convention), the quotes become part of the value. The webhook URL validation regex would fail, and curl would receive a URL with literal quote characters.

**Recommendation:** Strip surrounding quotes: `val="${val%\"}"; val="${val#\"}"` (and same for single quotes).

### 2. `cat` with no timeout contradicts documented design (Medium)

**File:** `claude-notify.sh:80`

```bash
INPUT=$(cat 2>/dev/null) || true
```

CLAUDE.md states "Stdin read uses `read -t 5` timeout to prevent hanging" but the actual code uses `cat` with no timeout. If a hook caller keeps stdin open, `cat` blocks indefinitely.

**Recommendation:** Replace with `timeout 5 cat` or a `read -t 5` loop approach.

### 3. `post_status_message` has no retry/rate-limit handling (Medium)

**File:** `claude-notify.sh:150-169`

The `patch_status_message` function has retry logic with exponential backoff. `post_status_message` has none. If a POST gets rate-limited (HTTP 429), the message is silently lost and no status file is written, leaving the project in a broken state.

**Recommendation:** Add similar retry logic to `post_status_message`.

### 4. `get_project_color` grep treats `.` in project names as regex wildcard (Medium)

**File:** `lib/notify-helpers.sh:270`

Project names are sanitized to `[A-Za-z0-9._-]`, so `.` is allowed. The grep pattern `^${project}=` treats `.` as "any character," potentially matching wrong entries.

**Recommendation:** Escape regex metacharacters in the project name before grepping.

### 5. `load_env_var` uses `eval` without validating `var_name` characters (Medium)

**File:** `lib/notify-helpers.sh:27-35`

While callers pass hardcoded strings (safe today), the function accepts arbitrary `var_name` arguments through `eval`. A future misuse could introduce code injection.

**Recommendation:** Add `[[ "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1` guard.

### 6. `/tmp/claude-notify/` created with default umask (Low)

**File:** `claude-notify.sh:32`

The directory is world-readable on shared systems. Other users can read state files to learn project names, Discord message IDs, and session timing.

**Recommendation:** Add `chmod 700 "$THROTTLE_DIR"` after mkdir.

### 7. Zero integration tests (Low)

All tests source the library and test individual functions. No test pipes JSON into the main `claude-notify.sh` script to verify end-to-end behavior.

### 8. No curl/HTTP tests (Low)

POST, PATCH, DELETE, and self-healing (404 fallback) are completely untested. The retry logic with backoff has zero test coverage.

### 9. `format_duration` does not validate input (Low)

**File:** `lib/notify-helpers.sh:95-104`

If `seconds` is empty or non-numeric, the `-lt` comparison will error. Currently protected by callers always providing arithmetic results, but the function itself is not defensive.

### 10. Repeated jq spawning in `build_status_payload` (Info)

**File:** `lib/notify-helpers.sh:288-469`

The pattern of piping through `jq -c` repeatedly to build arrays spawns 5-10 jq processes per call. Acceptable for notification frequency but inelegant.

---

## Conclusion

claude-code-notify demonstrates above-average discipline for shell scripting: proper quoting, `set -euo pipefail`, JSON via `jq` with `--arg`, and defensive defaults. The test suite is unusually thorough for a bash project. The most impactful fixes are: stripping quotes from `.env` values (user-facing bug), adding stdin timeout (design doc mismatch), and adding POST retry logic for parity.
