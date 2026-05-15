# Security Guards

Durable lessons about the guard-handler detection layer and the patterns
guard files must cover to remain effective.

## M-005: Dangerous-command guards must use syntax-aware detection, not pattern matching

Domain: security-guards
Status: active
Scope: hooks/guard-handler.py detectors, hooks/guards/destructive-commands.md, hooks/guards/raw-codex-delegation.md, hooks/guards/sensitive-files.md, hooks/guards/hardcoded-secrets.md, .doyaken/guards/*.md
Applies to phases: any phase that runs a Bash tool; guard authoring/maintenance
Applies to paths: hooks/guard-handler.py, hooks/guards/*.md, .doyaken/guards/*.md
Last verified: 2026-05-15
Recheck when: a new dangerous-command class is added, a guard adds a new event type, or the guard frontmatter parser changes

Lesson:
Naive regex guards over Bash input miss real threats and false-positive on
legitimate cleanup. Dangerous-command detectors must be syntax-aware: they must
extract real command tokens out of shell wrappers (`nice`, `timeout`, `xargs`,
`find -exec`), command substitutions (`` `…` ``, `$(…)`, `eval`,
`bash -c`/`sh -c`), heredocs, parameter expansion, alias resolution, package
runners (`npx …`, `npm exec --call`), and interpreter payloads
(`python -c`, `node -e`, `ruby -e`, `perl -e`) before matching. Pattern files
should declare what they cover and what they intentionally allow (e.g.,
subdirectory `rm -rf ./build`).

Evidence:
- `8b62b46 fix(guards): harden destructive command detection` (644 LoC added
  in `hooks/guard-handler.py`, plus updates to four guard files) replaces a
  naive regex with syntax-aware detection covering shell wrappers,
  substitutions, aliases, xargs, find exec, and protected root/home/cwd target
  forms, while explicitly allowing documented safe subdirectory cleanup.
- `4290403 feat: block unsafe raw codex delegation` covers the same surface for
  Codex delegation: launch wrappers (`nice`, `timeout`, `xargs`, `find -exec`),
  interpreter payloads, package runners (`npx codex`, `npm exec --call …`),
  shell-nested `bash -c`/`eval` payloads, heredocs, and unresolved/unreadable
  script paths.
- `hooks/guard-handler.py` exposes helpers including
  `extract_executable_backticks`, `extract_dollar_substitutions`,
  `is_doyaken_codex_wrapper`, and heredoc/substitution extraction.
- Guard `.md` files state explicitly what is caught and what is intentionally
  allowed.

Future agent behavior:
- When adding or modifying a guard for a dangerous command class, route through
  a detector in `guard-handler.py`, not a flat regex in the guard frontmatter.
- New detectors must consider wrappers, substitutions, heredocs, interpreters,
  and package runners. If a class is genuinely flat-regex-safe, justify it in
  the guard body.
- Guard frontmatter is parsed regex-based and accepts only flat `key: value`
  pairs — no nested objects or arrays.
- `block` actions exit 2; `warn` actions exit 0. Other non-zero exits are
  errors, not blocks. Keep detectors fast — they run on every tool invocation.
- Update the guard `.md` body to document caught patterns and intentional
  exceptions so reviewers can audit the boundary.
