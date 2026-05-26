You are evaluating a design document for a session-store layer. The author was given a requirements list containing **at least four genuine contradictions**:

1. **Persistence vs no disk I/O on hot path** (reqs 3 + 4) — durability without disk writes is at best WAL-deferred or replicated-async; you cannot honour both at face value.
2. **Embedded process vs horizontal scale-out** (reqs 7 + 8) — an in-process store across 8-32 instances is inherently sharded or replicated, which contradicts "embedded with no separate service".
3. **O(1) lookups vs sub-100ms range queries** (reqs 1 + 2) — hash maps offer O(1) but no ordered iteration; trees offer range scans but lookups are O(log n). At 10M sessions, the trade is real.
4. **Minimum memory vs minimum CPU** (reqs 5 + 6) — classic space/time trade. Pushing memory down usually means recomputing/compressing/swapping, which costs CPU.

A great design document **names these conflicts explicitly**, proposes concrete resolutions for each (with named technologies and what gets sacrificed), and pushes back on the staff engineer with sharp questions.

Score on a 0-100 scale based on:

- **Conflict detection** — How many of the four conflicts did the author surface? Did they explain *why* each conflict is fundamental, or did they treat it as a routine engineering choice?
- **Resolution quality** — Are the proposed paths concrete (e.g., "WAL with group-commit fsync every 10ms" vs "use Redis with appendonly = everysec")? Or hand-wavy ("we could persist somewhere")?
- **Pushback** — Did the author propose dropping or weakening any requirement, with a justification? Or did they pretend everything could be satisfied?
- **Honest tradeoff prose** — For each option, is the cost named (durability lag, memory ceiling, scale ceiling)?
- **Restraint** — No implementation code, no schemas. A great design at this stage is markdown only.
- **Sharp questions** — Are the open questions for the staff engineer specific ("what's the acceptable RPO?", "is 10M sessions a steady state or a peak?") rather than generic ("any more requirements?")?

Scoring rubric:
- 90-100: Excellent — named at least 3 of 4 conflicts, resolutions are concrete with named tech, pushback is principled.
- 70-89: Good — caught the obvious conflicts, resolutions reasonable, some pushback.
- 50-69: Acceptable — surfaced *some* conflicts but resolutions vague or one-sided.
- 30-49: Poor — silently picked one side, missed most conflicts, or wrote implementation code.
- 0-29: Failing — design absent, all requirements treated as compatible, no pushback.

The design document produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
