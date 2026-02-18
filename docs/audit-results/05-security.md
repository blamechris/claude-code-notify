# Security Audit: claude-code-notify

**Agent**: Security Guardian -- Paranoid security engineer and SRE who designs for 3am incidents
**Overall Rating**: 3.4 / 5
**Date**: 2026-02-18

---

## Area Ratings

| Area | Rating | Notes |
|------|--------|-------|
| Secret Management | 3/5 | Good file permissions, process-level exposure |
| Input Validation | 4/5 | Strong sanitization, eval is latent risk |
| File System Security | 2.5/5 | Predictable /tmp path is biggest weakness |
| Network Security | 4/5 | HTTPS enforced, good URL validation |
| Process Security | 3/5 | PID management has race conditions |
| Privilege Model | 4/5 | No escalation, runs as user |
| Supply Chain | 3/5 | PATH manipulation risk |
| Failure Modes | 4/5 | Graceful degradation in most scenarios |
| Information Disclosure | 3.5/5 | Project names leak; tool info can leak secrets |
| Denial of Service | 4/5 | Good throttling; missing stdin timeout |

---

## Top 10 Findings (Ordered by Severity)

### 1. Predictable `/tmp/claude-notify` without ownership verification (High)

**File:** `claude-notify.sh:32`

Hardcoded, predictable path. `mkdir -p` does not verify ownership. Symlink attack: attacker creates `/tmp/claude-notify` as symlink before victim runs script.

**Mitigation:** Use `$XDG_RUNTIME_DIR` or `/tmp/claude-notify-$(id -u)`. Verify ownership after creation. Set `chmod 700`.

### 2. `eval`-based config loader is a latent injection vector (High)

**File:** `lib/notify-helpers.sh:27-35`

`eval` twice in `load_env_var()`. Safe today (hardcoded callers) but fragile -- a future maintainer calling with user-controlled input creates code execution.

**Mitigation:** Replace with Bash nameref (`local -n ref="$var_name"`) or `declare -g`.

### 3. Webhook URL visible in process listing (Medium)

**File:** `claude-notify.sh:155-158`

Webhook URL (containing secret token) visible via `ps aux | grep curl`. Allows any system user to impersonate the bot.

**Mitigation:** Use curl `--config` with process substitution to avoid URL in command line.

### 4. Non-atomic file writes enable concurrent corruption (Medium)

**File:** `lib/notify-helpers.sh:111-118`

`printf > file` is not atomic. Concurrent readers see partial/empty content. Subagent count and state files are read/written by multiple processes.

**Mitigation:** Write to temp file, then `mv` (atomic on same filesystem).

### 5. Heartbeat PID file race condition (Medium)

**File:** `claude-notify.sh:307-312`

PID recycling between reading PID file and sending `kill` could terminate an unrelated process.

**Mitigation:** Verify process identity via `/proc/PID/cmdline` before killing.

### 6. Tool input may leak secrets to Discord (Medium)

**File:** `claude-notify.sh:128-141`

When `SHOW_TOOL_INFO=true`, tool input (commands, file paths) is embedded in Discord. Commands containing API keys, bearer tokens, or passwords would be visible to the channel.

**Mitigation:** Add a redaction layer for common secret patterns.

### 7. PATH prepend allows binary hijacking (Medium)

**File:** `claude-notify.sh:27`

`PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"` -- if these directories are writable, a malicious `jq` or `curl` could intercept all data.

**Mitigation:** Use `command -v` to resolve full paths at startup.

### 8. Lock mechanism proceeds without lock after exhaustion (Medium)

**File:** `claude-notify.sh:236-250`

After 100 failed lock attempts, proceeds unlocked, risking state corruption.

**Mitigation:** Skip the update entirely instead of proceeding unlocked.

### 9. /tmp full causes orphaned heartbeat (Medium)

When `/tmp` is full, PID file write fails silently. Heartbeat becomes unkillable via normal SessionEnd path.

**Mitigation:** Check disk space on startup with prominent warning.

### 10. No stdin read timeout (Low)

**File:** `claude-notify.sh:80`

`cat 2>/dev/null` with no timeout. Script can block indefinitely if caller keeps stdin open.

**Mitigation:** Use `timeout 5 cat` or `read -t 5` loop.

---

## Positive Security Practices

- Config directory `chmod 700`, `.env` file `chmod 600`
- Webhook URL never logged
- `PROJECT_NAME` sanitized with character whitelist `[A-Za-z0-9._-]`
- JSON validated before parsing (`jq empty`)
- Tool input truncated to 1000 chars
- Color values validated as numeric before use
- `.gitignore` excludes `.env` and `*.env`
- HTTPS enforced in URL validation
- Self-healing on API failures (never crashes the hook)

---

## Recommendations (Priority Order)

1. **Immediate:** Set `chmod 700` on `$THROTTLE_DIR` after creation
2. **Immediate:** Replace `eval` in `load_env_var` with `declare -g` or nameref
3. **Short-term:** Make file writes atomic (write-to-temp + `mv`)
4. **Short-term:** Add maximum lifetime to heartbeat daemon (24h)
5. **Short-term:** Validate process identity before killing PIDs
6. **Medium-term:** Add secret redaction for tool input
7. **Medium-term:** Add stdin read timeout
8. **Medium-term:** Make webhook URL validation a hard failure
9. **Long-term:** Move state to `$XDG_RUNTIME_DIR`
10. **Long-term:** Pin CI action versions to SHA hashes
