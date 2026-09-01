#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ticket-branch-adoption.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"

cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DX_TEST_GH_LOG"
[[ "${1:-}" == "pr" && "${2:-}" == "list" ]] || exit 64
pr_state=""
shift 2
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--state" ]]; then
    pr_state="${2:-}"
    shift 2
  else
    shift
  fi
done
case "${DX_TEST_PR_MODE:-none}:${pr_state}" in
  open:open) printf '1\n' ;;
  open:all) printf '1\n' ;;
  none:open|none:all) printf '0\n' ;;
  historical:open) printf '0\n' ;;
  historical:all) printf '1\n' ;;
  failure:*) exit 1 ;;
  *) exit 65 ;;
esac
SH
chmod +x "$TMP_DIR/bin/gh"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

new_fixture() {
  local name="$1" branch_name="$2"
  FIXTURE_REMOTE="$TMP_DIR/${name}.git"
  FIXTURE_SEED="$TMP_DIR/${name}-seed"
  FIXTURE_REPO="$TMP_DIR/${name}-repo"

  git init -q --bare "$FIXTURE_REMOTE"
  git clone -q "$FIXTURE_REMOTE" "$FIXTURE_SEED"
  git -C "$FIXTURE_SEED" config user.email dex@example.test
  git -C "$FIXTURE_SEED" config user.name "Dex Test"
  printf 'base\n' > "$FIXTURE_SEED/base.txt"
  git -C "$FIXTURE_SEED" add base.txt
  git -C "$FIXTURE_SEED" commit -q -m "test: add base"
  git -C "$FIXTURE_SEED" branch -M main
  git -C "$FIXTURE_SEED" push -q -u origin main
  git -C "$FIXTURE_REMOTE" symbolic-ref HEAD refs/heads/main

  git -C "$FIXTURE_SEED" switch -q -c "$branch_name"
  printf 'remote work\n' > "$FIXTURE_SEED/remote.txt"
  git -C "$FIXTURE_SEED" add remote.txt
  git -C "$FIXTURE_SEED" commit -q -m "test: add remote work"
  git -C "$FIXTURE_SEED" push -q -u origin "$branch_name"
  FIXTURE_REMOTE_OID=$(git -C "$FIXTURE_SEED" rev-parse HEAD)

  git -C "$FIXTURE_SEED" switch -q main
  printf 'new default work\n' > "$FIXTURE_SEED/default-later.txt"
  git -C "$FIXTURE_SEED" add default-later.txt
  git -C "$FIXTURE_SEED" commit -q -m "test: advance default"
  git -C "$FIXTURE_SEED" push -q

  git clone -q "$FIXTURE_REMOTE" "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" config user.email dex@example.test
  git -C "$FIXTURE_REPO" config user.name "Dex Test"
}

prepare_session() {
  local repo_dir="$1" placeholder_branch="$2" session_label="$3"
  PREPARED_SESSION=$(cd "$repo_dir" && dx_scoped_session_id "$session_label")
  PREPARED_HEAD=$(git -C "$repo_dir" rev-parse HEAD)
  dx_meta_write "$PREPARED_SESSION" \
    "original_branch=${placeholder_branch}" \
    "original_head=${PREPARED_HEAD}"
  dx_record_session_branch "$PREPARED_SESSION" "$repo_dir"
}

# A linked worktree adopts an existing remote branch when its PR is open.
new_fixture open-pr feature/ENG-123-existing
git -C "$FIXTURE_REPO" branch worktree-ticket-123 origin/main
mkdir -p "$FIXTURE_REPO/.dex/worktrees"
OPEN_WORKTREE="$FIXTURE_REPO/.dex/worktrees/ticket-123"
git -C "$FIXTURE_REPO" worktree add -q "$OPEN_WORKTREE" worktree-ticket-123
prepare_session "$OPEN_WORKTREE" worktree-ticket-123 ticket-123-open
export DX_TEST_GH_LOG="$TMP_DIR/open-pr-gh.log"
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=open \
  dx_ticket_branch_prepare feature/ENG-123-existing "$OPEN_WORKTREE")
assert_eq "remote" "$branch_source" "open PR branch source"
assert_eq "feature/ENG-123-existing" \
  "$(git -C "$OPEN_WORKTREE" branch --show-current)" "open PR branch name"
assert_eq "$FIXTURE_REMOTE_OID" "$(git -C "$OPEN_WORKTREE" rev-parse HEAD)" \
  "open PR remote head"
