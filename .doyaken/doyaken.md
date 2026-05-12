# Doyaken — Doyaken

## Tech Stack
- **Shell (zsh):** `dk.sh` — main CLI functions, sourced in `~/.zshrc`
- **Shell (bash):** `hooks/*.sh`, `bin/*.sh` — hooks and CLI scripts
- **Shell (bash/zsh-compatible):** `lib/*.sh` — shared libraries
- **Python 3 (stdlib only):** `hooks/guard-handler.py` — guard evaluation engine
- **Markdown + YAML frontmatter:** Skills, agents, guards, prompts, rules

## Quality Gates
| Check | Command | Scope |
|-------|---------|-------|
| Lint | `shellcheck dk.sh bin/*.sh hooks/*.sh lib/*.sh` | Core runtime shell scripts |
| Syntax (bash) | `bash -n lib/<file>.sh` | Library modules, hooks, bin scripts |
| Syntax (zsh) | `zsh -n dk.sh` | dk.sh only |
| Test | N/A | No test suite |
| Format | N/A | No formatter configured |
| Typecheck | N/A | Not applicable (shell/Python) |
| Generate | N/A | No code generation |
| All | N/A | No unified check command |

## Project Structure
```
dk.sh                Main shell functions (zsh only, ~2140 lines)
settings.json        Claude Code hook definitions template
install.sh           Quick-start installer wrapper
agents/              Sub-agents (symlinked to ~/.claude/agents/)
bin/                 CLI scripts: install, uninstall, init, uninit, config, status
docs/                Extended docs: guards, autonomous mode
hooks/               Claude Code hooks + guard handler
  guards/            Built-in guard rules (5 rules)
lib/                 Shared shell libraries (8 modules)
prompts/             Prompt templates for skills/agents
  phase-audits/      Phase-specific audit prompts (1-6 + prompt-loop)
skills/              Lifecycle skills (16 total, symlinked to ~/.claude/skills/)
.doyaken/            Per-project config (this directory)
```

## Files to Never Commit
- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.doyaken/worktrees/` (ephemeral, gitignored)
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

## Reviewers

Reviewers assigned when the PR is marked ready for review (Phase 6). Two types:
- `request` — `gh pr edit --add-reviewer <handle>` (humans, Copilot, anything GitHub supports)
- `mention` — `@<handle>` posted as a PR comment (for AI agents that watch mentions)

| Handle | Type | Notes |
|--------|------|-------|
| @mitchellbryson | request | Authenticated GitHub user |
| Copilot | request | GitHub Copilot review |

Edit rows directly or rerun `dk config`. Remove a row to skip a reviewer.

## Rules
- @rules/shell.md — Shell scripting conventions and language boundaries
- @rules/skills-prompts.md — Skill, agent, guard, and prompt conventions
- @rules/architecture.md — Architecture patterns and state management

## Workflow
Run `/doyaken` to begin the autonomous ticket lifecycle.
