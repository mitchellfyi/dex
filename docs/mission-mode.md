# Mission mode

Mission mode runs a Dex lifecycle as one accountable lead with helpers, in one
worktree, on one branch, normally ending in one PR. It is selected per launch
and changes nothing when it is not selected: every file described here checks
`DX_MISSION_ACTIVE=1` first and does nothing otherwise.

## Selecting it

Nothing to select: every lifecycle launch (`dx <ticket>`, `dx --workflow …`,
`dx run --spec …`) is a mission launch. Whether the lead delegates at all is
its own decision under `prompts/mission-delegation.md`; for a small task it
works alone and the roles go unused, as the smoke pair showed. To run the
legacy lifecycle instead, for a comparison or a bisect:

```
DEX_ORCHESTRATION_MODE=legacy dx <ticket-or-prompt>
```

`lib/provider.sh` (`dx_provider_claude`), for the lead's own session only:

- exports `DX_MISSION_ACTIVE=1` and `DEX_ORCHESTRATION_MODE=mission` to the
  launched process, so hooks and guards can tell a mission from a legacy run;
- caps helpers: `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` (helpers cannot spawn
  helpers) and `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` to `DEX_MISSION_MAX_HELPERS`,
  default 2;
- passes the three helper roles with `claude --agents` (`dx_mission_agents_json`
  in `lib/mission.sh`), unless the caller already passed `--agents`;
- initialises the mission ledger once for the session (`dx_mission_prepare_launch`).

Review children, assessments, triage and session-only launches never take this
path, so a Phase 3 reviewer is not a mission helper and does not see the lease.
A Codex-engine lifecycle is a mission without the roles: the ledger, the
lease and memory capture apply, and completion ingests the lead's
observations (Codex has no SessionEnd hook); the helper roles ride on
`claude --agents` and the SubagentStart/SubagentStop hooks are Claude Code's,
so a Codex lead delegates through `bin/dxcodex.sh` as before.

The roles are passed on the command line rather than installed as
`.claude/agents/*.md` files on purpose: `~/.claude/agents` on an installed host
links into the Dex checkout, and a file there would be live for every Claude
session on the machine, mission or not.

## The ledger

`$DX_STATE_DIR/<session>.mission/` (default `~/.claude/.dex-phases/`) holds:

| File | Role |
|---|---|
| `records.jsonl` | Append-only, fsync'd. One JSON record per write with `schema_version`, `kind`, a strictly increasing `generation`, `recorded_at`, `actor` and `fields`. This is the truth |
| `current.json` | A snapshot folded from the records: mission, lease, assignments by id, decisions, self-checks, evidence links, counts. Rebuilt from the log on demand (`rebuild`); checked against it by `verify`. Mode 0600; a reader refuses it when it is no longer a private regular file |
| `observations.jsonl` | Candidate facts helpers submitted in their `dx-result` blocks, with agent, revision and `trust: candidate`. Input to the memory pipeline, not memory |
| `violations.jsonl` | One line per advisory guard warning: guard, actor, agent type, tool, lease holder, detail |
| `brief.md` | Only when no system context existed at launch; a placeholder the lead replaces by recording the accepted brief |

Record kinds: `mission`, `assignment`, `write-lease`, `decision`,
`evidence-link`, `selfcheck`, `observation-ref`, `feedback-ref`, `note`.

The CLI is `bin/mission.sh <session> <init|record|lease|observe|feedback|show|verify|rebuild>`
(internal tier; `scripts/mission_ledger.py` does the ledger work, `observe` feeds the memory
store and `feedback` the outbox). Every write that
happens inside a run also leaves an event in the run journal: `mission.started`,
`mission.lease.acquired`, `mission.lease.released`,
`mission.assignment.<status>`, `mission.decision`, `mission.selfcheck`,
`mission.evidence.linked`, `mission.observation`, `mission.feedback`,
`mission.note`. See docs/events.md.

Exit codes: 0 ok; 1 `verify` found a problem; 2 usage, or a ledger that is not
safe to read; 3 refused (a lease someone else holds, `init` on an existing
ledger).

## The write lease

One holder at a time changes source. `lease acquire --holder <who> --scope <paths> --revision <sha>`
is refused (exit 3, naming the holder) while another holder has it; `lease
release --holder <who>` is refused unless that holder asks. The lead takes it
by hand before editing; the SubagentStart hook takes it for an implementer
when it is free and the SubagentStop hook releases it. Both revisions are
recorded, so the ledger says which tree a helper started from and left behind.

