---
name: "dxloop"
description: "Run a prompt in a loop until the requested work is fully implemented and verified."
---

# Skill: dxloop

Use the terminal `dxloop` command for an audited plan-and-implementation loop.
The command launches a dedicated Claude session and binds every completion
receipt to that launch's session, purpose, phase, and generation.

## Handoff

Do not activate loop files from the current Claude session. A skill command
does not receive the Claude hook session ID, so a file-only activation cannot
prove that the current session owns it. Another Claude session in the same
checkout could otherwise claim the loop before this session's first Stop hook.

Give the user a runnable terminal command containing their original task:

```bash
dxloop '<prompt>'
```

Quote the prompt safely for their shell. State plainly that this skill has not
started a loop; the terminal command starts it. Then stop normally.

The dedicated wrapper owns activation, saves the original prompt for
compaction recovery, launches planning, rotates to a fresh implementation
generation, and cleans up on completion, timeout, interruption, or direct
human pause. Do not reproduce those state transitions in this skill.

## While inside a wrapper-launched loop

If the surrounding prompt says this is already a `dxloop` planning or
implementation session, follow that prompt instead of handing off again:

- Plan the requested work and present it for approval during planning.
- Implement the approved plan, using tests and project verification gates.
- Follow the Stop hook's audit instructions.
- Run only the literal generation-bound completion command supplied for this
  launch, and only after every gate passes.
- If repeated failures exhaust two materially different strategies, use the
  exact escalation command supplied by the hook. Escalation pauses the loop;
  it does not complete it or relax the approved criteria.

Never discover a current completion generation at signal time. Never write a
bare `.complete`, readiness, pause, or human-control marker yourself.
