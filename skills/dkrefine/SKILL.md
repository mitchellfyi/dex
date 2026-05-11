---
name: "dkrefine"
description: "Technical refinement: map the architecture, clarify scope, identify design patterns, decompose into estimated sub-tickets — no implementation."
---

# Skill: dkrefine

Technical refinement of an engineering effort. Map the system's current architecture (or read the cached map), interrogate scope with the user, identify the design patterns that fit, decompose the work into estimated sub-tickets, and raise risks. Never implement.

## When to Use

- Invoked by the `dkrefine` shell wrapper (`dk refine <N|description>` or `dkrefine <N|description>`).
- Invoked directly inside an existing Claude session via `/dkrefine <input>`.

This skill is **not** part of the autonomous `dk` lifecycle. Do **not** write Phase 1 markers, do **not** activate the Stop-hook audit loop, do **not** rename branches, do **not** set ticket status to "In Progress", do **not** commit, do **not** create a worktree.

The defining output of `dkrefine` is a **decomposition into multiple estimated sub-tickets**, plus architecture, pattern, and risk comments on the parent. If the work cannot decompose into at least two independently shippable sub-tickets, `dkrefine` is the wrong tool — bail out (per §12 in Step 6) and tell the user to run `dk <ticket>` directly.

## Standing Platform Constraints

Two constraints apply to **every** refinement, regardless of ticket. The agent must address both during the question loop and re-check them in the quality gate before presenting the draft:

- **Multi-tenancy.** All configuration, data, and computation are tenant-scoped. Cross-tenant isolation must be preserved by every proposed change. Configuration surfaces are per-tenant by default; any setting that is _not_ per-tenant must be flagged explicitly with a justification.
- **Compute-heavy, low-user-count profile.** The platform is not high-traffic; it is heavy per-request computation (solvers, allocations, projections, cascades). Performance NFRs target the latency of a single computation and the scope of cascade recomputes — not requests-per-second. Caching, memoization, incremental recomputation, and cascade-scope minimization are first-class design tools. A proposal that triggers a naive O(N²) recompute over the whole plan on every edit is a red flag and must be challenged.

## Steps

### 1. Gather Context

Use the integrations configured in `doyaken.md § Integrations`. Skip any that are "not configured".

**Ticket tracker (if input is a ticket id or URL):**

- Read the ticket — title, description, acceptance criteria, relations, comments. Comments often hold prior decisions and stakeholder context.
- If the tracker supports it, check the assignee — but do **not** reassign and do **not** change status. Refinement is not work-start.
- Do **not** rename the branch. Do **not** push.

**Freeform input (no ticket id):**

- Derive intent from the user's description, the current branch name, and local documentation.
- Skip all tracker write-back steps later.

**Related work:**

- If the ticket has related or blocking issues, read those too.
- `git log --oneline -20` for recent local context.

### 2. Architecture Map (Read-only)

Foundational. Every later decision — design patterns, sub-tickets, risks, estimates — references this map. **This skill does not build the map** — that is the `dkarchitect` skill's job. `dkrefine` only reads it.

#### 2a. Read `.doyaken/architecture.md`

- **Present** → read it. It is a C4 model (System Context, Container, Component) plus multi-tenancy boundary and plug-point catalogue. Treat as the canonical current-state view. Skim the codebase to spot obvious drift against the map; note any drift in the Decision Log (§15) but do **not** rewrite the file silently.
- **Present but `last-refreshed` is older than 90 days** → use it, but flag staleness in the Decision Log and suggest the user run `/dkarchitect` to refresh.
- **Absent** → **stop and tell the user to run `/dkarchitect` first**, then re-invoke `/dkrefine`. The shell wrapper (`dk refine`) handles this bootstrap automatically outside plan mode; direct `/dkrefine` invocations need to run `/dkarchitect` themselves first because plan mode is read-only.

The C4 containers and components in the map are the **domains** sub-tickets will be tagged with in §12 — read them carefully now so you can attribute each sub-ticket to one.

#### 2b. Build the Codebase Component Map (specific to this change)

Overlay on `.doyaken/architecture.md`. Each refinement produces its own component map — which pillars (C4 containers / components) this particular change touches.