assert_eq "origin/feature/ENG-123-existing" \
  "$(git -C "$OPEN_WORKTREE" rev-parse --abbrev-ref --symbolic-full-name '@{u}')" \
  "open PR upstream"
assert_eq "feature/ENG-123-existing" \
  "$(dx_session_branch_read "$PREPARED_SESSION")" "saved open PR branch"
assert_eq "remote" "$(dx_meta_read "$PREPARED_SESSION" ticket_branch_source)" \
  "saved open PR branch source"
assert_eq "$FIXTURE_REMOTE_OID" \
  "$(dx_meta_read "$PREPARED_SESSION" ticket_branch_remote_oid)" \
  "saved open PR remote head"
assert_eq "OPEN" "$(dx_meta_read "$PREPARED_SESSION" ticket_branch_pr_kind)" \
  "saved open PR state"
assert_contains "pr list --state open --head feature/ENG-123-existing" \
  "$DX_TEST_GH_LOG"

# An in-place lifecycle adopts the remote branch when no PR exists.
new_fixture no-pr feature/ENG-124-existing
git -C "$FIXTURE_REPO" switch -q --no-track -c worktree-ticket-124 origin/main
prepare_session "$FIXTURE_REPO" worktree-ticket-124 ticket-124-no-pr
export DX_TEST_GH_LOG="$TMP_DIR/no-pr-gh.log"
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=none \
  dx_ticket_branch_prepare feature/ENG-124-existing "$FIXTURE_REPO")
assert_eq "remote" "$branch_source" "no PR branch source"
assert_eq "feature/ENG-124-existing" \
  "$(git -C "$FIXTURE_REPO" branch --show-current)" "no PR branch name"
assert_eq "$FIXTURE_REMOTE_OID" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "no PR remote head"
assert_eq "origin/feature/ENG-124-existing" \
  "$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}')" \
  "no PR upstream"
assert_eq "NONE" "$(dx_meta_read "$PREPARED_SESSION" ticket_branch_pr_kind)" \
  "saved no PR state"
assert_contains "pr list --state all --head feature/ENG-124-existing" \
  "$DX_TEST_GH_LOG"

# The operation is idempotent and fast-forwards a branch that moves remotely.
git -C "$FIXTURE_SEED" switch -q feature/ENG-124-existing
printf 'remote follow-up\n' >> "$FIXTURE_SEED/remote.txt"
git -C "$FIXTURE_SEED" add remote.txt
git -C "$FIXTURE_SEED" commit -q -m "test: advance remote work"
git -C "$FIXTURE_SEED" push -q
advanced_remote_oid=$(git -C "$FIXTURE_SEED" rev-parse HEAD)
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=none \
  dx_ticket_branch_prepare feature/ENG-124-existing "$FIXTURE_REPO")
assert_eq "remote" "$branch_source" "repeated branch source"
assert_eq "$advanced_remote_oid" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "repeated adoption fast-forwarded"

# Rechecking an adopted branch preserves compatible local commits ahead of
# origin instead of resetting them.
printf 'local follow-up\n' > "$FIXTURE_REPO/local-follow-up.txt"
git -C "$FIXTURE_REPO" add local-follow-up.txt
git -C "$FIXTURE_REPO" commit -q -m "test: keep compatible local work"
local_ahead_oid=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=none \
  dx_ticket_branch_prepare feature/ENG-124-existing "$FIXTURE_REPO")
assert_eq "remote" "$branch_source" "local-ahead branch source"
assert_eq "$local_ahead_oid" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "compatible local commit preserved"

# A compatible branch that exists only locally is reused without consulting
# GitHub or gaining an upstream.
new_fixture local-only feature/ENG-129-other
git -C "$FIXTURE_REPO" branch feature/ENG-129-local origin/main
git -C "$FIXTURE_REPO" switch -q feature/ENG-129-local
printf 'local-only work\n' > "$FIXTURE_REPO/local-only.txt"
git -C "$FIXTURE_REPO" add local-only.txt
git -C "$FIXTURE_REPO" commit -q -m "test: add local-only work"
local_only_oid=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
git -C "$FIXTURE_REPO" switch -q --no-track -c worktree-ticket-129 origin/main
prepare_session "$FIXTURE_REPO" worktree-ticket-129 ticket-129-local
export DX_TEST_GH_LOG="$TMP_DIR/local-only-gh.log"
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=failure \
  dx_ticket_branch_prepare feature/ENG-129-local "$FIXTURE_REPO")
