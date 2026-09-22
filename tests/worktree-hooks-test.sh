#!/usr/bin/env bash
set -euo pipefail

# Worktree lifecycle hooks: a repository declares what a worktree of it costs
# beyond disk, and Dex runs those commands when it creates one and on every
# path that removes one.
#
# The hooks here append a line per invocation to $MARKER_FILE, so an assertion
# can say both "it ran" and "it ran with the name, ticket, repo root and
# working directory the contract promises". The interesting cases are the ones
# where the project's command misbehaves: a hook that fails and a hook that
# never returns must not be able to leave a worktree half-removed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
# Physical path: the hooks report $PWD, and git reports resolved toplevels, so
# a TMPDIR with a trailing slash or a symlinked /var would make every path
# assertion here compare two spellings of the same directory.
TMP_DIR="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dex-worktree-hooks.XXXXXX")" && pwd -P)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export GIT_AUTHOR_NAME=dex GIT_AUTHOR_EMAIL=dex@example.test
export GIT_COMMITTER_NAME=dex GIT_COMMITTER_EMAIL=dex@example.test
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

# The hooks write here. Exported so they are reachable from the command the
# contract declares, whatever directory Dex runs it in.
export MARKER_FILE="$TMP_DIR/markers.log"
: > "$MARKER_FILE"

CREATE_HOOK='printf "%s\n" "create name=$DX_WORKTREE_NAME ticket=$DX_TICKET repo=$DX_REPO_ROOT path=$DX_WORKTREE_PATH cwd=$PWD" >> "$MARKER_FILE"'
REMOVE_HOOK='printf "%s\n" "remove name=$DX_WORKTREE_NAME ticket=$DX_TICKET repo=$DX_REPO_ROOT cwd=$PWD" >> "$MARKER_FILE"'

