#!/usr/bin/env bash
set -euo pipefail

# `dx <anything>` routes without asking: a tracker URL on this repository
# becomes its ticket, a project URL, another URL or a document runs the full
# workflow with a source-resolution intake, and a plain prompt still needs a
# mode. The lifecycle itself is stubbed at the provider refresh, the way
# dx-script-test.sh does it, so this checks the routing and the names only.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-dx-input-routing-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin "git@github.com:acme/widgets.git"
printf '# Payments spec\n' > "$REPO/docs/payments spec.md"

CALLS="$TMP_DIR/calls.out"
# run_dx <out> <dx args…>: dx from inside the fixture repo, stopped at the
# provider refresh (exit 91) so nothing is created. stdin is not a terminal.
run_dx() {
  local out="$1"; shift
  : > "$CALLS"
  set +e
  (
    cd "$REPO" && DEX_DIR="$ROOT" DX_TEST_CALLS="$CALLS" zsh -fc '
      source "$DEX_DIR/dx.sh"
      __dx_confirm_task_word() { print -r -- typo-guard >> "$DX_TEST_CALLS"; }
      __dx_refresh_provider() { print -r -- "provider:$DEX_SESSION_ONLY" >> "$DX_TEST_CALLS"; return 91; }
      __dx_choose_prompt_mode() { print -r -- menu >> "$DX_TEST_CALLS"; print session; }
      dx_provider_session() { print -r -- "session:$*" >> "$DX_TEST_CALLS"; }
      dx "$@"
    ' dx "$@" < /dev/null
  ) > "$out" 2>&1
  DX_RC=$?
  set -e
}
# name_for <input>: the workspace name dx would give it.
name_for() {
  (cd "$REPO" && DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_resolve_workspace_name "$1" && print -r -- "$_dx_wt_name"' name "$1")
}

# ── a GitHub issue URL on this repository is that ticket ───────────────────
run_dx "$TMP_DIR/gh-issue.out" "https://github.com/acme/widgets/issues/84"
[[ "$DX_RC" -eq 1 ]] || { cat "$TMP_DIR/gh-issue.out" >&2; assert_at $LINENO; }
assert_contains "That URL is ticket 84;" "$TMP_DIR/gh-issue.out"
assert_contains "provider:0" "$CALLS"
! grep -q menu "$CALLS" || assert_at $LINENO
[[ "$(name_for "https://github.com/acme/widgets/issues/84")" == "ticket-84" ]] || assert_at $LINENO

# ── a Linear issue URL is that ticket ──────────────────────────────────────
run_dx "$TMP_DIR/linear-issue.out" "https://linear.app/acme/issue/ENG-123/payments"
assert_contains "ticket ENG-123" "$TMP_DIR/linear-issue.out"
! grep -q "on this repository" "$TMP_DIR/linear-issue.out" || assert_at $LINENO
assert_contains "provider:0" "$CALLS"
[[ "$(name_for "https://linear.app/acme/issue/ENG-123/payments")" == "ticket-123" ]] || assert_at $LINENO

# ── a pull request URL resumes the session linked to it ────────────────────
run_dx "$TMP_DIR/pr.out" "https://github.com/acme/widgets/pull/85"
assert_contains "pull request #85" "$TMP_DIR/pr.out"
assert_contains "provider:0" "$CALLS"

# ── project URLs, pages and documents run the workflow, no menu ────────────
run_dx "$TMP_DIR/linear-project.out" "https://linear.app/acme/project/payments-revamp-7f3a2b1c0d9e/overview"
assert_contains "Source input (linear-project)" "$TMP_DIR/linear-project.out"
assert_contains "provider:0" "$CALLS"
! grep -q menu "$CALLS" || assert_at $LINENO
[[ "$(name_for "https://linear.app/acme/project/payments-revamp-7f3a2b1c0d9e/overview")" == "task-project-payments-revamp-7f3a2b1c0d9e" ]] || assert_at $LINENO

# A gh stub whose token lacks the project scope, then one that has it.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf "  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'%s\n" "${GH_STUB_EXTRA:-}"
SH
chmod 700 "$TMP_DIR/bin/gh"
export PATH="$TMP_DIR/bin:$PATH"
run_dx "$TMP_DIR/gh-project.out" "https://github.com/orgs/acme/projects/12/views/3"
assert_contains "Source input (github-project)" "$TMP_DIR/gh-project.out"
assert_contains "gh auth refresh -s read:project" "$TMP_DIR/gh-project.out"
GH_STUB_EXTRA=", 'read:project'" run_dx "$TMP_DIR/gh-project-ok.out" "https://github.com/orgs/acme/projects/12"
assert_contains "Source input (github-project)" "$TMP_DIR/gh-project-ok.out"
! grep -q "read:project scope" "$TMP_DIR/gh-project-ok.out" || assert_at $LINENO
[[ "$(name_for "https://github.com/orgs/acme/projects/12/views/3")" == "task-acme-projects-12" ]] || assert_at $LINENO

run_dx "$TMP_DIR/page.out" "https://docs.example.com/specs/payments?v=2"
assert_contains "Source input (url)" "$TMP_DIR/page.out"
assert_contains "provider:0" "$CALLS"

# A URL with instructions after it keeps the instructions.
run_dx "$TMP_DIR/url-words.out" "https://linear.app/acme/project/payments-7f3a" "and keep the old API working"
assert_contains "Source input (linear-project)" "$TMP_DIR/url-words.out"

# An issue on another repository is a source, not this repository's ticket.
run_dx "$TMP_DIR/other-issue.out" "https://github.com/other/repo/issues/7"
assert_contains "Source input (url)" "$TMP_DIR/other-issue.out"
! grep -q "ticket 7" "$TMP_DIR/other-issue.out" || assert_at $LINENO

# A document: relative path, spaces in the name, resolved to an absolute path.
run_dx "$TMP_DIR/doc.out" "docs/payments spec.md"
assert_contains "Document input" "$TMP_DIR/doc.out"
assert_contains "payments spec.md" "$TMP_DIR/doc.out"
assert_contains "provider:0" "$CALLS"
[[ "$(cd "$REPO" && DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; __dx_resolve_workspace_name "$1" && print -r -- "$_dx_wt_name"' name "docs/payments spec.md")" == "task-payments-spec" ]] || assert_at $LINENO
run_dx "$TMP_DIR/doc-words.out" "./docs/payments spec.md" "only the refunds part"
assert_contains "Document input" "$TMP_DIR/doc-words.out"

# ── a plain prompt, a missing file and a non-http link still need a mode ───
run_dx "$TMP_DIR/prompt.out" "fix the login bug"
assert_contains "Choose --session or --workflow" "$TMP_DIR/prompt.out"
! grep -q provider "$CALLS" || assert_at $LINENO
run_dx "$TMP_DIR/missing.out" "docs/missing.md"
assert_contains "Choose --session or --workflow" "$TMP_DIR/missing.out"
assert_contains "No file named 'docs/missing.md' here" "$TMP_DIR/missing.out"
run_dx "$TMP_DIR/ftp.out" "ftp://example.com/spec"
assert_contains "Choose --session or --workflow" "$TMP_DIR/ftp.out"
assert_contains "Only http(s) links are resolved" "$TMP_DIR/ftp.out"
# Ordinary words get no such hint.
! grep -q "No file named" "$TMP_DIR/prompt.out" || assert_at $LINENO

# ── explicit choices still win ─────────────────────────────────────────────
run_dx "$TMP_DIR/session-url.out" --session "https://github.com/acme/widgets/issues/84"
assert_contains "session:https://github.com/acme/widgets/issues/84" "$CALLS"
! grep -q "ticket 84" "$TMP_DIR/session-url.out" || assert_at $LINENO
run_dx "$TMP_DIR/ticket.out" 84
assert_contains "provider:0" "$CALLS"
! grep -q "Source input" "$TMP_DIR/ticket.out" || assert_at $LINENO
[[ "$(name_for "84")" == "ticket-84" ]] || assert_at $LINENO
[[ "$(name_for "fix the login bug")" == "task-fix-the-login-bug" ]] || assert_at $LINENO

# ── a provider that cannot launch stops before anything is created ─────────
: > "$CALLS"
set +e
(
  cd "$REPO" && DEX_DIR="$ROOT" DX_TEST_CALLS="$CALLS" zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_confirm_task_word() { :; }
    __dx_refresh_provider() { print -r -- provider >> "$DX_TEST_CALLS"; return 0; }
    dx_provider_agent_ready_check() { print -r -- ready-check >> "$DX_TEST_CALLS"; dx_error "stub: router disabled"; return 1; }
    __dx_setup_worktree() { print -r -- worktree >> "$DX_TEST_CALLS"; return 92; }
    dx "$@"
  ' dx 84 < /dev/null
) > "$TMP_DIR/not-ready.out" 2>&1
NOT_READY_RC=$?
set -e
[[ "$NOT_READY_RC" -eq 1 ]] || { cat "$TMP_DIR/not-ready.out" >&2; assert_at $LINENO; }
assert_contains "ready-check" "$CALLS"
! grep -q worktree "$CALLS" || assert_at $LINENO
assert_contains "nothing was created" "$TMP_DIR/not-ready.out"
assert_contains "stub: router disabled" "$TMP_DIR/not-ready.out"

# ── the usage text tells people they can hand dx a URL or a file ───────────
(cd "$REPO" && DEX_DIR="$ROOT" zsh -fc 'source "$DEX_DIR/dx.sh"; dx' > "$TMP_DIR/usage.out" 2>&1) || true
assert_contains "dx <URL>" "$TMP_DIR/usage.out"
assert_contains "dx <FILE>" "$TMP_DIR/usage.out"

printf 'dx input routing tests passed\n'
