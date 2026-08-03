---
name: "dxloop"
description: "Run a prompt in a loop until the requested work is fully implemented and verified."
---

# Skill: dxloop

Run a prompt in a loop until fully implemented. In-session equivalent of the `dxloop` CLI command.

## When to Use

- When the user wants to ensure a task is 100% complete before stopping
- When the user invokes `/dxloop <prompt>`

## Arguments

The argument is the prompt/task to execute. Example: `/dxloop add input validation to all API endpoints`

## Steps

### 1. Activate the loop

Run this bash command to activate the stop hook loop and clean stale state:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
mkdir -p "$DX_LOOP_DIR"
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
touch "$(dx_active_file "$SESSION_ID")"
rm -f "$(dx_loop_file "$SESSION_ID")" "$(dx_complete_file "$SESSION_ID")"
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
2. **/dxreview --single-pass** — run one review wave on your changes (code-change sessions only): compact context pack, deterministic checks, issue harvest, verifier triage, batch fixes, and targeted recheck
3. **Multi-perspective inventory** — 4-pass manual review (Logic & Correctness, Structure/Design/Documentation, Security, Holistic Consistency & Dependencies)
4. **Merged inventory and batch fix** — combine any remaining findings from /dxreview --single-pass and manual passes; fix in severity order
5. **/dxverify quality pipeline** — format, lint, typecheck, test (code-change sessions only)
6. **Evidence table** — trace each requirement to specific `file:line` evidence in code and tests

If you find issues at any step, fix them and re-audit. Do NOT proceed to step 4 until the audit passes.

### 4. Signal completion

After the audit passes, stop. The Stop hook manages completion — it will provide
the completion signal file path and promise string after enough quality audit
passes. Do NOT write any `.complete` files or output promise strings on your own.

## Notes

- The stop hook will block you from stopping and inject an audit prompt. Follow the audit instructions — the hook provides completion instructions after sufficient clean iterations.
- If the loop reaches max iterations (default 30), it will allow stopping as a safety net.
- The `.active` file is cleaned up automatically when the loop completes or reaches max iterations.