Enforcement is advisory and structural, by the owner's choice:

- read-only roles (`dx-investigator`, `dx-reviewer`) have Edit, Write and
  NotebookEdit disabled by the harness;
- one implementer runs at a time, in the foreground, so there is one writer by
  construction;
- the `mission-write-lease` and `mission-git-mutation` guards warn, name who
  holds the lease, and record every attempt in `violations.jsonl`; they do not
  deny (docs/guards.md).

The gap that remains, stated plainly: a read-only helper's shell is not
restricted, so a `sed -i` or an `rm` from an investigator is caught only by the
contract it was given, not by a guard. Serial execution is what makes that
acceptable in this version; parallel direct writers are not supported.

## Hooks

| Hook | File | In a mission |
|---|---|---|
| SessionStart | `hooks/load-ticket-context.sh` | Prints what the ledger knows: mission, brief, lease, open assignments, where the contract is |
| SubagentStart | `hooks/subagent-start.sh` | Registers the assignment, grants or refuses the lease, injects the helper's context (`hookSpecificOutput.additionalContext`). Cannot stop a helper from starting |
| SubagentStop | `hooks/subagent-stop.sh` | Parses the `dx-result` block from the helper's last message, records the outcome, releases the lease, keeps observations. A helper that ended without the block is asked once to add it (`decision: block`), then recorded as `UNREPORTED` |
| PreToolUse | `hooks/guard-handler.py` | The two mission guards above |
| PreCompact | `hooks/pre-compact.sh` | Names the mission, the lease and the ledger path so the compacted lead re-reads them |
| SessionEnd | `hooks/session-end.sh` | `session.usage` (not mission-specific; see docs/events.md § Model usage) |

Both subagent hooks are registered in `settings.json` with the matcher
`dx-implementer|dx-investigator|dx-reviewer`; `dx reload` installs them. An
agent of any other type, or any hook outside a mission, is ignored.

## Roles and the contract

`prompts/mission-delegation.md` is the contract: when to do work and when to
delegate, what each role owns, the lease protocol, how to brief a helper, the
`dx-result` block helpers end with, and the lead's bounded self-check. Helpers
receive the pointer and the rules for their role in their injected context;
the lead reads the file once.

## Memory: capture, retrieval, invalidation

Observations become memory in three steps, none of which calls a model.

1. **Capture.** A helper puts `observations` in its `dx-result` block; the
   SubagentStop hook writes them to the mission ledger directory. The lead
   submits its own with `bin/mission.sh <session> observe --json '{"lesson":…,"evidence":…,"scope":…,"type":…}'`,
   which goes straight into the store and leaves an `observation-ref` in the
   ledger. At SessionEnd the helpers' rows are ingested too, from a byte
   cursor, so a second SessionEnd does not ingest them twice.
