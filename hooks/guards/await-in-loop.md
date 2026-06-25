---
name: warn-await-in-loop
enabled: true
event: file
detector: await-in-loop
action: warn
---

WARNING: `await` inside a loop - possible sequential I/O.

Each iteration waits for the previous one. That may be required when the next step depends on the previous result, but it can also turn independent work into a slow chain of network, database, file, SDK, or browser calls.

Prefer one of:

- **Batch the work** - collect inputs and use a bulk or set-based operation when the API supports it.
- **Parallelize independent calls** - collect tasks in the loop and await them together after it, using a concurrency limit when the list is large.

Keep the sequential `await` when each iteration depends on the previous one, or when you are deliberately rate-limiting. Add a short comment for intentional sequencing. Async iteration forms and awaits inside nested closures or methods are not flagged.