| Pillar | Path(s) on disk | Current responsibility | Touched by this change? |
| ------ | --------------- | ---------------------- | ----------------------- |

Pillars not touched are listed as `None — <reason>` so the omission is deliberate, not an oversight. Pillar names should match the C4 container or component names in `.doyaken/architecture.md` verbatim — this is what makes the Domain field in §12 cross-referenceable.

### 3. Internal Architecture Check

Before asking the user anything, answer these five questions to yourself. If you cannot answer all five with confidence, do more reading in Step 2 first.

1. What system boundaries does this cross? (services, pillars, ownership)
2. Which existing components participate, and which need to change? _(cite paths)_
3. What is the data/control flow before vs. after?
4. What invariants or contracts could break? (schema, API, tenant isolation, idempotency, cascade ordering)
5. What does a senior architect challenge about this direction? Especially: scale within a single tenant's plan, cascade explosion, solver/engine interaction, plug-point design.

### 4. Mandatory Question Loop

**Bar: at least four `AskUserQuestion` batches.** The per-call limit (typically three questions per call) is _only_ a per-batch limit — the _total_ number of questions is unbounded. Keep asking until every dimension below is either answered, explicitly deferred by the user, or proven non-applicable.

Group related questions in a batch. After each answer, re-check assumptions and unknowns — if new ones surface, ask another batch before drafting.

This is a **technical** refinement — engineering decomposition, not product discovery. Skip "value hypothesis", "user stories", and other PO-flavor probes. Cover **every** dimension below across the batches:

- **Goals & scope.** What does done look like _technically_? What is explicitly out of scope (and which OoS items are roadmap candidates vs. permanent)? Cross-project / cross-service interfaces.
- **Architecture & integration.** Chosen approach vs. alternatives; new components vs. extensions of existing ones (cite the existing ones by path); data model impact (new entities, new attributes, identity-vs-attribute split); sync/async; API/contract changes; backward compatibility; **interface pluggability** — what should be a strategy/plug-point so v2 does not need a schema migration.
- **Scale & multi-tenancy (mandatory, every ticket).**
  - Tenant-scoping: which new config/data is tenant-scoped? How is isolation preserved?
  - Compute profile: cost shape of the operation (per plan? per batch? per movement? O(N) in what)? Realistic upper bound for N in a single tenant's plan?
  - Cascade scope: when a single edit fires, what is the minimum recompute set vs. the worst-case recompute set? Is there a guarded "manual full re-run" vs. "incremental cascade" distinction?
  - Caching/memoization: which intermediate results are reusable across edits?
  - Tenant-config surface: what does the admin configure per tenant? Defaults? Per-product overrides?
- **Operational & risk.** Blast radius; rollback story; observability (per-failure reasoning logs, latency P50/P99 instrumentation, KPI value logging); security/permissions; rollout (flag, gradual, big-bang); dependencies on other teams/tickets; edge cases the implementer will hit first.

If the user defers a dimension, that dimension must appear verbatim under **Open Questions** in the draft. Do **not** silently make decisions on the user's behalf — even decisions that seem obvious — because the user's domain context, deadlines, downstream coordination, and prior decisions are invisible from inside the codebase.

### 5. Design-Pattern Analysis

After the conversation has converged on an approach, identify the design patterns that fit. **Surface only patterns that genuinely improve the design** — do not retrofit a pattern onto a trivial sub-ticket just to have one.

For each pattern you propose, capture:

- **Pattern name.** Standard vocabulary preferred (Strategy, Repository, Adapter, Observer, Factory, Pipeline, Plugin/Registry, Command, Chain of Responsibility, Template Method, Decorator, Memento, Saga, Outbox, …).
- **Why it fits.** The specific variability, coupling, or change-frequency concern it addresses on this ticket.
- **Where it lives in code.** Path or proposed location.
- **Sub-ticket(s) that embody it.** Each sub-ticket should be tied to at most one dominant pattern.
- **Alternative considered.** One sentence on what was rejected and why (e.g. "considered a Factory but the construction is trivial — Strategy alone is enough").

Cross-reference against §2c (Codebase Component Map): if the same pattern already exists in this codebase, **reuse it, do not reinvent it**. Cite the existing implementation's path.

