#!/usr/bin/env bash
# A human pause or cancel receipt that outlived its provider must not detach
# the next `dx <ticket>` relaunch. The relaunch is the newer human instruction.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-relaunch-control.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export TMP_DIR
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT" \
  "$DX_ARTIFACT_DIR" "$DX_TOOL_DIR" "$TMP_DIR/bin"

# The launcher only checks that a claude binary resolves; the provider call
# itself is stubbed inside each scenario.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/bin/claude"
chmod +x "$TMP_DIR/bin/claude"
export PATH="$TMP_DIR/bin:$PATH"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

TEST_REPO="$TMP_DIR/repo"
git init -q -b main "$TEST_REPO"
git -C "$TEST_REPO" config user.email dex@example.test
git -C "$TEST_REPO" config user.name "Dex Test"
git -C "$TEST_REPO" commit --allow-empty -qm init

# Record what the launcher left behind at the moment the provider started,
# and which engine it resolved. The agent is pinned per scenario so the repo's
# own provider profile cannot pick the path under test.
run_relaunch() { # <session-id> <marker-file> <output-file> <agent>
  local session_id="$1" marker_file="$2" output_file="$3" agent="$4" status=0
  set +e
  TEST_REPO="$TEST_REPO" TEST_SESSION_ID="$session_id" TEST_MARKER="$marker_file" \
    DX_AGENT_OVERRIDE="$agent" \
    zsh -fc '
      source "$DEX_DIR/dx.sh"
      __dx_refresh_provider

      unalias __dx_claude 2>/dev/null
      unfunction __dx_claude 2>/dev/null
      __dx_claude() {
        local marker_line="launched" engine_line=""
        printf "%s\n" "$@" > "${TEST_MARKER}.args"
        [[ -e "$(dx_lifecycle_control_file "$TEST_SESSION_ID")" ]] && marker_line+=" control"
        [[ -e "$(dx_paused_file "$TEST_SESSION_ID")" ]] && marker_line+=" paused"
        [[ -e "$(dx_pause_state_file "$TEST_SESSION_ID")" ]] && marker_line+=" pause-state"
        [[ -e "$(dx_active_file "$TEST_SESSION_ID")" ]] && marker_line+=" active"
        engine_line=$(grep "^engine=" "$(dx_provider_state_file "$TEST_SESSION_ID")" 2>/dev/null)
        printf "%s %s\n" "$marker_line" "${engine_line:-engine=unknown}" > "$TEST_MARKER"
        return 97
      }

      state_file=$(dx_state_file "$TEST_SESSION_ID")
      times_file=$(dx_times_file "$TEST_SESSION_ID")
      __dx_run_phases_inline \
        "relaunch-control" "$TEST_REPO" main 2 "$state_file" "$times_file" \
        "dx relaunch-test" worktree "$TEST_SESSION_ID" "relaunch test"
    ' > "$output_file" 2>&1
  status=$?
  set -e
  return "$status"
}

# Phase 2 lifecycle that a human cancelled from a prompt; the provider then
# died without the wrapper's cleanup, leaving both the receipt and the pause.
seed_phase_two() { # <session-id>
  local session_id="$1"
  dx_lifecycle_atomic_write "$(dx_state_file "$session_id")" 2
  printf '2:%s\n' "$(date +%s)" > "$(dx_times_file "$session_id")"
  dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$session_id")" inline
  dx_lifecycle_atomic_write "$(dx_loop_config_file "$session_id")" \
    "2:PHASE_2_COMPLETE:${ROOT}/prompts/phase-audits/2-implement.md:1"
  touch "$(dx_active_file "$session_id")"
}

STALE_SID="relaunch-stale-cancel"
seed_phase_two "$STALE_SID"
dx_write_lifecycle_control "$STALE_SID" cancel "" user-prompt "" 2 ""
dx_lifecycle_detach "$STALE_SID" manual-cancel user-prompt
assert_file "$(dx_lifecycle_control_file "$STALE_SID")"
assert_file "$(dx_paused_file "$STALE_SID")"
STALE_MARKER="$TMP_DIR/stale.marker"
run_relaunch "$STALE_SID" "$STALE_MARKER" "$TMP_DIR/stale.out" claude || true
assert_file "$STALE_MARKER"
assert_eq "launched active engine=claude" "$(<"$STALE_MARKER")" \
  "stale cancel receipt and pause consumed before the provider started"
