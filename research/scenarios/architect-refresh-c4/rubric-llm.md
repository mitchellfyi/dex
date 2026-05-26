You are evaluating a C4 architecture document for a small monorepo. The codebase has:
- `services/api/` — Express HTTP API with users and orders routes, talks to Postgres and enqueues to Redis
- `services/worker/` — background processor that consumes the Redis queue and sends email via SMTP
- `packages/shared/` — shared types + queue client (Redis wrapper) used by both services
- `docker-compose.yml` defining containers: api, worker, db (postgres), redis, mailhog (smtp)

The document should cover three C4 levels (Context, Container, Component) with valid mermaid diagrams, plus a data flow section and a "reusable plug-points" section.

Score on a 0-100 scale based on:

- **Accuracy** — Does the diagram match the actual code? Are the right containers present? Are inferred technologies (Express, Postgres, Redis, SMTP) correct? Are there phantom components that aren't in the seed?
- **Mermaid validity** — Are the diagrams using proper C4-PlantUML or mermaid-c4 syntax? Would they render? Do they use the right keywords (Person, System, Container, Component, Rel)?
- **Level appropriateness** — Is the System Context diagram actually at the context level (people + system + external systems), not crammed with internal containers? Is the Container view at container granularity, not component-level? Is the Component view zoomed in correctly?
- **Useful prose** — Does the data flow narrative match the actual code path (HTTP request → Postgres write → Redis enqueue → worker consumes → SMTP send)? Are the plug-points actually reusable touchpoints (e.g., the shared queue client, the topic naming)?
- **Restraint** — A great C4 doc names only what exists. Did the author resist inventing components ("AuthService") that aren't in the seed?

Scoring rubric:
- 90-100: Excellent — diagrams accurate and rendering, prose tight, plug-points real.
- 70-89: Good — minor inaccuracies or one weak diagram.
- 50-69: Acceptable — diagrams present but generic, prose vague.
- 30-49: Poor — diagrams invent components, levels confused, mermaid broken.
- 0-29: Failing — no architecture doc, or doc unrelated to the code.

The document produced:

{{CODE_LISTING}}

Respond with ONLY a JSON object: {"score": N, "reasoning": "brief explanation"}
