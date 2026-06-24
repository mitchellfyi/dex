---
name: warn-await-in-loop
enabled: true
event: file
detector: await-in-loop
action: warn
---

WARNING: `await` inside a `for`/`while` loop — likely an N+1 query or sequential I/O.

Each iteration waits for the previous one, so N rows become N sequential round-trips. This is a leading cause of slow endpoints and, on the server side, database connection-pool exhaustion (every awaited call holds resources while the loop crawls).

Prefer one of:

- **Batch the work** — collect the inputs and issue one set-based call instead of one per row (e.g. `WHERE id IN (...)`, a JOIN, or a bulk insert/upsert).
- **Parallelize independent calls** — build an array of promises in the loop and `await Promise.all(...)` once, after it. Bound the fan-out with a concurrency limit when the list is large.

Keep the sequential `await` only when each iteration genuinely depends on the previous one, or when you are deliberately rate-limiting — and say so in a comment. Note: `for await (...)` async iteration and awaits inside a closure collected for a later `Promise.all` are not flagged.
