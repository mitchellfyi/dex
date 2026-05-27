# Dex

Dex lives at <https://dexcode.ai> and is owned and run by Synthetic Industry (<https://syntheticindustry.ai/>).

## Tech Stack
- **Shell (zsh):** `dx.sh` — main CLI functions, sourced in `~/.zshrc`
- **Shell (bash):** `hooks/*.sh`, `bin/*.sh` — hooks and CLI scripts
- **Shell (bash/zsh-compatible):** `lib/*.sh` — shared libraries
- **Python 3 (stdlib only):** `hooks/guard-handler.py` — guard evaluation engine
- **Markdown + YAML frontmatter:** Skills, agents, guards, prompts, rules

## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Lint | `shellcheck dx.sh bin/*.sh hooks/*.sh lib/*.sh` | Core runtime shell scripts |
| Syntax (bash) | `bash -n lib/<file>.sh` | Library modules, hooks, bin scripts |
| Syntax (zsh) | `zsh -n dx.sh` | dx.sh only |
| Test | N/A | No test suite |
| Format | N/A | No formatter configured |
| Typecheck | N/A | Not applicable (shell/Python) |
| Generate | N/A | No code generation |
| All | N/A | No unified check command |

## Project Structure
```
dx.sh                Main shell functions (zsh only, ~2800 lines)
settings.json        Claude Code hook definitions template
install.sh           Quick-start installer wrapper
agents/              Sub-agents (symlinked to ~/.claude/agents/)
bin/                 CLI scripts: install, uninstall, init, uninit, config, status, sync, maintain, log, tools, ui-capture, dxcodex, install-settings, status-line
docs/                Extended docs: guards, autonomous mode, RTK token reduction
hooks/               Claude Code hooks + guard handler
  guards/            Built-in guard rules (5 rules)
lib/                 Shared shell libraries (11 modules: common, agent-tools, codex, git, maintenance, output, provider, rtk, session, ui-capture, worktree)
prompts/             Prompt templates for skills/agents
  phase-audits/      Phase-specific audit prompts (1-6 + prompt-loop)
research/            DX evaluation harness (scenarios, scoring, improvement loop)
skills/              Lifecycle skills (18 total, linked into ~/.claude/skills/)
.dex/                Per-project config (this directory)
  providers.json     Repo-local default agent/provider profile
```

## Files to Never Commit
- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.dex/worktrees/` (ephemeral, gitignored)
- `~/.claude/settings.json` (user-specific)
- Anything containing secrets or credentials

## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | GitHub Issues (`gh`) | enabled |
| Design | Figma MCP | not configured |
| Error monitoring (Sentry) | Sentry MCP | not configured |
| Error monitoring (Honeybadger) | Honeybadger MCP | not configured |
| Deployments | Vercel MCP | not configured |
| Observability (Grafana) | Grafana MCP | not configured |
| Observability (Datadog) | Datadog MCP | not configured |

When an integration is "not configured", skip any workflow steps that reference it.
For ticket tracking: use the enabled tracker for all status updates, context gathering, and ticket lifecycle management.

## Tooling

Dex bootstraps [RTK](https://github.com/rtk-ai/rtk) — a Rust output-filtering
CLI — during `dx install`, `dx init`, `dx sync`, and `dx tools bootstrap` to cut
command-output tokens. Claude Code uses a fail-open PreToolUse rewrite hook
(`hooks/rtk-claude-hook.sh`) that runs *after* the guards; Codex receives
instruction-based RTK guidance instead. RTK is optional — set `DX_RTK_ENABLED=0`
to disable. See `docs/rtk-token-reduction.md`.

## Provider

This repo uses `.dex/providers.json` to default Dex runs to the Codex agent with
`gpt-5.3-codex`. Use `dx --agent claude` for a one-run fallback to the built-in
Claude/Opus 4.7 profile, or `dx --model <model>` to override the model passed to
the selected agent.

## Reviewers

Reviewers assigned when the PR is marked ready for review (Phase 6). Two types:
- `request` — `gh pr edit --add-reviewer <handle>` (humans, Copilot, anything GitHub supports)
- `mention` — `@<handle>` posted as a PR comment (for AI agents that watch mentions)

When attaching request reviewers, Dex normalizes `Copilot`, `@copilot`,
or Copilot aliases to GitHub CLI's special `@copilot` reviewer value. Normal
GitHub usernames are passed without a leading `@`.

| Handle | Type | Notes |
|--------|------|-------|
| @mitchellfyi | request | Authenticated GitHub user |
| Copilot | request | GitHub Copilot review |

Edit rows directly or rerun `dx config`. Remove a row to skip a reviewer.
## Rules
- @rules/shell.md — Shell scripting conventions and language boundaries
- @rules/skills-prompts.md — Skill, agent, guard, and prompt conventions
- @rules/architecture.md — Architecture patterns and state management
- @review-rules.md — Path-specific review focus for Dex review waves
- @memory/index.md — Durable repo memory index (scope-gated)

## Memory
`.dex/memory/index.md` maps durable repo memory to paths, phases, and
workflows. Agents should load only scoped active entries and verify them against
current code before relying on them.

## Maintenance

| Setting | Value |
|---------|-------|
| enabled | true |
| branch_prefix | dex/maintain/ |
| label | dex-maintenance |
| default_mode | report |
| max_prs | 1 |
| low_risk_fix_categories | docs, rules, guards, memory, tests |
| copilot_review | true |

`fix-scoped` may only patch the configured low-risk categories above, plus
verification updates in matching test files, unless a repo maintainer expands
this table. Publication is handled by the `dx maintain` CLI wrapper after the
provider exits so GitHub write credentials are not exposed to the agent
process.

## Workflow
Run `/dex` to begin the autonomous ticket lifecycle.
Run `/dxsync` or `dx sync` to refresh repo memory after significant repo,
workflow, review, or CI changes.