# make_repo <dir> [hook line...] — a fake project with a `## Worktree Hooks`
# section. With no hook lines the section is absent entirely, which is the
# case every existing repository is in.
make_repo() {
  local repo="$1"
  shift
  mkdir -p "$repo/.dex/worktrees"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email dex@example.test
  git -C "$repo" config user.name "Dex Test"
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "test: initialize repo"
  {
    printf '# Dex — fixture\n\n## Quality Gates\n\nNone.\n\n'
    if [[ $# -gt 0 ]]; then
      printf '## Worktree Hooks\n\n```yaml\n'
      printf '%s\n' "$@"
      printf '```\n'
    fi
  } > "$repo/.dex/dex.md"
}

marker_count() {
  grep -cF -- "$1" "$MARKER_FILE" 2>/dev/null || true
}

# ─── 1. The contract reader ─────────────────────────────────────────────────

CONTRACT_REPO="$TMP_DIR/contract"
make_repo "$CONTRACT_REPO" \
  "after_create: $CREATE_HOOK" \
  "before_remove: $REMOVE_HOOK" \
  'orphan_resources: printf "%s\n" leftover-one leftover-two'

assert_eq "$CREATE_HOOK" \
  "$(dx_project_worktree_hook "$CONTRACT_REPO" after_create)" \
  "after_create reads back"
assert_eq "$REMOVE_HOOK" \
  "$(dx_project_worktree_hook "$CONTRACT_REPO" before_remove)" \
  "before_remove reads back"

# An undeclared key is "this project declared nothing" (1); a key that is not
# a hook at all is a Dex bug (2).
HOOK_STATUS=0
dx_project_worktree_hook "$CONTRACT_REPO" on_session_end >/dev/null 2>&1 || HOOK_STATUS=$?
assert_eq 1 "$HOOK_STATUS" "an undeclared hook is absent, not an error"
HOOK_STATUS=0
dx_project_worktree_hook "$CONTRACT_REPO" after_creat >/dev/null 2>&1 || HOOK_STATUS=$?
assert_eq 2 "$HOOK_STATUS" "a misspelled hook name is rejected"

# A project with no section at all: every entry point stays a no-op.
BARE_REPO="$TMP_DIR/bare"
make_repo "$BARE_REPO"
HOOK_STATUS=0
dx_project_worktree_hook "$BARE_REPO" before_remove >/dev/null 2>&1 || HOOK_STATUS=$?
assert_eq 1 "$HOOK_STATUS" "no section means no hook"
dx_worktree_hook_run before_remove "$BARE_REPO" "$BARE_REPO/.dex/worktrees/none" \
  > "$TMP_DIR/bare.out" 2>&1 || assert_at $LINENO
assert_eq "" "$(cat "$TMP_DIR/bare.out")" "a project with no hooks says nothing"

# ─── 2. dx_wt_remove runs before_remove, wherever it is called from ─────────

HOOK_REPO="$TMP_DIR/hooked"
make_repo "$HOOK_REPO" "after_create: $CREATE_HOOK" "before_remove: $REMOVE_HOOK"

git -C "$HOOK_REPO" worktree add -q --no-track \
  "$HOOK_REPO/.dex/worktrees/task-direct" -b worktree-task-direct main
: > "$MARKER_FILE"
(cd "$HOOK_REPO" && dx_wt_remove "$HOOK_REPO/.dex/worktrees/task-direct" "$HOOK_REPO") \
  > "$TMP_DIR/direct.out" 2>&1
[[ ! -d "$HOOK_REPO/.dex/worktrees/task-direct" ]] || assert_at $LINENO
assert_contains "remove name=task-direct" "$MARKER_FILE"
# The worktree is the working directory, and the repo root is the main
# checkout even though the command ran inside a linked worktree.
assert_contains "repo=$HOOK_REPO" "$MARKER_FILE"
assert_contains "cwd=$HOOK_REPO/.dex/worktrees/task-direct" "$MARKER_FILE"

# Derived rather than passed: a caller that knows only the path still gets the
# hook, because the path already names the checkout.
git -C "$HOOK_REPO" worktree add -q --no-track \
  "$HOOK_REPO/.dex/worktrees/ticket-77" -b worktree-ticket-77 main
: > "$MARKER_FILE"
(cd "$HOOK_REPO" && dx_wt_remove "$HOOK_REPO/.dex/worktrees/ticket-77") >/dev/null 2>&1
[[ ! -d "$HOOK_REPO/.dex/worktrees/ticket-77" ]] || assert_at $LINENO
# A ticket worktree carries its ticket ID into the hook's environment.
assert_contains "remove name=ticket-77 ticket=77" "$MARKER_FILE"

# A refused path never reaches the hook.
: > "$MARKER_FILE"
REMOVE_STATUS=0
dx_wt_remove "$HOOK_REPO" >/dev/null 2>&1 || REMOVE_STATUS=$?
assert_eq 1 "$REMOVE_STATUS" "a path outside .dex/worktrees/ is refused"
assert_eq 0 "$(marker_count remove)" "a refused removal runs no hook"
[[ -d "$HOOK_REPO" ]] || assert_at $LINENO

# ─── 3. A failing hook warns; the worktree still goes ───────────────────────

FAIL_REPO="$TMP_DIR/failing"
make_repo "$FAIL_REPO" \
  'before_remove: printf "%s\n" "tried $DX_WORKTREE_NAME" >> "$MARKER_FILE"; exit 3'
git -C "$FAIL_REPO" worktree add -q --no-track \
  "$FAIL_REPO/.dex/worktrees/task-doomed" -b worktree-task-doomed main
: > "$MARKER_FILE"
(cd "$FAIL_REPO" && dx_wt_remove "$FAIL_REPO/.dex/worktrees/task-doomed" "$FAIL_REPO") \
  > "$TMP_DIR/failing.out" 2>&1
[[ ! -d "$FAIL_REPO/.dex/worktrees/task-doomed" ]] || assert_at $LINENO
assert_contains "tried task-doomed" "$MARKER_FILE"
assert_contains "failed (exit 3)" "$TMP_DIR/failing.out"
assert_contains "Continuing." "$TMP_DIR/failing.out"

# A block Dex cannot read is reported once and ignored whole, rather than
# half-applied.
BROKEN_REPO="$TMP_DIR/broken"
make_repo "$BROKEN_REPO" 'before_remove:' '  nested:' '    deeper: yes'
git -C "$BROKEN_REPO" worktree add -q --no-track \
  "$BROKEN_REPO/.dex/worktrees/task-broken" -b worktree-task-broken main
(cd "$BROKEN_REPO" && dx_wt_remove "$BROKEN_REPO/.dex/worktrees/task-broken" "$BROKEN_REPO") \
  > "$TMP_DIR/broken.out" 2>&1
[[ ! -d "$BROKEN_REPO/.dex/worktrees/task-broken" ]] || assert_at $LINENO
assert_contains "is not a flat mapping of shell commands" "$TMP_DIR/broken.out"

# A list where a command belongs is refused rather than run as a sequence.
LIST_REPO="$TMP_DIR/listed"
make_repo "$LIST_REPO" 'before_remove:' '  - first' '  - second'
git -C "$LIST_REPO" worktree add -q --no-track \
  "$LIST_REPO/.dex/worktrees/task-listed" -b worktree-task-listed main
(cd "$LIST_REPO" && dx_wt_remove "$LIST_REPO/.dex/worktrees/task-listed" "$LIST_REPO") \
  > "$TMP_DIR/listed.out" 2>&1
[[ ! -d "$LIST_REPO/.dex/worktrees/task-listed" ]] || assert_at $LINENO
assert_contains "each hook is one shell command, not a list" "$TMP_DIR/listed.out"

# ─── 4. A hook that does not return is stopped ──────────────────────────────

SLOW_REPO="$TMP_DIR/slow"
make_repo "$SLOW_REPO" \
  'before_remove: /bin/sleep 5; printf "%s\n" "slow finished" >> "$MARKER_FILE"'
git -C "$SLOW_REPO" worktree add -q --no-track \
  "$SLOW_REPO/.dex/worktrees/task-slow" -b worktree-task-slow main
: > "$MARKER_FILE"
SLOW_START=$(date +%s)
(cd "$SLOW_REPO" \
  && DEX_WORKTREE_HOOK_TIMEOUT=1 dx_wt_remove "$SLOW_REPO/.dex/worktrees/task-slow" "$SLOW_REPO") \
  > "$TMP_DIR/slow.out" 2>&1
SLOW_ELAPSED=$(( $(date +%s) - SLOW_START ))
[[ ! -d "$SLOW_REPO/.dex/worktrees/task-slow" ]] || assert_at $LINENO
assert_contains "passed 1s and was stopped" "$TMP_DIR/slow.out"
assert_eq 0 "$(marker_count "slow finished")" "the stopped hook never reached its second command"
# Not a wall-clock assertion about the deadline itself, only that the removal
# did not sit through the whole sleep. Generous for a loaded host.
[[ "$SLOW_ELAPSED" -lt 5 ]] || assert_at $LINENO

# A call site running on someone else's clock can lower the deadline, never
# raise it — and "0 means forever" is a raise.
assert_eq 300 "$(__dx_worktree_hook_timeout)" "the default stands on its own"
assert_eq 5 "$(DX_WORKTREE_HOOK_CEILING=5 __dx_worktree_hook_timeout)" \
  "a ceiling lowers the default"
assert_eq 5 "$(DEX_WORKTREE_HOOK_TIMEOUT=900 DX_WORKTREE_HOOK_CEILING=5 __dx_worktree_hook_timeout)" \
  "a ceiling overrides a larger project value"
assert_eq 5 "$(DEX_WORKTREE_HOOK_TIMEOUT=0 DX_WORKTREE_HOOK_CEILING=5 __dx_worktree_hook_timeout)" \
  "a ceiling overrides 'no deadline'"
assert_eq 2 "$(DEX_WORKTREE_HOOK_TIMEOUT=2 DX_WORKTREE_HOOK_CEILING=5 __dx_worktree_hook_timeout)" \
  "a project asking for less than the ceiling still gets less"
assert_eq 0 "$(DEX_WORKTREE_HOOK_TIMEOUT=0 __dx_worktree_hook_timeout)" \
  "without a ceiling, 0 still means no deadline"

# ─── 5. The dx.sh create path and the dx.sh removal commands ────────────────

if command -v zsh >/dev/null 2>&1; then
  ZSH_REPO="$TMP_DIR/zsh-repo"
  make_repo "$ZSH_REPO" "after_create: $CREATE_HOOK" "before_remove: $REMOVE_HOOK"
  export ZSH_REPO
  : > "$MARKER_FILE"

  # dxrm <name>, dxrm --all and dxclean each reach the same removal, and the
  # create path stands the worktree up first.
  (cd "$ZSH_REPO" && zsh -fc '
    source "$DEX_DIR/dx.sh"
    set -e
    cd "$ZSH_REPO"

    __dx_setup_worktree 501
    [[ -d "$ZSH_REPO/.dex/worktrees/ticket-501" ]] || assert_at $LINENO

    dxrm 501
    dx_link_claude_to_worktree() { : }

    git worktree add -q --no-track "$ZSH_REPO/.dex/worktrees/task-all" -b worktree-task-all main
    dxrm --all

    git worktree add -q --detach "$ZSH_REPO/.dex/worktrees/task-stale" main
    dxclean
  ') > "$TMP_DIR/zsh.out" 2>&1 || {
    cat "$TMP_DIR/zsh.out" >&2
    fail "the zsh worktree commands did not complete"
  }

  assert_contains "create name=ticket-501 ticket=501" "$MARKER_FILE"
  assert_contains "path=$ZSH_REPO/.dex/worktrees/ticket-501" "$MARKER_FILE"
  assert_contains "cwd=$ZSH_REPO/.dex/worktrees/ticket-501" "$MARKER_FILE"
  assert_contains "remove name=ticket-501" "$MARKER_FILE"
  assert_contains "remove name=task-all" "$MARKER_FILE"
  assert_contains "remove name=task-stale" "$MARKER_FILE"
  [[ ! -d "$ZSH_REPO/.dex/worktrees/ticket-501" ]] || assert_at $LINENO
  [[ ! -d "$ZSH_REPO/.dex/worktrees/task-all" ]] || assert_at $LINENO
  [[ ! -d "$ZSH_REPO/.dex/worktrees/task-stale" ]] || assert_at $LINENO
  # Creation runs the create hook once, not once per link pass.
  assert_eq 1 "$(marker_count "create name=ticket-501")" "after_create runs once"
else
  printf 'skip: zsh is not installed, so the dx.sh create and removal paths are not exercised\n'
fi

# ─── 6. dx worktree audit ───────────────────────────────────────────────────

AUDIT_REPO="$TMP_DIR/audit"
# The probe names one true orphan and one worktree that is checked out right
# now. A probe enumerating "every database I can see" produces exactly that,
# and Dex — not the probe — is the one that has to know which is which.
make_repo "$AUDIT_REPO" \
  "before_remove: $REMOVE_HOOK" \
  'orphan_resources: printf "%s\n" task-retired task-live TASK-LIVE "$DX_REPO_ROOT/.dex/worktrees/task-live/"'
git -C "$AUDIT_REPO" worktree add -q --no-track \
  "$AUDIT_REPO/.dex/worktrees/task-live" -b worktree-task-live main
# A directory git does not know about, and a registration whose directory is
# gone: the two ways the catalogues come apart.
mkdir -p "$AUDIT_REPO/.dex/worktrees/task-ghost"
git -C "$AUDIT_REPO" worktree add -q --no-track \
  "$AUDIT_REPO/.dex/worktrees/task-vanished" -b worktree-task-vanished main
rm -rf "$AUDIT_REPO/.dex/worktrees/task-vanished"

: > "$MARKER_FILE"
(cd "$AUDIT_REPO" && bash "$ROOT/bin/worktree.sh" audit) > "$TMP_DIR/audit.out" 2>&1
assert_contains "Worktrees git has registered:" "$TMP_DIR/audit.out"
assert_contains "main checkout" "$TMP_DIR/audit.out"
assert_contains "Directories under .dex/worktrees/:" "$TMP_DIR/audit.out"
assert_contains "task-live" "$TMP_DIR/audit.out"
assert_contains "git does not know it" "$TMP_DIR/audit.out"
assert_contains "directory is gone" "$TMP_DIR/audit.out"
assert_contains "task-retired" "$TMP_DIR/audit.out"
assert_contains "Nothing was removed." "$TMP_DIR/audit.out"
# The dry run has to show the comparison, not just the probe's opinion.
assert_contains "task-live" "$TMP_DIR/audit.out"
assert_contains "reported, but Dex still has this worktree" "$TMP_DIR/audit.out"
assert_contains "belong to a worktree Dex or git still lists" "$TMP_DIR/audit.out"
# A probe spells a worktree however it likes. All three of these name the same
# live checkout as `task-live`, and none of them is an orphan.
assert_contains "TASK-LIVE" "$TMP_DIR/audit.out"
assert_contains "$AUDIT_REPO/.dex/worktrees/task-live/" "$TMP_DIR/audit.out"
assert_eq 3 "$(grep -cF 'reported, but Dex still has this worktree' "$TMP_DIR/audit.out")" \
  "every spelling of the live worktree is held back"
assert_contains "3 reported name(s) belong to a worktree Dex or git still lists" \
  "$TMP_DIR/audit.out"
assert_contains "1 unregistered director(ies), 1 stale git registration(s), 1 reported orphan(s)" \
  "$TMP_DIR/audit.out"
# Dry run: nothing ran, nothing went.
assert_eq 0 "$(marker_count remove)" "the audit runs no hook without --apply"
[[ -d "$AUDIT_REPO/.dex/worktrees/task-ghost" ]] || assert_at $LINENO
[[ -d "$AUDIT_REPO/.dex/worktrees/task-live" ]] || assert_at $LINENO

: > "$MARKER_FILE"
(cd "$AUDIT_REPO" && bash "$ROOT/bin/worktree.sh" audit --apply) > "$TMP_DIR/apply.out" 2>&1
[[ ! -d "$AUDIT_REPO/.dex/worktrees/task-ghost" ]] || assert_at $LINENO
# The registered worktree was never listed as a problem, so --apply leaves it.
[[ -d "$AUDIT_REPO/.dex/worktrees/task-live" ]] || assert_at $LINENO
assert_contains "remove name=task-ghost" "$MARKER_FILE"
assert_contains "remove name=task-vanished" "$MARKER_FILE"
# A reported orphan has no directory, so the hook runs from the checkout with
# the reported line as the name.
assert_contains "remove name=task-retired" "$MARKER_FILE"
assert_contains "cwd=$AUDIT_REPO" "$MARKER_FILE"
# The live worktree the probe also named was never torn down, and is still a
# checkout git knows about.
assert_eq 0 "$(marker_count task-live)" \
  "--apply does not tear down a live worktree, however the probe spelled it"
assert_eq 0 "$(marker_count TASK-LIVE)" \
  "a case-folded spelling of a live worktree is held back too"
# A linked worktree's .git is a file pointing at the common dir, not a dir.
[[ -f "$AUDIT_REPO/.dex/worktrees/task-live/.git" ]] || assert_at $LINENO
git -C "$AUDIT_REPO" worktree list --porcelain \
  | grep -Fq "$AUDIT_REPO/.dex/worktrees/task-live" || assert_at $LINENO

# ── A probe's relative spelling resolves against the checkout ──────────────
# A probe prints paths relative to the repository it ran in. Dex resolves them
# there, not against wherever the caller happens to be standing.
(cd "$AUDIT_REPO/.dex" \
  && dx_worktree_name_is_live "$AUDIT_REPO" ".dex/worktrees/task-live") \
  || fail "a checkout-relative spelling of a live worktree was not live from a subdirectory"
if (cd "$AUDIT_REPO/.dex" \
    && dx_worktree_name_is_live "$AUDIT_REPO" ".dex/worktrees/task-retired"); then
  fail "a checkout-relative spelling of a retired worktree read as live"
fi

# ── "Cannot tell" reads as live ─────────────────────────────────────────────
# A working `git worktree list` always prints the main checkout, so a failed
# or empty listing is not an empty set of live worktrees; it is no answer, and
# no answer must never tear anything down.
NOGIT_DIR="$TMP_DIR/nogit"
mkdir -p "$NOGIT_DIR/.dex/worktrees/task-unknown"
LIVE_NAMES_RC=0
dx_worktree_live_names "$NOGIT_DIR" > "$TMP_DIR/nogit-live.out" 2>/dev/null \
  || LIVE_NAMES_RC=$?
assert_eq 2 "$LIVE_NAMES_RC" "a failed worktree listing is reported, not read as empty"
[[ ! -s "$TMP_DIR/nogit-live.out" ]] || assert_at $LINENO
dx_worktree_name_is_live "$NOGIT_DIR" task-anything \
  || fail "a reported name was an orphan while git could not list the worktrees"

# The same through the audit, with a git that fails on `worktree` only: the
# directories are all still there, the audit says it cannot tell, and --apply
# refuses to remove or tear down anything on that answer.
REAL_GIT=$(command -v git)
GITFAIL_BIN="$TMP_DIR/gitfail-bin"
mkdir -p "$GITFAIL_BIN"
cat > "$GITFAIL_BIN/git" <<STUB
#!/usr/bin/env bash
for argument in "\$@"; do
  if [[ "\$argument" == "worktree" ]]; then
    printf 'fatal: injected worktree failure\n' >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$GITFAIL_BIN/git"
mkdir -p "$AUDIT_REPO/.dex/worktrees/task-ghost"
: > "$MARKER_FILE"
GITFAIL_RC=0
(cd "$AUDIT_REPO" && PATH="$GITFAIL_BIN:$PATH" bash "$ROOT/bin/worktree.sh" audit --apply) \
  > "$TMP_DIR/apply-gitfail.out" 2>&1 || GITFAIL_RC=$?
assert_eq 1 "$GITFAIL_RC" "--apply refuses when git cannot list the worktrees"
assert_contains "could not list this repository's worktrees" "$TMP_DIR/apply-gitfail.out"
assert_contains "Nothing was removed" "$TMP_DIR/apply-gitfail.out"
[[ -d "$AUDIT_REPO/.dex/worktrees/task-ghost" ]] || assert_at $LINENO
[[ -d "$AUDIT_REPO/.dex/worktrees/task-live" ]] || assert_at $LINENO
assert_eq 0 "$(marker_count remove)" "no before_remove hook ran on a listing git could not give"
rm -rf "$AUDIT_REPO/.dex/worktrees/task-ghost"

# ── The probe's own outcome: absent, crashed, and silent are three answers ──

# A repository that declares no probe still gets an audit, and says so.
: > "$MARKER_FILE"
(cd "$BARE_REPO" && bash "$ROOT/bin/worktree.sh" audit) > "$TMP_DIR/audit-bare.out" 2>&1
assert_contains "declares no orphan_resources probe" "$TMP_DIR/audit-bare.out"
assert_contains "Dex, git and this project agree." "$TMP_DIR/audit-bare.out"
assert_eq 0 "$(marker_count remove)" "an agreeing audit runs nothing"
PROBE_STATUS=0
dx_worktree_orphan_resources "$BARE_REPO" >/dev/null 2>&1 || PROBE_STATUS=$?
assert_eq 1 "$PROBE_STATUS" "no probe is 1"

# A probe that crashed must not read as a clean bill of health.
BROKEN_PROBE_REPO="$TMP_DIR/broken-probe"
make_repo "$BROKEN_PROBE_REPO" \
  'orphan_resources: printf "%s\n" "the probe blew up" >&2; exit 9'
PROBE_STATUS=0
dx_worktree_orphan_resources "$BROKEN_PROBE_REPO" \
  > "$TMP_DIR/probe-broken.out" 2> "$TMP_DIR/probe-broken.err" || PROBE_STATUS=$?
assert_eq 2 "$PROBE_STATUS" "a failed probe is 2, not 1"
assert_contains "orphan_resources probe failed (exit 9)" "$TMP_DIR/probe-broken.err"
assert_eq "" "$(cat "$TMP_DIR/probe-broken.out")" "a failed probe reports no orphans"
(cd "$BROKEN_PROBE_REPO" && bash "$ROOT/bin/worktree.sh" audit) \
  > "$TMP_DIR/audit-broken.out" 2>&1
assert_contains "the probe failed; Dex cannot tell whether this project is clean" \
  "$TMP_DIR/audit-broken.out"
assert_contains "orphan_resources probe failed (exit 9)" "$TMP_DIR/audit-broken.out"
assert_not_contains "Dex, git and this project agree." "$TMP_DIR/audit-broken.out"
assert_not_contains "declares no orphan_resources probe" "$TMP_DIR/audit-broken.out"

# A probe that ran and found nothing is the reassuring case, and says so in
# its own words rather than borrowing the "no probe" line.
SILENT_PROBE_REPO="$TMP_DIR/silent-probe"
make_repo "$SILENT_PROBE_REPO" 'orphan_resources: true'
PROBE_STATUS=0
dx_worktree_orphan_resources "$SILENT_PROBE_REPO" >/dev/null 2>&1 || PROBE_STATUS=$?
assert_eq 3 "$PROBE_STATUS" "a silent probe is 3"
(cd "$SILENT_PROBE_REPO" && bash "$ROOT/bin/worktree.sh" audit) \
  > "$TMP_DIR/audit-silent.out" 2>&1
assert_contains "the probe ran and reported nothing" "$TMP_DIR/audit-silent.out"
assert_contains "Dex, git and this project agree." "$TMP_DIR/audit-silent.out"

bash "$ROOT/bin/worktree.sh" --help > "$TMP_DIR/worktree-help.out"
assert_contains "Usage: dx worktree audit" "$TMP_DIR/worktree-help.out"
WT_STATUS=0
(cd "$AUDIT_REPO" && bash "$ROOT/bin/worktree.sh" audit --oops) > "$TMP_DIR/audit-bad.out" 2>&1 \
  || WT_STATUS=$?
assert_eq 1 "$WT_STATUS" "an unknown audit option is rejected"
assert_contains "Unknown worktree audit option" "$TMP_DIR/audit-bad.out"

# ─── 7. The UI-proof baseline checkout ──────────────────────────────────────

BASE_REPO="$TMP_DIR/baseline-repo"
make_repo "$BASE_REPO" "after_create: $CREATE_HOOK" "before_remove: $REMOVE_HOOK"
BASE_COMMIT=$(git -C "$BASE_REPO" rev-parse HEAD)
BASE_ROOT="$TMP_DIR/proof-root"
mkdir -p "$BASE_ROOT"
BASE_CHECKOUT="$BASE_ROOT/baseline"

: > "$MARKER_FILE"
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" add-baseline "$BASE_CHECKOUT" "$BASE_COMMIT") \
  > "$TMP_DIR/baseline-add.out" 2>&1
[[ -d "$BASE_CHECKOUT" ]] || assert_at $LINENO
assert_contains "create name=baseline" "$MARKER_FILE"

: > "$MARKER_FILE"
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" remove-baseline "$BASE_CHECKOUT") \
  > "$TMP_DIR/baseline-remove.out" 2>&1
[[ ! -d "$BASE_CHECKOUT" ]] || assert_at $LINENO
assert_contains "remove name=baseline" "$MARKER_FILE"
# The prompt's teardown also expects the temporary parent to go.
[[ ! -d "$BASE_ROOT" ]] || assert_at $LINENO

# It refuses the checkouts that are not its business.
: > "$MARKER_FILE"
WT_STATUS=0
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" remove-baseline "$BASE_REPO") \
  > "$TMP_DIR/baseline-main.out" 2>&1 || WT_STATUS=$?
assert_eq 1 "$WT_STATUS" "the main checkout is refused"
assert_contains "Refusing to remove the main checkout" "$TMP_DIR/baseline-main.out"
[[ -d "$BASE_REPO" ]] || assert_at $LINENO

git -C "$BASE_REPO" worktree add -q --no-track \
  "$BASE_REPO/.dex/worktrees/task-lifecycle" -b worktree-task-lifecycle main
WT_STATUS=0
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" remove-baseline \
  "$BASE_REPO/.dex/worktrees/task-lifecycle") > "$TMP_DIR/baseline-lifecycle.out" 2>&1 \
  || WT_STATUS=$?
assert_eq 1 "$WT_STATUS" "a lifecycle worktree is not a baseline"
assert_contains "Remove it with dxrm" "$TMP_DIR/baseline-lifecycle.out"
[[ -d "$BASE_REPO/.dex/worktrees/task-lifecycle" ]] || assert_at $LINENO

WT_STATUS=0
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" add-baseline \
  "$BASE_REPO/.dex/worktrees/task-nope" "$BASE_COMMIT") \
  > "$TMP_DIR/baseline-inside.out" 2>&1 || WT_STATUS=$?
assert_eq 1 "$WT_STATUS" "a baseline is not created inside .dex/worktrees/"
[[ ! -e "$BASE_REPO/.dex/worktrees/task-nope" ]] || assert_at $LINENO

# A directory that is not a checkout at all.
mkdir -p "$TMP_DIR/not-a-repo"
WT_STATUS=0
(cd "$BASE_REPO" && bash "$ROOT/bin/worktree.sh" remove-baseline "$TMP_DIR/not-a-repo") \
  > "$TMP_DIR/baseline-nonrepo.out" 2>&1 || WT_STATUS=$?
assert_eq 1 "$WT_STATUS" "an unregistered directory is refused"
[[ -d "$TMP_DIR/not-a-repo" ]] || assert_at $LINENO

assert_eq 0 "$(marker_count remove)" "a refused baseline removal runs no hook"

# ─── 8. dx maintain cuts and drops worktrees too ────────────────────────────
#
# Its worktree builders return the path on stdout and the caller reads it with
# a command substitution, so a hook that printed there would be captured as
# part of the path. The hook goes to stderr; this pins that it stays there.

MAINT_REPO="$TMP_DIR/maintain"
make_repo "$MAINT_REPO" "after_create: $CREATE_HOOK" "before_remove: $REMOVE_HOOK"
MAINT_SHA=$(git -C "$MAINT_REPO" rev-parse HEAD)
: > "$MARKER_FILE"

(
  # maintain.sh installs its own EXIT trap, so keep it inside a subshell where
  # it cannot take this test's cleanup with it.
  # shellcheck disable=SC1091
  source "$ROOT/bin/maintain.sh"
  cd "$MAINT_REPO"
  __dx_maintain_prepare_worktree "$MAINT_REPO" maintain-run-1 "dex/maintain/" main \
    > "$TMP_DIR/maintain-run.path" 2>"$TMP_DIR/maintain-run.err"
  __dx_maintain_prepare_response_worktree "$MAINT_REPO" "dex/maintain/maintain-resp-1" \
    "$MAINT_SHA" maintain-resp-1 \
    > "$TMP_DIR/maintain-resp.path" 2>"$TMP_DIR/maintain-resp.err"
  __dx_maintain_cleanup_response_worktree "$MAINT_REPO" \
    "$(cat "$TMP_DIR/maintain-resp.path")" > "$TMP_DIR/maintain-drop.out" 2>&1
) || fail "the maintenance worktree helpers did not complete"

assert_eq "$MAINT_REPO/.dex/worktrees/maintain-run-1	dex/maintain/maintain-run-1" \
  "$(cat "$TMP_DIR/maintain-run.path")" \
  "the run worktree path and branch reach the caller unpolluted"
assert_eq "$MAINT_REPO/.dex/worktrees/maintain-resp-1-respond" \
  "$(cat "$TMP_DIR/maintain-resp.path")" \
  "the respond worktree path reaches the caller unpolluted"
assert_contains "create name=maintain-run-1" "$MARKER_FILE"
assert_contains "create name=maintain-resp-1-respond" "$MARKER_FILE"
assert_contains "remove name=maintain-resp-1-respond" "$MARKER_FILE"
[[ ! -d "$MAINT_REPO/.dex/worktrees/maintain-resp-1-respond" ]] || assert_at $LINENO
# The hook's own line went to stderr, which is where the path contract needs
# it, and it is still visible to whoever is reading the run.
assert_contains "after_create worktree hook" "$TMP_DIR/maintain-run.err"

# ─── 9. on_session_end, through the real SessionEnd hook ───────────────────
#
# Driven the way tests/session-telemetry-test.sh drives it: the hook payload on
# stdin, DEX_SESSION_ID in the environment, and the working directory standing
# in for the session's checkout. A session holds ports and leases the worktree
# does not own, and the hook is the only place a repository can say how to
# release them — so it is worth proving it actually executes, not just that
# the reader can find it.

SESSION_REPO="$TMP_DIR/session-end"
make_repo "$SESSION_REPO" \
  'on_session_end: printf "%s\n" "session-end name=$DX_WORKTREE_NAME ticket=$DX_TICKET repo=$DX_REPO_ROOT cwd=$PWD" >> "$MARKER_FILE"'
git -C "$SESSION_REPO" worktree add -q --no-track \
  "$SESSION_REPO/.dex/worktrees/ticket-908" -b worktree-ticket-908 main

: > "$MARKER_FILE"
printf '%s\n' '{"session_id":"worktree-hooks-session-end"}' \
  | (cd "$SESSION_REPO/.dex/worktrees/ticket-908" \
    && env DEX_SESSION_ID=worktree-hooks-session-end \
      bash "$ROOT/hooks/session-end.sh") > "$TMP_DIR/session-end.out" 2>&1
assert_contains "session-end name=ticket-908 ticket=908" "$MARKER_FILE"
# dx_repo_root escapes the worktree, so the hook is told the main checkout
# while it runs in the worktree — the same pairing every other call site uses.
assert_contains "repo=$SESSION_REPO" "$MARKER_FILE"
assert_contains "cwd=$SESSION_REPO/.dex/worktrees/ticket-908" "$MARKER_FILE"

# In place there is no worktree, so the name is the repository directory's.
: > "$MARKER_FILE"
printf '%s\n' '{"session_id":"worktree-hooks-session-end-inplace"}' \
  | (cd "$SESSION_REPO" \
    && env DEX_SESSION_ID=worktree-hooks-session-end-inplace \
      bash "$ROOT/hooks/session-end.sh") > "$TMP_DIR/session-end-inplace.out" 2>&1
assert_contains "session-end name=session-end ticket= repo=$SESSION_REPO" "$MARKER_FILE"

# A project that declares nothing gets a silent session end, as before.
: > "$MARKER_FILE"
printf '%s\n' '{"session_id":"worktree-hooks-session-end-bare"}' \
  | (cd "$BARE_REPO" \
    && env DEX_SESSION_ID=worktree-hooks-session-end-bare \
      bash "$ROOT/hooks/session-end.sh") > "$TMP_DIR/session-end-bare.out" 2>&1
assert_eq 0 "$(marker_count session-end)" "no declaration, no hook"
assert_not_contains "worktree hook" "$TMP_DIR/session-end-bare.out"

# The host gives the whole SessionEnd hook ten seconds (settings.json, pinned
# by tests/install-health-test.sh). The project's command runs before the reap
# and the temp-root cleanup, so a hook that took the project's own 300 s
# default would be killed by the host mid-script and take those with it,
# without saying anything. The call site caps it at five seconds; what has to
# survive that is everything after it.
SLOW_SESSION_REPO="$TMP_DIR/session-end-slow"
make_repo "$SLOW_SESSION_REPO" \
  'on_session_end: /bin/sleep 12; printf "%s\n" "slow session hook finished" >> "$MARKER_FILE"'
SLOW_SESSION_ID=worktree-hooks-session-end-slow
printf '0:100\n' > "$DX_STATE_DIR/${SLOW_SESSION_ID}.times"
printf 'context\n' > "$DX_STATE_DIR/${SLOW_SESSION_ID}.system-context"
: > "$MARKER_FILE"
SLOW_SESSION_START=$(date +%s)
printf '%s\n' "{\"session_id\":\"$SLOW_SESSION_ID\"}" \
  | (cd "$SLOW_SESSION_REPO" \
    && env DEX_SESSION_ID="$SLOW_SESSION_ID" DEX_WORKTREE_HOOK_TIMEOUT=0 \
      bash "$ROOT/hooks/session-end.sh") > "$TMP_DIR/session-end-slow.out" 2>&1
SLOW_SESSION_ELAPSED=$(( $(date +%s) - SLOW_SESSION_START ))
# DEX_WORKTREE_HOOK_TIMEOUT=0 means "no deadline" everywhere else; here the
# call site's budget wins, and says so.
assert_contains "passed 5s and was stopped" "$TMP_DIR/session-end-slow.out"
assert_eq 0 "$(marker_count "slow session hook finished")" \
  "the capped hook never reached its second command"
# The two things the session depends on both run after the hook. The context
# file is removed by the last line of the script, so its absence is the proof
# that the host's ten seconds were not spent inside the project's command.
[[ ! -f "$DX_STATE_DIR/${SLOW_SESSION_ID}.system-context" ]] || assert_at $LINENO
[[ $(wc -l < "$DX_STATE_DIR/${SLOW_SESSION_ID}.times") -eq 2 ]] || assert_at $LINENO
# Not a measurement of the cap, only that the whole hook fits in the budget
# the host allows it, with room for a loaded machine.
[[ "$SLOW_SESSION_ELAPSED" -lt 10 ]] || assert_at $LINENO

# A vendored runtime carrying only part of lib/ still has to be able to end a
# session — tests/session-end-ownership-test.sh pins that, and loading three
# more modules for this hook is exactly how it would stop being true. Here the
# repository does declare on_session_end, which is the case that reaches the
# new code, so the degradation has to be "no hook", never "no session end".
MINIMAL_DEX="$TMP_DIR/minimal-dex"
mkdir -p "$MINIMAL_DEX/hooks" "$MINIMAL_DEX/lib" "$TMP_DIR/minimal-state" "$TMP_DIR/minimal-loops"
cp "$ROOT/hooks/session-end.sh" "$MINIMAL_DEX/hooks/"
cp "$ROOT/lib/common.sh" "$ROOT/lib/session.sh" "$ROOT/lib/session-process.sh" "$MINIMAL_DEX/lib/"
printf '0:100\n' > "$TMP_DIR/minimal-state/minimal-hooks-session.times"
: > "$MARKER_FILE"
printf '%s\n' '{"session_id":"minimal-hooks-session"}' \
  | (cd "$SESSION_REPO/.dex/worktrees/ticket-908" && env \
      DEX_DIR="$MINIMAL_DEX" DEX_SESSION_ID=minimal-hooks-session \
      DX_STATE_DIR="$TMP_DIR/minimal-state" DX_LOOP_DIR="$TMP_DIR/minimal-loops" \
      bash "$MINIMAL_DEX/hooks/session-end.sh") > "$TMP_DIR/session-end-minimal.out" 2>&1 \
  || fail "session end failed on a runtime carrying only part of lib/"
[[ $(wc -l < "$TMP_DIR/minimal-state/minimal-hooks-session.times") -eq 2 ]] || assert_at $LINENO
assert_eq 0 "$(marker_count session-end)" "a partial runtime skips the hook rather than failing"

# The hook runs before the reap, so anything it starts is still the session's.
# The order is what makes that true; assert it rather than trusting the file.
SESSION_HOOK_LINE=$(grep -n 'dx_worktree_hook_run on_session_end' "$ROOT/hooks/session-end.sh" | head -1 | cut -d: -f1)
SESSION_REAP_LINE=$(grep -n 'dx_session_finish_processes' "$ROOT/hooks/session-end.sh" | head -1 | cut -d: -f1)
[[ -n "$SESSION_HOOK_LINE" && -n "$SESSION_REAP_LINE" ]] || assert_at $LINENO
[[ "$SESSION_HOOK_LINE" -lt "$SESSION_REAP_LINE" ]] || assert_at $LINENO

printf 'worktree hook tests passed\n'