If a refinement genuinely involves only mechanical work (config, copy, plumbing) with no pattern worth naming, record `— none, all sub-tickets are mechanical` explicitly. Silent absence is not allowed.

### 6. Assemble the Refinement Material

This is your **working memory**, not the user-facing output. Build all fifteen sections below so you have the inputs you need for the quality gate, the `ExitPlanMode` summary in Step 8, and the tracker write-back in Step 9. If a section is genuinely empty for this ticket, mark it `— none` rather than omitting it; an empty section is data too.

1. **Problem Statement (technical).** The change, broken into the natural engineering sub-domains the conversation surfaced (e.g. "Creation", "Allocation", "Expiration", "Visibility"). These sub-domains drive the grouping of Verification Criteria below.
2. **Codebase Component Map.** The table from §2c, finalised. Every entry cites a real path in this repo.
3. **Impact Domains.** Per-pillar **Heavy / Medium / Light / None** table with a one-paragraph reason per pillar. Walk every pillar discovered in Step 2, not a fixed list. Pillars not touched are listed as `None — <reason>`.
4. **Cross-component / cross-team interfaces.** For each Heavy- or Medium-impact pillar, name the contract: who owns what, where the boundary is in code, what shape data crosses it.
5. **Assumptions.** Explicit list of every assumption that survived the question loop. Each line ends with a source: `— user said X` / `— universally safe` / `— deferred to implementation` / `— deferred by user`.
6. **Edge Cases.** Bulleted list. Each edge case names the trigger and the expected behavior (or the expected exception), not just "what if X". Lean engineering: race conditions, partial failures, concurrent edits, replay, retries, ordering, timezone/DST, encoding.
7. **Out of Scope.** Bulleted list. Each item: one-line reason and a marker — _roadmap candidate_ vs. _permanent OoS_. Out of Scope being empty is itself a smell — refinement that excludes nothing has not yet drawn its boundaries.
8. **Verification Criteria.** Numbered, **each a testable assertion with a concrete observable outcome** — a test name, a query, an HTTP probe, a log assertion, a metric threshold. Prose-only criteria ("works correctly", "is performant") must be rewritten as mechanically checkable assertions. Group by the engineering sub-domains from §1.
9. **Non-Functional Requirements.** Broken into sub-sections:
   - **Performance.** Latency targets for the dominant operations (single computation, cascade trigger latency, KPI calc time, etc.). If the user has not given a number, use a placeholder and flag it as `TBD-during-refinement`.
   - **Observability.** What to log on success vs. failure; aggregate metrics; per-failure reasoning logs where the operation is debug-heavy.
   - **Configurability (per-tenant).** Every configuration surface introduced or changed. Tenant-scoping is implicit; explicitly note any setting that is _not_ per-tenant and why.
   - **Pluggability (architectural).** For each plug-point identified in §10, state the interface name, what v1 ships as the only registered implementation, and what v2/v3 candidates exist.
   - **Multi-tenancy.** Explicit section confirming tenant-scoping of new data/config, isolation guarantees, and any deviation from the platform's standing isolation stance.
