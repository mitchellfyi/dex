---
name: warn-detached-processes
enabled: true
event: bash
detector: detached-process
action: warn
---

This is either a command this project declared heavy, or work that outlives
the command. Read whichever half applies.

**A declared heavy command:**
run it through `dx run-gate` so it queues and is owned — unless it is a
long-lived server: start those directly and own them, since a lease held for a
server's whole life is never returned. The repository listed the command under
`heavy_commands` in `## Resources` in `.dex/dex.md`, which means the host
admits only so many at once. Outside the lease it does not wait its turn, so
it competes with every other session instead of queueing behind them.
`dx run-gate` also streams to a session-owned log you can poll from a short
tool call, and records the exit code.

**Work that outlives the command** — a `nohup`/`setsid`/`disown` launch, a
background `&`, or the tool's own background mode, which this guard cannot see
in the payload but which detaches work the same way. Dex still owns it: the
process carries this session's token, and the session's end — a normal exit, a
watchdog kill, `dx control stop`, or the runtime supervisor noticing its
launcher is gone — stops it. That is usually what you want, and two things
follow:

- **Do not rely on it running later.** A server, watcher, or long gate started
  this way is gone when the phase ends. If a later step needs it, start it
  there, or keep it in the foreground of the step that needs it.
- **If it genuinely must survive the session, say so and record why.** Detached
  work nobody wrote down is what leaves a host with a dozen orphaned servers
  holding ports and memory. `dx ps` lists what every session owns and what is
  already orphaned; `dx ps --reap-orphans` stops the orphans.

Put scratch files under `$DX_SESSION_TMP` so they go with the session too.

Caught: `nohup`, `setsid` and `disown` in command position, including inside a
heredoc, a `bash -c` payload, or a command substitution; a background `&` the
same command never `wait`s for; and a top-level command segment whose first
words are one of the project's declared `heavy_commands`, unless it is already
inside `dx run-gate`. Not caught, because the `&` is not a separator there:
`2>&1`, `>&2`, `&>file`, `&&`, and an `&` inside quotes.
