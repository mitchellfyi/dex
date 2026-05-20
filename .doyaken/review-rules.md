# Review Rules

Path-specific review focus for Doyaken review waves.

## `dk.sh`

- Verify zsh-only syntax intentionally stays in `dk.sh`.
- Public shell functions must keep `unalias` / `unfunction` re-sourcing guards.
- Phase messages and lifecycle scope boundaries must stay consistent with the
  matching skill and phase-audit prompts.
- After changes, run `zsh -n dk.sh`.

## `lib/*.sh`

- Must remain bash/zsh-compatible; no zsh-only parameter expansion or arrays.
- Shared state-file helpers should be cleaned up by `dk_cleanup_session` and
  legacy migration when appropriate.
- After changes, run `bash -n lib/<file>.sh`.

## `hooks/*.sh` And `bin/*.sh`

- Bash scripts should use `#!/usr/bin/env bash` and `set -euo pipefail`.
- User-facing output should use Doyaken output helpers when common.sh is sourced.
- Hook behavior is security-sensitive; fail closed for dangerous operations.
- After changes, run `bash -n <file>` and `shellcheck` when available.

## `hooks/guard-handler.py`

- Python stdlib only.
- Never pass user-controlled strings through `shell=True`.
- Exit code 2 means "block"; other non-zero exits are hook errors.

## `skills/*/SKILL.md`

- Skills must be codebase-agnostic and discover tooling at runtime.
- Lifecycle skills must preserve phase ownership: no commits in Phase 3, no PR
  creation before Phase 5, no external reviewer polling before Phase 6.
- Skill instructions should avoid recursively invoking broader loops from inside
  already-looped phases.

## `prompts/phase-audits/*.md`

- Phase audits should verify the phase-specific completion gate and avoid
  duplicating work owned by the invoked skill.
- Phase 3 single-wave audits may complete with `FINDINGS_FIXED:N`; the outer
  `/dkreviewloop` owns the adaptive consecutive `CLEAN` gate.
- Completion criteria must match the state/result files read by `dk.sh` and
  `hooks/phase-loop.sh`.

## `agents/*.md`

- Review agents are read-only and must not edit files.
- Review agents should not enable project memory; review waves must
  not create `.claude/agent-memory/` artifacts as a side effect.
- Findings require exact evidence, a concrete trigger, and confidence >= 50.
- Domain-specific agents should return `N/A` quickly when their domain is not
  relevant to the diff.

## Docs

- README and `docs/autonomous-mode.md` must describe the same lifecycle semantics
  as `dk.sh`, skills, and phase-audit prompts.
- Avoid documenting draft PR or external reviewer behavior as Phase 3 work;
  that belongs to Phase 5/6 and `/dkprreview`.
