This workspace contains a small monorepo with an API service, a background worker, and a shared package. Your job is to produce a C4 architecture map at `.dex/architecture.md` covering levels 1-3 (System Context, Containers, Components).

The document must include:

1. **Level 1 — System Context**: a mermaid `C4Context` diagram naming the people who use the system and the external systems it talks to. Add a short prose section underneath describing what the system does.
2. **Level 2 — Container view**: a mermaid `C4Container` diagram showing the API service, the worker, the shared package, and any backing infrastructure (database, queue) you can infer from the code. Annotate each container with the technology it uses.
3. **Level 3 — Component view**: a mermaid `C4Component` diagram zooming in on the API container — at minimum, the routes, the database client, and the queue producer should appear. Underneath, a table listing each component, its file path, and its responsibility.

Also include:

- A short **Data flow** section describing how a request lands and how a background job gets enqueued and processed
- A **Reusable plug-points** section noting where another product could integrate (e.g., the shared package, the queue interface)

Use the `/dxarchitect` skill if it helps. Read the source code in `services/` and `packages/` before drawing anything — the diagrams must reflect what's actually there. Do **not** invent components that aren't in the code; do **not** omit ones that are. Mermaid syntax must be valid (you can sanity-check by ensuring each diagram has matching `\`\`\`mermaid` fences and proper C4 keywords).

The output is `.dex/architecture.md` only. Do not modify the existing source code in this workspace.
