#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ticket-branch-errors.XXXXXX")"

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
  open:open|open:all) printf '1\n' ;;
  none:open|none:all) printf '0\n' ;;
  historical:open) printf '0\n' ;;
  historical:all) printf '1\n' ;;
  malformed:*) printf 'not-a-count\n' ;;
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
  git clone -q "$FIXTURE_REMOTE" "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" config user.email dex@example.test
  git -C "$FIXTURE_REPO" config user.name "Dex Test"
  git -C "$FIXTURE_REPO" switch -q --no-track -c \
    "worktree-ticket-${name}" origin/main
  FIXTURE_PLACEHOLDER="worktree-ticket-${name}"
  FIXTURE_START_OID=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
  FIXTURE_SESSION=$(cd "$FIXTURE_REPO" && dx_scoped_session_id "ticket-${name}")
  dx_meta_write "$FIXTURE_SESSION" \
    "original_branch=${FIXTURE_PLACEHOLDER}" \
    "original_head=${FIXTURE_START_OID}"
  dx_record_session_branch "$FIXTURE_SESSION" "$FIXTURE_REPO"
}

assert_branch_unchanged() {
  local label="$1"
  assert_eq "$FIXTURE_PLACEHOLDER" \
    "$(git -C "$FIXTURE_REPO" branch --show-current)" "$label branch"
  assert_eq "$FIXTURE_CURRENT_OID" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
    "$label head"
}

run_rejected() {
  local label="$1" mode="$2" branch_name="$3" output_file="$4"
  FIXTURE_CURRENT_OID=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
  if DEX_SESSION_ID="$FIXTURE_SESSION" DX_TEST_PR_MODE="$mode" \
      dx_ticket_branch_prepare "$branch_name" "$FIXTURE_REPO" \
      > "$output_file" 2>&1; then
    printf '%s: expected ticket branch setup to fail\n' "$label" >&2
    exit 1
  fi
  assert_branch_unchanged "$label"
}

# Closed or merged pull-request history must not revive a remote branch.
new_fixture 201 feature/ENG-201-historical
run_rejected "historical PR" historical feature/ENG-201-historical \
  "$TMP_DIR/historical.out"
assert_contains "only closed or merged pull requests" "$TMP_DIR/historical.out"
assert_eq "" "$(dx_meta_read "$FIXTURE_SESSION" ticket_branch_source)" \
  "historical PR source metadata"

# Failed or malformed GitHub responses are not treated as no PR.
new_fixture 202 feature/ENG-202-gh-failure
run_rejected "GitHub failure" failure feature/ENG-202-gh-failure \
  "$TMP_DIR/gh-failure.out"
assert_contains "Could not check pull requests" "$TMP_DIR/gh-failure.out"

new_fixture 203 feature/ENG-203-gh-malformed
run_rejected "malformed GitHub response" malformed \
  feature/ENG-203-gh-malformed "$TMP_DIR/gh-malformed.out"
assert_contains "Could not check pull requests" "$TMP_DIR/gh-malformed.out"

# Dirty state blocks every branch mutation, including untracked files.
new_fixture 204 feature/ENG-204-dirty
printf 'local work\n' > "$FIXTURE_REPO/untracked.txt"
run_rejected "dirty worktree" open feature/ENG-204-dirty "$TMP_DIR/dirty.out"
assert_contains "with uncommitted changes" "$TMP_DIR/dirty.out"
[[ -f "$FIXTURE_REPO/untracked.txt" ]] || assert_at $LINENO

# A clean placeholder with a commit after its recorded starting point is user
# work, not disposable setup state.
new_fixture 205 feature/ENG-205-advanced
printf 'local commit\n' > "$FIXTURE_REPO/local.txt"
git -C "$FIXTURE_REPO" add local.txt
git -C "$FIXTURE_REPO" commit -q -m "test: add local work"
local_commit_oid=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
run_rejected "advanced placeholder" open feature/ENG-205-advanced \
  "$TMP_DIR/advanced.out"
assert_contains "no longer matches the untouched lifecycle starting point" \
  "$TMP_DIR/advanced.out"
assert_eq "$local_commit_oid" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "advanced placeholder commit preserved"

# A conflicting local branch is preserved alongside the placeholder.
new_fixture 206 feature/ENG-206-diverged
git -C "$FIXTURE_REPO" switch -q -c feature/ENG-206-diverged origin/main
printf 'different local work\n' > "$FIXTURE_REPO/local-branch.txt"
git -C "$FIXTURE_REPO" add local-branch.txt
git -C "$FIXTURE_REPO" commit -q -m "test: diverge local branch"
local_branch_oid=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
git -C "$FIXTURE_REPO" switch -q "$FIXTURE_PLACEHOLDER"
run_rejected "diverged local branch" open feature/ENG-206-diverged \
  "$TMP_DIR/diverged.out"
assert_contains "has diverged from origin" "$TMP_DIR/diverged.out"
assert_eq "$local_branch_oid" \
  "$(git -C "$FIXTURE_REPO" rev-parse feature/ENG-206-diverged)" \
  "diverged local branch preserved"

