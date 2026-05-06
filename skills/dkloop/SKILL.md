---
name: "dkloop"
description: "Run a prompt in a loop until the requested work is fully implemented and verified."
---

# Skill: dkloop

Run a prompt in a loop until fully implemented. In-session equivalent of the `dkloop` CLI command.

## When to Use

- When the user wants to ensure a task is 100% complete before stopping
- When the user invokes `/dkloop <prompt>`

## Arguments

The argument is the prompt/task to execute. Example: `/dkloop add input validation to all API endpoints`

## Steps

### 1. Activate the loop

Run this bash command to activate the stop hook loop and clean stale state:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
mkdir -p "$DK_LOOP_DIR"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
touch "$(dk_active_file "$SESSION_ID")"
rm -f "$(dk_loop_file "$SESSION_ID")" "$(dk_complete_file "$SESSION_ID")"
echo "Loop activated (session: ${SESSION_ID})"
```

This creates an `.active` signal file that the stop hook checks. The hook will prevent you from stopping until you write the `.complete` file.

### 2. Execute the prompt

Work on the user's prompt. Follow the same approach as any implementation task:
- Read relevant code before making changes
- Follow existing patterns and conventions
- Test your changes where possible

### 3. Self-audit before completing

Before signaling completion, critically review your work against the original prompt. The stop hook will guide you through a comprehensive audit when you try to stop, including:

1. **Acceptance criteria extraction** — list all requirements from the prompt (explicit and implied)
2. **/dkreview --single-pass** — run /dkreview --single-pass on your changes (code-change sessions only)
3. **Multi-perspective inventory** — 4-pass manual review (Logic & Correctness, Structure/Design/Documentation, Security, Holistic Consistency & Dependencies)
4. **Self-reviewer agent** — spawn the `self-reviewer` agent for an independent adversarial review (code-change sessions only)
5. **Merged inventory and batch fix** — combine all findings from /dkreview --single-pass, manual passes, and the agent; fix in severity order
6. **/dkverify quality pipeline** — format, lint, typecheck, test (code-change sessions only)
7. **Evidence table** — trace each requirement to specific `file:line` evidence in code and tests

If you find issues at any step, fix them and re-audit. Do NOT proceed to step 4 until the audit passes.

### 4. Signal completion

After the audit passes, stop. The Stop hook manages completion — it will provide
the completion signal file path and promise string after enough quality audit
passes. Do NOT write any `.complete` files or output promise strings on your own.

## Notes

- The stop hook will block you from stopping and inject an audit prompt. Follow the audit instructions — the hook provides completion instructions after sufficient clean iterations.
- If the loop reaches max iterations (default 30), it will allow stopping as a safety net.
- The `.active` file is cleaned up automatically when the loop completes or reaches max iterations.