assert_eq "local" "$branch_source" "local-only branch source"
assert_eq "$local_only_oid" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "local-only branch head"
local_only_upstream=$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref \
  --symbolic-full-name '@{u}' 2>/dev/null || true)
assert_eq "" "$local_only_upstream" "local-only branch upstream"
[[ ! -e "$DX_TEST_GH_LOG" ]] || assert_at $LINENO

# A Phase 0 session created by an older Dex release has no original_head. Its
# untouched default-tip placeholder remains safe to migrate.
new_fixture legacy feature/ENG-125-existing
git -C "$FIXTURE_REPO" switch -q --no-track -c worktree-ticket-125 origin/main
prepare_session "$FIXTURE_REPO" worktree-ticket-125 ticket-125-legacy
dx_meta_write "$PREPARED_SESSION" "original_head="
export DX_TEST_GH_LOG="$TMP_DIR/legacy-gh.log"
branch_source=$(DEX_SESSION_ID="$PREPARED_SESSION" DX_TEST_PR_MODE=none \
  dx_ticket_branch_prepare feature/ENG-125-existing "$FIXTURE_REPO")
assert_eq "remote" "$branch_source" "legacy branch source"
assert_eq "$FIXTURE_REMOTE_OID" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "legacy branch remote head"

# Both lifecycle workspace modes seal the disposable placeholder's starting
# commit before Phase 0 can adopt a remote branch.
new_fixture setup-worktree feature/ENG-126-existing
mkdir -p "$FIXTURE_REPO/.dex"
export DX_TEST_SETUP_REPO="$FIXTURE_REPO"
zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$DX_TEST_SETUP_REPO"
  __dx_setup_worktree 126
  session_id=$(dx_session_id ticket-126)
  worktree_dir="$DX_TEST_SETUP_REPO/.dex/worktrees/ticket-126"
  [[ "$(dx_meta_read "$session_id" original_branch)" == worktree-ticket-126 ]] || exit 1
  [[ "$(dx_meta_read "$session_id" original_head)" == "$(git -C "$worktree_dir" rev-parse HEAD)" ]] || exit 1
  __dx_startup_claim_release
'

new_fixture setup-inplace feature/ENG-127-existing
mkdir -p "$FIXTURE_REPO/.dex"
export DX_TEST_SETUP_REPO="$FIXTURE_REPO"
zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$DX_TEST_SETUP_REPO"
  __dx_setup_in_place 127
  session_id=$(__dx_session_id_for_workspace in-place ticket-127)
  [[ "$(dx_meta_read "$session_id" original_branch)" == worktree-ticket-127 ]] || exit 1
  [[ "$(dx_meta_read "$session_id" original_head)" == "$(git rev-parse HEAD)" ]] || exit 1
  __dx_startup_claim_release
'

# The shared helper itself runs under zsh as well as bash.
new_fixture zsh-helper feature/ENG-128-existing
git -C "$FIXTURE_REPO" switch -q --no-track -c worktree-ticket-128 origin/main
prepare_session "$FIXTURE_REPO" worktree-ticket-128 ticket-128-zsh
export DX_TEST_ZSH_REPO="$FIXTURE_REPO"
export DX_TEST_ZSH_SESSION="$PREPARED_SESSION"
export DX_TEST_ZSH_REMOTE_OID="$FIXTURE_REMOTE_OID"
export DX_TEST_GH_LOG="$TMP_DIR/zsh-helper-gh.log"
export DX_TEST_PR_MODE=none
zsh -fc '
  source "$DEX_DIR/lib/common.sh"
  set -e
  branch_source=$(DEX_SESSION_ID="$DX_TEST_ZSH_SESSION" \
    dx_ticket_branch_prepare feature/ENG-128-existing "$DX_TEST_ZSH_REPO")
  [[ "$branch_source" == remote ]] || exit 1
  [[ "$(git -C "$DX_TEST_ZSH_REPO" branch --show-current)" == \
    feature/ENG-128-existing ]] || exit 1
  [[ "$(git -C "$DX_TEST_ZSH_REPO" rev-parse HEAD)" == \
    "$DX_TEST_ZSH_REMOTE_OID" ]] || exit 1
'

printf 'ticket branch adoption tests passed\n'