# A branch checked out elsewhere is never stolen from its owner worktree.
new_fixture 207 feature/ENG-207-owned
git -C "$FIXTURE_REPO" branch feature/ENG-207-owned "$FIXTURE_REMOTE_OID"
OWNING_WORKTREE="$TMP_DIR/owned-worktree"
git -C "$FIXTURE_REPO" worktree add -q "$OWNING_WORKTREE" \
  feature/ENG-207-owned
run_rejected "owned branch" open feature/ENG-207-owned "$TMP_DIR/owned.out"
assert_contains "is already checked out at" "$TMP_DIR/owned.out"

# Invalid names and a detached checkout fail before any ref can change.
new_fixture 208 feature/ENG-208-valid
run_rejected "invalid branch" none 'feature/bad..branch' "$TMP_DIR/invalid.out"
assert_contains "missing or invalid" "$TMP_DIR/invalid.out"

git -C "$FIXTURE_REPO" checkout -q --detach
detached_oid=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
if DX_TEST_PR_MODE=none dx_ticket_branch_prepare feature/ENG-208-valid \
    "$FIXTURE_REPO" > "$TMP_DIR/detached.out" 2>&1; then
  printf 'detached HEAD was accepted\n' >&2
  exit 1
fi
assert_contains "detached HEAD" "$TMP_DIR/detached.out"
assert_eq "$detached_oid" "$(git -C "$FIXTURE_REPO" rev-parse HEAD)" \
  "detached head preserved"

# Remote failures and timeouts do not become false "branch missing" results.
new_fixture 209 feature/ENG-209-remote-failure
git -C "$FIXTURE_REPO" remote set-url origin "$TMP_DIR/missing-origin.git"
run_rejected "remote failure" none feature/ENG-209-remote-failure \
  "$TMP_DIR/remote-failure.out"
assert_contains "will not treat a remote failure as a missing branch" \
  "$TMP_DIR/remote-failure.out"

new_fixture 210 feature/ENG-210-timeout
FIXTURE_CURRENT_OID=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
if (
  dx_run_with_timeout() { return 124; }
  DEX_SESSION_ID="$FIXTURE_SESSION" DX_TEST_PR_MODE=open \
    dx_ticket_branch_prepare feature/ENG-210-timeout "$FIXTURE_REPO"
) > "$TMP_DIR/timeout.out" 2>&1; then
  printf 'remote timeout was accepted\n' >&2
  exit 1
fi
assert_branch_unchanged "remote timeout"
assert_contains "Timed out while checking origin" "$TMP_DIR/timeout.out"

# Fetch and PR checks have independent timeout failures after branch discovery.
new_fixture 212 feature/ENG-212-fetch-timeout
FIXTURE_CURRENT_OID=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
if (
  dx_run_with_timeout() {
    shift
    case " $* " in
      *" fetch "*) return 124 ;;
      *) "$@" ;;
    esac
  }
  DEX_SESSION_ID="$FIXTURE_SESSION" DX_TEST_PR_MODE=open \
    dx_ticket_branch_prepare feature/ENG-212-fetch-timeout "$FIXTURE_REPO"
) > "$TMP_DIR/fetch-timeout.out" 2>&1; then
  printf 'fetch timeout was accepted\n' >&2
  exit 1
fi
assert_branch_unchanged "fetch timeout"
assert_contains "Timed out while fetching ticket branch" \
  "$TMP_DIR/fetch-timeout.out"

new_fixture 213 feature/ENG-213-pr-timeout
FIXTURE_CURRENT_OID=$(git -C "$FIXTURE_REPO" rev-parse HEAD)
if (
  dx_run_with_timeout() {
    shift
    if [[ "${1:-}" == "__dx_ticket_branch_gh" ]]; then
      return 124
    fi
    "$@"
  }
  DEX_SESSION_ID="$FIXTURE_SESSION" DX_TEST_PR_MODE=open \
    dx_ticket_branch_prepare feature/ENG-213-pr-timeout "$FIXTURE_REPO"
) > "$TMP_DIR/pr-timeout.out" 2>&1; then
  printf 'PR timeout was accepted\n' >&2
  exit 1
fi
assert_branch_unchanged "PR timeout"
assert_contains "Timed out while checking open pull requests" \
  "$TMP_DIR/pr-timeout.out"

# A missing remote branch becomes a new local branch without consulting PRs.
new_fixture 214 feature/ENG-214-other
new_source=$(DEX_SESSION_ID="$FIXTURE_SESSION" DX_TEST_PR_MODE=failure \
  dx_ticket_branch_prepare feature/ENG-214-new "$FIXTURE_REPO")
assert_eq "new" "$new_source" "new branch source"
assert_eq "feature/ENG-214-new" \
  "$(git -C "$FIXTURE_REPO" branch --show-current)" "new branch name"
new_upstream=$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref \
  --symbolic-full-name '@{u}' 2>/dev/null || true)
assert_eq "" "$new_upstream" "new branch upstream"

printf 'ticket branch adoption error tests passed\n'