2. **Validate and store.** `scripts/memory_store.py` (`lib/memory.sh`) keeps one
   store per repository identity at `~/.claude/.dex-memory/<repo-key>/`
   (`DX_MEMORY_STORE_DIR` overrides it; worktrees share their main repo's).
   Ingest checks the fields (`lesson`, `evidence`, `scope` repo|environment|mission,
   `type` fact|decision|procedure|measurement|hypothesis), looks every file the
   evidence names up in the repository and records `path@blob` for each, and
   dedupes by (scope, lesson): a repeat raises `seen`. A fact, decision or
   procedure with a checkable file is `active`; a hypothesis, or a claim with
   nothing checkable, is a `candidate`; a measurement is calibration and is not
   retrieved by default. Missing evidence is rejected and the rejection is
   logged with its reason. `entries.json` is the consolidated view,
   `observations.jsonl` the raw log, both 0600.
3. **Retrieve.** `retrieve --paths …` returns the active curated entries from
   `.dex/memory/domains/*.md` whose `Applies to paths` match, plus the verified
   observations whose dependencies or text match, and appends a trace line to
   `retrieval.log` (session, role, paths, loaded, skipped with reasons, stale).
   The SessionStart hook does this for the branch's changed files plus the
   working tree's modified and new files, after a `recheck`; the SubagentStart
   hook does it for the helper's scope, each after a `recheck`. An entry whose
   dependency blob no longer matches is marked `needs-recheck` and named as
   stale, not shown as current; when the content returns to what was verified,
   the next recheck restores it. Curated entries may carry `Depends on: path@blob` for the same
   treatment through `curated-overlay.json`; their files are never edited.

### Every lifecycle feeds the store

Mission sessions capture observations through helpers and the lead's
`observe`. Every lifecycle, mission or legacy, Claude or Codex, also feeds the
store at the end through the **harvest** (`scripts/lifecycle_harvest.py`,
`dx_memory_harvest_session`), with no model call: review-ledger findings that
were fixed or stayed open become facts about their file and lens; override,
waiver and jump reasons and waived or skipped phases become decisions; a
failed gate becomes a fact carrying a capped, redacted tail of its log; heavy
work outside a gate is a measurement; and the warnings the guard handler
showed the agent, which it now logs to `<session>.guard-warnings.jsonl`, are
aggregated per guard. Notes, the implementer's seeded self-review rows,
rejected findings, passed gates and completed phases are not lessons. The
harvest runs at completion, in `dxrm` and in `dxclean`, before the session
state is removed, and a marker beside that state keeps it to once per
session. `DEX_MEMORY_RETRIEVAL=0` turns memory injection off at SessionStart
and SubagentStart; it exists for the memory on/off comparison.

### The store keeps itself in check

No human queue sits behind the store. Two passes keep it trim, and both end
in a decision rather than a pending item.

**Maintenance** is deterministic and runs at the end of every lifecycle or
mission session (`dx_memory_maintain`, also `dx memory maintain`). A
`candidate` fact, decision or procedure that two different sessions reported
independently becomes `active` with trust `corroborated`; a session repeating
itself does not count. An entry that stayed `needs-recheck` past
`--stale-days` (14) is retired as stale. A candidate nobody observed or
retrieved for `--idle-days` (45), or an active entry nobody retrieved for
`--unused-days` (90), is retired as idle or unused. Curator-promoted entries
are exempt from the unused rule. Every retirement records its reason, and a
retired lesson that is observed again reopens on probation with its history
kept. Retrieval never shows a retired entry. `maintenance.log` keeps one line
per pass.

**Curation** is the critical review, and it is the model's job, not a
person's. `dx memory curate` runs maintenance, exports the live entries with
their retrieval counts and dependencies (`review-export`), and asks a fresh
print-mode session, in the repository, with `Read`, `Grep` and `Glob` only,
to decide for each entry whether it earns its keep: `promote`, `retire`,
`merge`, `rewrite` or `keep`, each with a reason another engineer could
check. The prompt is `prompts/memory-curator.md`. The deterministic layer
(`curate-apply`) validates every decision, applies the valid ones to the
store, logs each to `curation.log` with the actor, and leaves tracked files
alone: decisions about `.dex/memory` entries go to `curated-overlay.json`,
which `dx sync` reads. Unknown ids, empty reasons and dead merge targets are
rejected and logged while the rest apply. An answer with no decisions block,
a failed CLI or a timeout leaves the store as maintenance left it and exits
non-zero.

The review is due when at least `--min-changes` (5) entries changed since the
last one, or when one did and the last review is `--max-age-days` (7) old;
`--force` overrides. Nightly maintenance (`dx maintain`) also runs the research consumer over the
machine's feedback outbox before its own agent, with caps
(`DEX_MAINTAIN_CONSUME`, `DEX_MAINTAIN_CONSUME_MAX_CANDIDATES`,
`DEX_MAINTAIN_CONSUME_MAX_MINUTES`), so candidates are decided without anyone
invoking it. The lifecycle calls `dx_memory_curate_if_due` after Phase 6
and before cleanup, so the review runs in its own session after the lifecycle's
conversation has ended, bounded by `--max-turns` (12) and `--budget-seconds`
(600). `DEX_MEMORY_CURATE=0` turns the lifecycle trigger off;
`DX_MEMORY_CURATOR_BIN` substitutes the CLI (the tests use a stub). A
`memory.curated` event is written when a session id is known.

### Trusted memory lands on its own

A promotion is not finished while it lives only in the store. `dx memory land`
(`materialize` plus a commit) writes every curator-promoted entry whose
evidence names at least one file into `.dex/memory/domains/<domain>.md` in the
entry format the index describes, with `Depends on: path@blob`, a `Source:`
line naming the store entry, and an index row; it applies the overlay's
`retired` and `needs-recheck` decisions to the existing entries as a one-line
status change inside their blocks. Files it did not create are never
rewritten. The domain is the one the curator named in its `promote` decision
(an existing domain from the index, or a new kebab-case one, which gets a
Domains row and a new file).

The landing runs in a throwaway worktree branched from the default branch's
upstream, on `dex/memory-<timestamp>`, with one `chore(memory): …` commit that
lists the entries. With a remote it pushes the branch, opens a PR with the
GitHub CLI and requests auto-merge (`gh pr merge --auto --squash`); when the
repository has auto-merge turned off the PR waits for its checks or a merge,
and the command says so. Without a remote the branch stays local and the
command says that too. The store then records `landed` (entry id, commit, PR)
so nothing lands twice, and retrieval serves the tracked entry instead of the
store copy once it is in the checkout. Rollback is a revert of that commit;
the store keeps the entries.

The lifecycle runs curation and then landing at completion
(`dx_memory_curate_if_due`, `dx_memory_land`; `DEX_MEMORY_LAND=0` turns
landing off). A write run of `dx sync` runs both before the agent, landing
`--in-place` into the checkout so the publish step that follows carries the
entries; an in-place landing that is thrown away before it is committed is
detected by the next `recheck` and lands again. `--dry-run` prints the plan
and writes nothing; `--no-pr` commits on the branch without pushing. Read-only
sync runs leave the store alone. Nightly `dx maintain` runs sync, so a
repository that sees no lifecycle still gets its review and its landing.

`dx sync`'s `--state-dir` defaults to the store and its `--dry-run` is enforced
in code: the repository is compared before and after the provider and the
command fails, naming the changed paths, if anything differs (nothing is
reverted). A write run with nothing new (no store entry changed since the
last completed write run and no `.dex` file changed) starts no agent and says
so; `--force` runs it anyway. The sync agent treats a `curated` entry as pre-approved, never
re-promotes a `retired` one, and leaves the landed entries as the script wrote
them.

## Feedback to Dex research

A potential Dex-level problem found during a mission is not fixed in the
mission. The lead writes a bounded, sanitised candidate:

```
bin/mission.sh <session> feedback --json '{"mechanism":"…","symptom":"…","evidence_summary":"…"}' [--reproduction check.sh] [--patch change.patch]
```

`scripts/feedback_outbox.py` (`lib/feedback.sh`) keeps one directory per
mechanism under `~/.dex/feedback/` (`DX_FEEDBACK_DIR` overrides): a versioned
`manifest.json`, `evidence-summary.md`, `metrics.json`, and the optional
`reproduction/check.sh` and `proposed-change.patch`, stored but never
executed there. The same mechanism reported again adds support rather than a
new candidate. Feedback submitted while the consumer runs is tagged
`origin: research` and waits for a later campaign.

### States

A candidate is `captured` when it has evidence but neither a reproduction nor
a patch, and `eligible` once it has one of them. A consumer claims it (a lease
with a TTL; `list` reports a lapsed lease as the underlying state, so a
crashed consumer hides nothing) and ends the claim with one of:

| Transition | State afterwards | Claimable again |
|---|---|---|
| `decide --decision rejected` | `evaluated` | no |
| `decide --decision validated` | `evaluated` | yes, for `activate` |
| `decide --decision inconclusive` | `eligible`, `attempts` + 1 | yes |
| `activate --dex-dir DIR` (needs `validated`) | `activated` | no; `revert` takes it back |
| `revert --reason TEXT` | `reverted` | no |
| `retire --reason TEXT` | `retired` | no |

`activated`, `reverted` and `retired` are the terminal states. A rejected
candidate is final too: nothing can claim it. Every candidate the consumer
touches ends in one of those four on evidence, without waiting for a person.
A `retired` candidate reported again adds support and stays retired;
`submit --reopen REASON` brings it back with a fresh attempt budget and keeps
both the reason and the retirement it undoes.

### The consumer

```
bash research/consume.sh --max-candidates N --max-minutes M --max-iterations I [--dex-source head|working-tree] [--evaluator SCRIPT] [--activate low|off] [--max-attempts N] [--reproduce on|off] [--dex-dir-live DIR] [--review on|off]
```

All three caps are required. For each candidate it claims the lease, builds a
pinned read-only baseline runtime (a `git archive` of HEAD through
`review_eval_prepare_runtime`, or the allowlisted paths of the working tree,
hashed), copies it, judges the patch's paths against the allowlist
(`skills/*/SKILL.md`, `prompts/**/*.md`) from the patch itself, applies it to
the copy all-or-nothing, runs the evaluator on both runtimes and records
`evaluation.json` with the decision, reason, `risk_tier` and cost
(`model_calls`, `model_seconds`). The default evaluator,
`research/consume-eval.sh`, is deterministic: a static check of the changed
files and the candidate's reproduction run against each runtime.

What the deterministic layer decides, and what follows from each decision:

- A reproduction that fails on the baseline and passes on the candidate is
  `validated`. The allowlist is the risk tier, so every validated patch is
  `low`. With `--activate low` (the default; `DX_RESEARCH_AUTO_ACTIVATE=off`
  changes it) the consumer first puts the change through the review gate
  described below, and on `approve` applies the patch to the live Dex checkout
  (`--dex-dir-live`, default `$DEX_DIR`) through `git apply --check` then
  `git apply`, unstaged and uncommitted, and records `activation` in the
  manifest and `evaluation.json`: the checkout's HEAD, the patch hash, the
  changed paths and the exact `rollback` command, `git -C DIR apply -R
  <patch>`. `feedback_outbox.py <dir> revert <id> --owner WHO --reason TEXT`
  runs that rollback and records why. A patch that no longer applies to the
  live checkout spends an attempt per run and is retired at the limit.
  `--activate off` leaves validated candidates `evaluated` for a person; a
  later run with activation on takes them.
- A patch outside the allowlist, one that does not apply, a candidate that
  breaks the static check or still fails its reproduction is `rejected`, and
  that is final.
- Anything the evidence cannot settle is `inconclusive`: the candidate returns
  to `eligible` with one attempt spent, and at `--max-attempts` (default 3)
  it is `retired` with the reason: `inconclusive after 3 evaluations`, or
  `reproduced 3 times, nothing fixed it` for a reproduction with no patch.

### What the model does

The model has two jobs. Both are bounded print-mode sessions that the
deterministic layer calls, parses and checks.

The first is to write the reproduction a `captured` candidate lacks.
With `--reproduce on` (the default) the consumer runs
`research/consume-reproduce.sh`, which turns `manifest.json` and
`evidence-summary.md` into a prompt and calls `claude -p` with `Read`, `Grep`
and `Glob` allowed and every writing tool disallowed, `--max-turns 12`
(`DX_CONSUME_REPRODUCE_MAX_TURNS`), `--setting-sources project,local
--strict-mcp-config` and text output, from the sealed baseline as its working
directory. The first live run granted no tools and hit the turn cap while
the model asked for files; that is why the tools are granted up front. The
answer must hold exactly one fenced `bash` block: a check that exits non-zero
where the problem is present and 0 where it is absent. The deterministic
layer takes over from there. The block must parse, and a short denylist
(network tools, `sudo`, git mutations, `rm -r` outside its own temp
directory, another model) is checked against its commands, not its text:
heredoc bodies and comments are removed with `hooks/shell_parse.py`, the
parser the guards share, and a denied word counts only in command position.
A reproduction of a parser bug has to carry `git commit` as data, and a
sandboxed init needs a stub file named `curl`; the first live run refused
both, and that is the failure this reading prevents. Anything the parser
cannot read is refused. The check is installed as `reproduction/check.sh`
(mode 0700) under the claim, the candidate becomes eligible, and it is
evaluated in the same run. A check that fails on the baseline is a reproduced
bug nobody has fixed: `inconclusive`, one attempt spent, retired at the
limit; because the consumer may only change prompts and skills, that
retirement also writes `mission-brief.md` into the package, a ticket-shaped
hand-off (`dx --workflow "$(cat …/mission-brief.md)"`) whose acceptance test
is the check itself. One that passes retires the candidate at once with
`could not reproduce (model-written check passes on the baseline)`. No usable
answer spends an attempt and leaves the candidate `captured` for the next
run. A run makes at most one model call per candidate; `cost.model_calls` and
`cost.model_seconds` in `evaluation.json` say what it cost.
`DX_CONSUME_CLAUDE_BIN` substitutes the binary (the tests use a stub) and
`DX_CONSUME_MODEL_TIMEOUT` bounds the call in seconds.

The second is the critical review between `validated` and `activate`, the
only non-deterministic step before a live change. The evaluator proves that a
patch applies inside the allowlist and flips its reproduction check; it
cannot say whether the change is general, correct, or worth the context it
costs every future session. With `--review on` (the default;
`DX_RESEARCH_REVIEW=off` changes it) `research/consume-review.sh` gives a
fresh session (`claude -p`, four turns, `Read`, `Grep` and `Glob` only,
project and local settings, no MCP servers, the candidate runtime as its
working directory) the manifest, evidence summary, metrics, the unified diff
and the full text of each changed file as it reads with the patch applied,
and asks for one fenced `json` block: `approve` or `reject`, a reason, risks,
and a generality of `one-off`, `repo` or `dex-wide`. The bar is in the
prompt: the change earns its keep only if a future Dex session would behave
better for it on more than the one incident that produced it. Prose that
restates what the file already says, anything that narrows or contradicts an
existing rule without saying so, anything specific to one repository or
host, and anything that cannot be checked are rejected. The reviewer cannot
see the incident, the project that reported it, or how later sessions
behave; it judges the text against the evidence and the rest of the runtime.
`approve` activates as above, with the `review` and its cost recorded in
`evaluation.json`; `reject` retires the candidate with `review: <reason>`; a
review that produces no decision leaves the candidate `evaluated`, spends an
attempt, and is retried next run until `--max-attempts`, when it is retired
as `review unavailable`. `--review off` activates on `validated` alone, so
the two policies can be compared on the same outbox. Whatever the review lets
through is undone by the recorded rollback, `git -C DIR apply -R <patch>`,
or by `feedback_outbox.py <dir> revert <id> --owner WHO --reason TEXT`.

The run summary lists `decisions`, `activated`, `retired` with
`retired_reasons`, `activation_failed`, `reviews` and `review_unavailable`.
The baseline is never modified.
`research/orchestrate.sh`, `improve.sh` and `loop.sh` are untouched by this.

## Comparing mission mode with the legacy lifecycle

`research/ab/` holds the frozen comparison: `manifest.json` (tasks, arms, budget, evaluator,
endpoint, stopping rule), `launch-arm.sh` (one arm from an isolated trial root), `collect.sh`
(metrics with provenance; unknowns stay unknown) and `compare.sh` (the paired table).

An arm is a Dex checkout (a detached worktree under `.dex/worktrees/exp-*`), a fresh fixture
repository built from a research scenario, and its own state, journals, memory store, feedback
outbox and auto-memory directory. The arm's settings reach the provider through a `claude` shim on
PATH that adds `--setting-sources project,local --settings <arm-settings.json>`, so the operator's
user settings and global hooks never load and the login stays the operator's own. The lifecycle is
`dx run --spec` (headless, plan approval not required), capped by wall clock; a watcher issues
`dx control stop` once the phase passes 4, because fixture repositories have no remote and
Phases 5 and 6 are outside the measurement. Acceptance is the scenario's own `rubric.sh` through
the research harness's scorer with the LLM judge skipped. Tokens come from the transcripts the run
wrote, one count per request.

```
bash research/ab/launch-arm.sh --arm A  --task buggy-code-fix --trial-root <dir>
bash research/ab/launch-arm.sh --arm B0 --task buggy-code-fix --trial-root <dir>
bash research/ab/compare.sh <dir>/buggy-code-fix/A/metrics.json <dir>/buggy-code-fix/B0/metrics.json
```

Arms run one at a time. One pair is a smoke test; the manifest says what more would be needed.

### Memory on or off

`research/memory-ab/run.sh --task <scenario> --trial-root DIR --dex-dir <candidate>`
runs the candidate arm three times on one fixture task: a `seed` run that
fills a fresh store through the harvest and the lead's observations, then
`mem-on` and `mem-off` against a copy of that store, differing only in
`DEX_MEMORY_RETRIEVAL`. `compare.md` puts the collected metrics side by side.
One replicate per cell is a pilot; a gain claim needs replicates and the
interval, as AGENTS.md "Measuring Outcomes" says.

## What does not change

Phases 0 to 6, the Stop-hook receipts, review waves, gate receipts, controls
and process ownership are the same in mission mode. Mission mode organises
Phase 2 and records what happened; it does not lower a gate.

## Tests

The mission-mode tests are ordinary `tests/<name>-test.sh` files with rows in
`tests/manifest.tsv`: `ab-launch`, `feedback-consumer`, `feedback-outbox`,
`gate-env-fingerprint`, `intake-consolidation`, `memory-curate`, `memory-hooks`,
`memory-land`, `memory-maintain`, `memory-store`, `mission-context`, `mission-guards`,
`mission-launch`, `mission-ledger`, `session-usage-event`, `subagent-hooks`,
`sync-dry-run`, `usage-collect`. Run one with `bash tests/<name>-test.sh`, or the
set with `bash tests/run-all.sh mission memory feedback`. The curator and the
consumer's model steps are exercised with stub CLIs (`DX_MEMORY_CURATOR_BIN`,
`DX_CONSUME_CLAUDE_BIN`); no test calls a model.