assert_contains "--resume" "${STALE_MARKER}.args"
assert_contains "relaunch-control" "${STALE_MARKER}.args"
# The stub provider exits non-zero, so the wrapper pauses afterwards. That
# pause must come from the provider exit, not from the consumed receipt.
assert_not_contains "cancelled by direct human instruction" "$TMP_DIR/stale.out"
assert_contains "Paused at Phase 2: Implement (exit 97)" "$TMP_DIR/stale.out"
if ! grep -rq "consumed the direct human instruction cancel receipt" "$DX_RUN_ROOT"; then
  fail "run journal did not record the consumed cancel receipt"
fi

# A pending phase transition is the Stop hook's to apply; the relaunch keeps it.
JUMP_SID="relaunch-pending-jump"
seed_phase_two "$JUMP_SID"
CLAUDE_SESSION_HANDLE="01999999-1111-4222-8333-444444444444"
dx_agent_session_handle_write "$JUMP_SID" claude "$CLAUDE_SESSION_HANDLE"
dx_write_lifecycle_control "$JUMP_SID" jump 4 terminal "" 2 ""
JUMP_MARKER="$TMP_DIR/jump.marker"
run_relaunch "$JUMP_SID" "$JUMP_MARKER" "$TMP_DIR/jump.out" claude || true
assert_file "$JUMP_MARKER"
assert_eq "launched control active engine=claude" "$(<"$JUMP_MARKER")" \
  "pending jump receipt preserved for the Stop hook"
assert_contains "$CLAUDE_SESSION_HANDLE" "${JUMP_MARKER}.args"
if grep -Fxq -- "relaunch-control" "${JUMP_MARKER}.args"; then
  fail "exact Claude resume also passed the legacy session name"
fi

# An unreadable receipt is refused before any provider starts.
BROKEN_SID="relaunch-broken-receipt"
seed_phase_two "$BROKEN_SID"
mkdir "$(dx_lifecycle_control_file "$BROKEN_SID")"
BROKEN_MARKER="$TMP_DIR/broken.marker"
BROKEN_RESULT=0
run_relaunch "$BROKEN_SID" "$BROKEN_MARKER" "$TMP_DIR/broken.out" claude || BROKEN_RESULT=$?
assert_eq "1" "$BROKEN_RESULT" "unreadable receipt relaunch result"
assert_no_file "$BROKEN_MARKER"
assert_contains "unreadable or invalid lifecycle control receipt" "$TMP_DIR/broken.out"
assert_dir "$(dx_lifecycle_control_file "$BROKEN_SID")"

# The interactive Codex launcher checks controls before launch on its own path.
# A stale cancel and its pause are consumed there too, then its Stop hook is
# activated before the session starts.
CODEX_SID="relaunch-codex-stale-cancel"
seed_phase_two "$CODEX_SID"
printf 'engine=codex-plugin\nsession=%s\n' "$CODEX_SID" > "$(dx_provider_state_file "$CODEX_SID")"
dx_write_lifecycle_control "$CODEX_SID" cancel "" terminal "" 2 ""
dx_lifecycle_detach "$CODEX_SID" manual-cancel terminal
CODEX_MARKER="$TMP_DIR/codex.marker"
run_relaunch "$CODEX_SID" "$CODEX_MARKER" "$TMP_DIR/codex.out" codex || true
assert_file "$CODEX_MARKER"
assert_eq "launched active engine=codex-plugin" "$(<"$CODEX_MARKER")" \
  "interactive Codex relaunch consumed the stale cancel receipt and pause"
assert_contains "--continue" "${CODEX_MARKER}.args"
assert_not_contains "cancelled by direct human instruction" "$TMP_DIR/codex.out"

# Once SessionStart has captured Codex's thread ID, relaunch uses that exact
# conversation instead of whichever session happens to be newest in the cwd.
CODEX_EXACT_SID="relaunch-codex-exact-session"
CODEX_SESSION_HANDLE="01999999-aaaa-4bbb-8ccc-dddddddddddd"
seed_phase_two "$CODEX_EXACT_SID"
dx_agent_session_handle_write "$CODEX_EXACT_SID" codex "$CODEX_SESSION_HANDLE"
CODEX_EXACT_MARKER="$TMP_DIR/codex-exact.marker"
run_relaunch "$CODEX_EXACT_SID" "$CODEX_EXACT_MARKER" \
  "$TMP_DIR/codex-exact.out" codex || true
assert_file "$CODEX_EXACT_MARKER"
assert_contains "$CODEX_SESSION_HANDLE" "${CODEX_EXACT_MARKER}.args"
assert_not_contains "--continue" "${CODEX_EXACT_MARKER}.args"

echo "lifecycle relaunch control tests passed"
