You are doing technical refinement for an epic-level feature. **Do not implement any code.** The deliverable is a single refinement document.

The product manager wrote this brief:

> Our users want notifications when things happen in the product. We need email, SMS, in-app, and maybe Slack. Some users want digests (daily or weekly), others want real-time. Admins should be able to send broadcast announcements. Some notifications are transactional (a password reset must arrive); others are promotional (opt-in only, and we have to honour unsubscribe). We'd like the system to be reusable across our other internal products too. We'd like to ship next quarter.

Your job: produce a refinement document at `REFINEMENT.md` covering:

1. **Goals and non-goals** — what's in scope for the first version, what's explicitly out
2. **Decomposed sub-tickets** — at least four independently shippable tickets, each with a one-line description and a size estimate (S / M / L). Each ticket should be a thing one engineer could pick up and finish without blocking on another.
3. **Dependencies** — which tickets depend on which, and why
4. **Risk register** — delivery, scope, integration, compliance, operational risks; at least one risk per category that applies
5. **Open questions** — assumptions you'd want a human to validate before kicking off implementation
6. **Architecture sketch** — name the components/services involved and how data flows between them (prose or ascii is fine, no implementation)
7. **Sequencing recommendation** — which ticket goes first, which last, and why

Use the `/dxrefine` skill if it helps. Write `REFINEMENT.md` at the workspace root. **Do not write any application code, schemas, migrations, or test files.** The only file you should create is the refinement document itself (plus any supporting markdown if it helps — but no source files).
