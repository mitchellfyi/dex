#!/usr/bin/env bash
# SessionEnd hook — records session end time and cleans up ephemeral state files.
# Runs when an interactive provider session ends (cleanly or otherwise).
set -euo pipefail

# Standalone launchers clean only their own temporary files.
[[ "${DEX_TRIAGE_ACTIVE:-0}" == 1 || "${DEX_SESSION_ONLY:-0}" == 1 ]] && exit 0

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="session session-process"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

# A checkout-derived Dex session can be visible to more than one provider
# session. Only the session that claimed the active loop may mutate its
# state during SessionEnd. If the payload cannot prove ownership, leave the
# state for the real owner or wrapper to clean up.
OWNER_FILE=$(dx_owner_file "$SESSION_ID")
if [[ -s "$OWNER_FILE" ]]; then
  HOOK_INPUT=$(cat 2>/dev/null || true)
  HOOK_CLAUDE_SESSION_ID=""
  if [[ -n "$HOOK_INPUT" ]]; then
    HOOK_CLAUDE_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin).get("session_id", "")
except Exception:
    value = ""
if isinstance(value, str):
    print(value)
' 2>/dev/null || true)
  fi
  OWNER_ID=$(cat "$OWNER_FILE" 2>/dev/null || true)
  if [[ -n "$OWNER_ID" && "$HOOK_CLAUDE_SESSION_ID" != "$OWNER_ID" ]]; then
    exit 0
  fi
fi

# Record end time in the times file (complements phase start times written by dx.sh)
TIMES_FILE=$(dx_times_file "$SESSION_ID")
CTX_FILE=$(dx_context_file "$SESSION_ID")

if [[ -f "$TIMES_FILE" || -f "$CTX_FILE" || -f "$(dx_state_file "$SESSION_ID")" || -f "$(dx_active_file "$SESSION_ID")" || -f "$(dx_loop_config_file "$SESSION_ID")" || -f "$(dx_handoff_mode_file "$SESSION_ID")" ]]; then
  dx_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
fi

if [[ -f "$TIMES_FILE" ]]; then
  echo "end:$(date +%s)" >> "$TIMES_FILE"
fi

# Give the project its say before the reap, not after. A session holds things
# the worktree does not own — a port, a lease, a container, a dev server — and
# `## Worktree Hooks` is where a repository declares how to release them. The
# hook runs while this session's ownership token is still live, so whatever it
# starts is reaped below rather than outliving the session that asked for it.
# A failing or slow hook warns and is stepped over, like every other worktree
# hook. In a worktree DX_WORKTREE_NAME is the worktree's name; in an in-place
# session it is the repository directory's own name.
#
# Running it needs three modules the reap does not, and this hook deliberately
# loads only what it calls: it runs under a short host-side deadline, and a
# vendored runtime may carry a subset of lib/. So look for the section with one
# grep first — the same heading shape scripts/project-contract.py matches — and
# pay for the modules only when a repository has actually asked for this.
SESSION_END_REPO=$(dx_repo_root 2>/dev/null || true)
if [[ -n "$SESSION_END_REPO" ]] && grep -qiE \
  '^#{1,6}[[:space:]]+Worktree Hooks[[:space:]]*$' \
  "$SESSION_END_REPO/.dex/dex.md" 2>/dev/null; then
  for SESSION_END_MODULE in output.sh project-state.sh worktree.sh; do
    [[ -f "${DEX_DIR}/lib/${SESSION_END_MODULE}" ]] || continue
    __dx_require_lib "$SESSION_END_MODULE" || true
  done
  if command -v dx_worktree_hook_run >/dev/null 2>&1; then
    # settings.json gives this hook ten seconds of host budget, and what the
    # session actually depends on — the reap and the temp-root removal — is
    # below this line. A project's own 300 s default, or its `0` for "no
    # deadline", would have the host kill the hook script first and take the
    # reap with it, silently. Five seconds leaves the rest of the hook room;
    # a project that asked for less than five still gets what it asked for.
    # shellcheck disable=SC2034  # read by __dx_worktree_hook_timeout in lib/
    DX_WORKTREE_HOOK_CEILING=5
    dx_worktree_hook_run on_session_end "$SESSION_END_REPO" "$(pwd)" || true
    unset DX_WORKTREE_HOOK_CEILING
  fi
fi

# Stop every process this session started, however it was launched, then drop
# the session temp root. The reaper needs the token file to identify what it
# owns, so the token goes only after it has run and only if nothing survived.
# It skips this hook's own ancestry, so it cannot stop itself or the provider
# that is already exiting. A session that never took process ownership returns
# without a scan. Its output is left visible: this is the session-end path the
# design allows to act, and acting has to be logged. The same call emits this
# session's one telemetry summary, after the reap so the counts are final.
dx_session_finish_processes "$SESSION_ID" session-end || true

# Clean up the system context file — it's regenerated at each phase start
rm -f "$CTX_FILE" 2>/dev/null || true