10. **Design Patterns.** The full output of Step 5. Table format preferred: `Pattern | Why it fits | Location | Sub-ticket(s) | Alternative considered`.
11. **Risk Register.** Table `Risk | Likelihood (L/M/H) | Impact (L/M/H) | Mitigation | Owner`. At least one risk per Heavy-impact pillar.
12. **Proposed Sub-tickets.** Numbered list. Each carries:
    - **Title**
    - **Domain** — the C4 container (Level 2) or component (Level 3) name from `.doyaken/architecture.md` that this sub-ticket primarily lives in. Used downstream to identify the responsible owner. Must match a name in the architecture map verbatim — if a sub-ticket spans multiple containers, pick the one where the riskiest change lands and note the spillover in **Cross-component / cross-team interfaces** (§4).
    - **Scope** — one line
    - **Depends-on** — sub-ticket numbers it sequences after (or `—` for independent)
    - **Primary paths** — files / packages touched
    - **Size** — `XS` / `S` / `M` / `L` / `XL` (scale below)
    - **Pattern** — dominant design pattern from §10, or `— none` if not applicable

    Sub-tickets are sized so a single `dk <subticket>` lifecycle can complete each one. Sequencing must respect the dependency edges.

    **At minimum two sub-tickets are required.** If the work genuinely cannot be split into two or more independently shippable pieces, stop and tell the user that `dkrefine` is the wrong tool: they should run `dk <ticket>` directly. Do not create a single sub-ticket that mirrors the parent.

    **T-shirt size calibration:**
    - **XS** — < 0.5 day. Config, copy, single-file tweak with tests.
    - **S** — 0.5–1 day. One module, well-understood pattern, low integration risk.
    - **M** — 1–3 days. Multi-file feature, modest integration, requires tests.
    - **L** — 3–5 days. Cross-pillar work, new entity or new contract, non-trivial migration.
    - **XL** — 1–2 weeks. New subsystem, multiple new contracts, coordination across pillars. **An XL is a smell — try to split further before accepting it.**
    - **XXL** — refuse. Break into smaller sub-tickets and re-estimate.
13. **Estimation Summary.** Roll-up of §12:
    - Total count and size mix (e.g. "5 sub-tickets: 1×L, 3×M, 1×S").
    - **Critical path** — longest dependency chain, with summed size.
    - **Parallelizable** — which sub-tickets can run concurrently.
    - **Riskiest-to-estimate** — which sub-tickets carry the most schedule risk (typically the L/XL ones with new contracts or unknown integrations).
14. **Open Questions.** Every dimension the user explicitly deferred plus any architectural question you could not resolve. Each numbered, with the owner who can answer.
15. **Decision Log.** Running list of decisions made _during this refinement_, date-stamped. Include the architecture-map status: `Read existing map (last-refreshed YYYY-MM-DD)` or `Built map fresh — user to review and commit`.

### 7. Quality Gate

Before presenting via `ExitPlanMode`, walk this checklist against the material in Step 6. If any item fails, go back and fix the material.

1. Every Verification Criterion is a testable assertion with an observable outcome.
2. Every Heavy-impact pillar has at least one entry in Risk Register, Sub-tickets, and (if applicable) NFRs.
3. Every new entity / configuration explicitly states its multi-tenancy stance.
4. Every "we will add new X" line has been justified against existing X in the codebase, citing the existing X's path.
5. The Performance NFR names the dominant cost shape (per plan / per batch / per movement) and an upper-bound expectation for N.
6. Out of Scope is non-empty.
7. Every dimension from Step 4 is either answered in the material or explicitly listed under Open Questions.
8. **§12 contains at least two sub-tickets, each tagged with a Domain, t-shirt size, and design pattern (`— none` allowed for pattern, never for size or domain).** If decomposition is not possible, bail out per the §12 instruction.
9. **Every Domain in §12 matches a C4 container or component name in `.doyaken/architecture.md` verbatim.** A Domain that doesn't appear in the architecture map is either a typo or a sign the map is stale — fix the typo, or re-run `/dkarchitect` to refresh the map.
10. **`.doyaken/architecture.md` exists and was read in §2a.** If it was missing, the skill should already have stopped earlier and asked the user to run `/dkarchitect`.
11. **§10 (Design Patterns) is non-empty.** A genuinely mechanical refinement records `— none, all sub-tickets are mechanical` explicitly.

### 8. Present via `ExitPlanMode`

This is the user-facing output. Model it on what `/dkplan` presents — short, scannable, plan-style — **not** the fifteen-section material. The detailed material lives in working memory now and goes to the tracker in Step 9.

Include exactly these blocks, in this order:

1. **Refinement summary** — 2–4 sentences distilled from §1 (Problem Statement). What changes, technically; what success looks like.
2. **Architecture map status** — one line: `Read existing map: .doyaken/architecture.md (last-refreshed YYYY-MM-DD)`. If freshly built by `/dkarchitect` earlier in this run, say so and remind the user to commit it.
3. **Architectural direction** — 3–6 bullets summarising the chosen approach: which existing components extend, which (if any) are new and why, key contracts, sync/async stance, pluggability points. Cite paths.
4. **Design patterns chosen** — one line per pattern from §10: `<Pattern> at <location> — <why> [sub-tickets: …]`.
5. **Proposed sub-tickets** — numbered list rendered from §12. One line per sub-ticket: `<title> [domain: <C4 name>] [<size>] [<pattern>] — <scope> [depends-on: …] [paths: …]`.
6. **Estimation summary** — total count + size mix, critical path size, riskiest-to-estimate (1–2 sentences), and a **per-domain rollup** (sub-ticket count and size mix grouped by Domain — helps the user see workload distribution across owners).
7. **Files / areas touched** — high-level, derived from §2 (Codebase Component Map). Not file-by-file — the affected pillars and their entry points.
8. **Assumptions surfaced and answered** — one line per item from §5: `<assumption> — user said <X>` / `<assumption> — universally safe` / `<assumption> — deferred`.
9. **Residual open questions** — numbered, rendered from §14. Each with the owner who can answer.
10. **Risks** — bullet list rendered from §11. One line per risk: `<risk> (<L/M/H>×<L/M/H>) — mitigation: <…> — owner: <…>`.

Do **not** paste the Codebase Component Map, Edge Cases, full Verification Criteria, NFRs, or Decision Log into `ExitPlanMode`. Those land on the parent ticket as comments in Step 9 — pasting them into the plan-mode UI as well would bury the parts the user actually needs to approve.

Do **not** write any phase markers — this command does not participate in the Doyaken phase lifecycle.

**Do not begin tracker write-back until the user approves the plan.**

### 9. Write Back After Approval

Only if a ticket tracker is configured **and** the input was a ticket id. For freeform input or no-tracker setups, skip this step and print a brief summary instead.

1. **Create sub-tickets.** For each item in §12:
   - Linear: `save_issue` with `parent` relation to the original ticket. If the tracker supports labels, set a label matching the **Domain** (e.g. `domain:api-service`).
   - GitHub Issues: `gh issue create` with the parent referenced in the body (e.g. "Parent: #123") and a `--label "domain:<name>"` flag if the label exists in the repo (skip the flag silently if it doesn't — do not auto-create labels).
   - Body includes: **Domain**, scope line, **size**, **dominant pattern (with path)**, depends-on list, primary paths touched, and a back-link to the parent.
   - Capture the returned id / URL.
2. **Post five separate comments on the parent ticket** (separate so they can be linked individually):
   1. **Architecture + Component Map.** Link to `.doyaken/architecture.md` (note its `last-refreshed` date), then paste the Codebase Component Map (§2) + Impact Domains (§3).
   2. **Design Patterns** — §10 table.
   3. **Risk Register** — §11.
   4. **NFRs** — §9 (Performance / Observability / Configurability / Pluggability / Multi-tenancy).
   5. **Open Questions + Decision Log** — §14 + §15.
3. **Never edit the parent ticket's description.** The parent description is owned by whoever wrote the ticket; refinement output goes in comments and child tickets.
4. **If `/dkarchitect` was run earlier in this `dk refine` invocation** (i.e. the architecture map was built fresh), remind the user in the final summary to commit `.doyaken/architecture.md` themselves: `git add .doyaken/architecture.md && git commit -m "docs: bootstrap architecture map"`. The skill never commits.
5. Print a final summary: parent ticket link, every created sub-ticket link (with **Domain** + size + pattern), the five comment URLs, and the **per-domain rollup** from §8 step 6 so the user can dispatch sub-tickets to owners.

## Notes

- `dkrefine` does **not** call `TaskCreate` — task creation is `/dkplan`'s job during implementation.
- `dkrefine` does **not** branch, commit, push, or modify code. The one exception is writing `.doyaken/architecture.md` in §2b — that is a workspace file, not a code edit, and is **never** committed by the skill.
- `dkrefine` does **not** chain to implementation automatically. After approval and write-back, suggest the user run `dk <subticket>` on any created child ticket to begin implementation.
- If the user invokes `/dkrefine` from inside an autonomous `dk` lifecycle session by mistake, decline and tell them to start a separate `dk refine` session — mixing refinement into the lifecycle would skip the Stop-hook expectations of the active phase.
