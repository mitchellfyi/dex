A staff engineer asked you to design a session-store layer for a high-traffic web app and handed you the following requirements list. Produce a design document at `DESIGN.md` proposing how to build it.

> **Session store requirements**
>
> 1. Lookups by session ID must be **O(1)** in the average case.
> 2. We need **range queries** ("all sessions created in the last 5 minutes", "all sessions for a given user") to return in **under 100ms** even at 10M sessions.
> 3. Sessions **must persist across restarts** (no data loss on process crash).
> 4. The store **must not perform disk I/O** on the hot path — every write must be acknowledged in under 1ms from memory.
> 5. Memory footprint must be **minimized** — we don't want to dedicate a large box to this.
> 6. CPU usage must be **minimized at all costs** — the box this runs on is shared with other services.
> 7. The store must be **embedded in the app process** (no separate service to operate).
> 8. The store must support **horizontal scale-out** to handle traffic spikes — we run 8-32 app instances behind a load balancer.

Write a design document. **Do not implement code.** The document at `DESIGN.md` should include:

1. A list of **conflicts** in the requirements — pairs (or larger groups) that cannot be simultaneously satisfied as stated, with a brief explanation of why each conflict is fundamental rather than just an engineering trade-off
2. For each conflict, **at least two resolution paths** — concrete ways to break the tie, with what each path costs and what it preserves
3. A **recommended design** that names which requirements you'd prioritise and which you'd push back on (and why)
4. **Questions for the staff engineer** — what you'd want clarified before committing to a design

If you find any single requirement that cannot be met by any plausible system, name it.

The output is `DESIGN.md` only. Do not write source code, configuration files, or schemas.
