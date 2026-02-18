# Project Audit Skill — Design Document

## Overview

`/project-audit` is a generalized multi-agent audit skill for Claude Code that performs a comprehensive, parallel assessment of any codebase. It is designed to be language-agnostic, framework-agnostic, and immediately useful on any project without configuration.

## Design Decisions and Tradeoffs

### 1. Five Core Agents, Not Four

The existing `/swarm-audit` uses 4 core agents (Skeptic, Builder, Guardian, Minimalist). For a whole-project audit, 5 core agents were chosen instead:

| swarm-audit | project-audit | Rationale |
|-------------|---------------|-----------|
| Skeptic | Craftsman (Code Quality) | Document skepticism becomes code quality analysis |
| Builder | Strategist (Feature Completeness) | Implementability becomes feature gap analysis |
| Guardian | Sentinel (Security) | Same safety focus, expanded to full codebase |
| Minimalist | Architect (Architecture) | Complexity reduction becomes structural evaluation |
| — | Inspector (Testing) | New: testing is critical for whole-project audits |

**Tradeoff:** 5 core agents means fewer optional slots at the default count of 6 (only 1 optional agent). This is acceptable because the core 5 cover the most universally important perspectives. Users who want more breadth can increase `agents=8` or higher.

### 2. Auto-Discovery Over Configuration

The skill auto-detects the project profile rather than requiring users to declare their stack. This is a deliberate choice:

- **Pro:** Zero-configuration for first use. Works immediately on any project.
- **Pro:** Discovery process forces the orchestrator to actually read the codebase before dispatching agents, improving context quality.
- **Con:** Discovery adds latency (30-60 seconds of file scanning before agents launch).
- **Con:** Detection heuristics may misclassify edge cases.

**Mitigation:** Users can override with `include=` and `skip=` if auto-detection gets it wrong. The skill also reports which agents were selected and why, making misclassification visible.

### 3. Structured Output Over Conversational Output

Agent reports follow a rigid template rather than free-form analysis:

- **Pro:** Reports are comparable across agents. The master assessment can reliably extract ratings, findings, and recommendations.
- **Pro:** Machine-parseable structure enables future tooling (dashboards, trend tracking).
- **Con:** Rigid structure may constrain agents from providing insights that do not fit the template.
- **Con:** Some agents may produce formulaic output.

**Mitigation:** The "detailed" verbosity mode allows deep-dives beyond the template structure. The template itself is broad enough to accommodate most findings.

### 4. Master Assessment as Synthesis, Not Average

The master assessment does not simply average agent ratings. It applies weighted scoring (core agents 1.0x, optional agents 0.8x) and explicitly identifies consensus vs. contested findings. This matters because:

- A security finding from Sentinel alone should carry more weight than an identical finding from Chronicler (Documentation agent).
- Contested points are often where the most valuable insight lives — the master assessment must engage with disagreements, not paper over them.

### 5. Implementation Roadmap Over Raw Findings

Many audit tools produce a list of findings and stop. This skill goes further by organizing findings into a phased implementation roadmap with effort estimates and dependency ordering. This is the highest-value output for the user.

**Tradeoff:** The roadmap is the orchestrator's synthesis, not the agents'. It requires the orchestrator to exercise judgment about sequencing and dependencies. This judgment may occasionally be wrong.

**Mitigation:** The roadmap is always accompanied by the raw agent reports. Users can disagree with prioritization while still benefiting from the findings.

### 6. Issue Creation as Opt-In

The skill asks before creating GitHub issues rather than auto-creating them. This differs from `/check-pr` which creates issues by default.

**Rationale:** An audit can produce 10+ recommendations. Auto-creating issues would flood the issue tracker. The user should choose which recommendations warrant tracking.

### 7. Agent Count Limits (4-12)

- **Minimum 4:** Below 4, you lose too many core perspectives. The minimum ensures at least 3 core agents even with aggressive `skip=` usage.
- **Maximum 12:** Beyond 12, diminishing returns set in. Agent reports start to overlap significantly, and synthesis becomes unwieldy. The 12-agent ceiling also keeps execution time reasonable (agents run in batches of 5).

### 8. Verdict Categories

Four verdicts instead of a numeric scale:

| Verdict | When | Why not just a number? |
|---------|------|------------------------|
| Ship It | 4.0+ aggregate, no P0 findings | Numbers lose context. "4.2/5" does not tell you what to do. |
| Ship With Fixes | 3.0-3.9 aggregate, or any P0 finding | "Ship With Fixes" communicates urgency without panic. |
| Needs Work | 2.0-2.9 aggregate | Clearly signals "stop adding features, fix fundamentals." |
| Rethink | Below 2.0 aggregate | Rare but necessary. Says "more of the same will not help." |

## Differentiation from /swarm-audit

| Aspect | /swarm-audit | /project-audit |
|--------|-------------|----------------|
| Scope | Single document or topic | Entire project |
| Discovery | None — user provides target | Auto-discovers project profile |
| Core agents | Skeptic, Builder, Guardian, Minimalist | Craftsman, Architect, Sentinel, Inspector, Strategist |
| Optional agents | 6 options, manually relevant | 7 options, auto-selected by profile |
| Output | Section-by-section ratings of a doc | Holistic project assessment with roadmap |
| Roadmap | Recommended action plan | Phased implementation roadmap with effort + dependencies |
| Issue creation | Not included | Opt-in post-audit issue creation |
| Competitive analysis | Not included | Available via Scout agent |

They are complementary: use `/swarm-audit` to deep-dive a specific design doc, use `/project-audit` for periodic whole-project health checks.

## Installation and Distribution

### For a Single Project

Copy the skill file into your project:

```bash
mkdir -p .claude/commands/
curl -o .claude/commands/project-audit.md \
  https://raw.githubusercontent.com/<owner>/<skill-repo>/main/project-audit.md
```

Then invoke with `/project-audit` in any Claude Code session within that project.

### As a Standalone Skill Repository

The skill is designed to be distributable as a standalone repository:

```
claude-code-skills/
├── commands/
│   ├── project-audit.md
│   ├── swarm-audit.md
│   └── ...
├── README.md
└── install.sh          # Copies commands into target project's .claude/commands/
```

The `install.sh` script would:

```bash
#!/bin/bash
TARGET="${1:-.}"
mkdir -p "${TARGET}/.claude/commands"
cp commands/*.md "${TARGET}/.claude/commands/"
echo "Installed $(ls commands/*.md | wc -l) skills into ${TARGET}/.claude/commands/"
```

### As a User-Level Skill (Future)

Claude Code may eventually support user-level skill directories (e.g., `~/.claude/commands/`). When that happens, installing once would make the skill available in all projects without per-project copies.

## Future Enhancements Roadmap

### Short-Term (Next Iteration)

1. **Trend Tracking** — If a previous audit exists in the output directory, compare ratings and highlight improvements/regressions. Show a delta column in the ratings table.

2. **Custom Agent Definitions** — Support `.claude/audit-agents.json` for project-specific agent personas (e.g., a "Regulator" agent for GDPR-sensitive projects). The schema is defined in the skill file but not yet implemented.

3. **Project-Level Defaults** — Support `.claude/audit-config.json` so teams can standardize audit parameters without typing arguments every time.

### Medium-Term

4. **Structured JSON Output** — In addition to markdown reports, emit a `project-audit.json` with machine-readable ratings, findings, and recommendations. This enables:
   - CI integration (fail builds if aggregate rating drops below threshold)
   - Dashboard visualization
   - Historical trend charts

5. **Differential Audit** — `git diff`-aware mode that only audits changed files since the last audit or since a given commit. Faster for incremental checks.

6. **Agent Memory** — Let agents reference findings from previous audits. "In the last audit, I flagged X. Has it been addressed?" This requires persisting a summary file between audit runs.

### Long-Term

7. **Multi-Repo Audit** — For monorepos or microservice architectures, run the audit across multiple repositories with cross-repo dependency analysis.

8. **Interactive Mode** — After the audit completes, enter an interactive Q&A mode where the user can ask follow-up questions and agents are re-invoked as needed to provide deeper analysis.

9. **Audit-as-CI** — A GitHub Action wrapper that runs `/project-audit` on a schedule (e.g., weekly) and posts results as a GitHub issue or wiki page, with trend tracking.

10. **Community Agent Library** — A registry of agent personas contributed by the community. Users could install domain-specific agents (e.g., "HIPAA Compliance", "Kubernetes Best Practices", "React Performance") from a central repository.
