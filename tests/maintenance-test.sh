#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-maintenance-test.XXXXXX")"

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
export PATH="$TMP_DIR/bin:$PATH"
# GitHub Actions exports its checkout repository. This fixture owns repository
# discovery through its gh stub, so inherited CI context must not override it.
unset GH_REPO GITHUB_REPOSITORY
mkdir -p "$TMP_DIR/bin"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

repo="$TMP_DIR/repo"
mkdir -p "$repo/.dex"
git -C "$TMP_DIR" init -b main repo >/dev/null
cat > "$repo/.dex/dex.md" <<'EOF'
# Test Dex Context

## Maintenance

| Setting | Value |
|---------|-------|
| enabled | true |
| default_mode | propose |
| schedule_mode | report |
| issue_mode | fix-scoped |
| auto_merge | true |
| auto_merge_method | squash |
EOF


assert_eq "fix-scoped" "$(dx_maintenance_event_mode "$repo" issues "")" "issue event mode"
assert_eq "report" "$(dx_maintenance_event_mode "$repo" schedule "")" "schedule event mode"
assert_eq "propose" "$(dx_maintenance_event_mode "$repo" workflow_dispatch "")" "default event mode"
assert_eq "report" "$(dx_maintenance_event_mode "$repo" issues "report")" "explicit mode override"

(
  cd "$repo"
  assert_eq "fix-scoped" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event issues)" "CLI issue event mode"
  assert_eq "report" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event schedule)" "CLI schedule event mode"
  assert_eq "propose" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event workflow_dispatch)" "CLI default event mode"
  assert_eq "report" "$(bash "$ROOT/bin/maintain.sh" resolve-mode --event issues --explicit-mode report)" "CLI explicit mode override"
)

cat > "$repo/.dex/dex.md" <<'EOF'
# Test Dex Context

## Maintenance

| Setting | Value |
|---------|-------|
| default_mode | unexpected |
| issue_mode | also-unexpected |
EOF

assert_eq "report" "$(dx_maintenance_event_mode "$repo" issues "")" "invalid mode fallback"

assert_eq "none" "$(dx_maintenance_pr_review_state "")" \
  "missing GitHub review decision"
assert_eq "none" "$(dx_maintenance_pr_review_state "null")" \
  "JSON null review decision"
assert_eq "approved" "$(dx_maintenance_pr_review_state "APPROVED")" \
  "GitHub-approved review decision"
assert_eq "review-required" "$(dx_maintenance_pr_review_state "REVIEW_REQUIRED")" \
  "GitHub-required review decision"
assert_eq "changes-requested" "$(dx_maintenance_pr_review_state "CHANGES_REQUESTED")" \
  "GitHub changes-requested review decision"
set +e
unknown_review_state=$(dx_maintenance_pr_review_state "PENDING")
unknown_review_state_rc=$?
set -e
assert_eq "unknown" "$unknown_review_state" "unknown GitHub review decision"
assert_eq "2" "$unknown_review_state_rc" "unknown GitHub review decision exit status"

cat > "$TMP_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  printf '%s\n' "example/repo"
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "edit" ]]; then
  printf '%s\n' "$*" >> "${GH_FAKE_CALLS:?}"
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  case "${GH_FAKE_PR_CASE:-persisted}" in
    persisted)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[{"login":"reviewer"}],"requested_teams":[]}
JSON
      ;;
    missing)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}
JSON
      ;;
    author)
      cat <<'JSON'
{"user":{"login":"reviewer"},"requested_reviewers":[],"requested_teams":[]}
JSON
      ;;
    copilot)
      cat <<'JSON'
{"user":{"login":"author"},"requested_reviewers":[{"login":"copilot-pull-request-reviewer[bot]"}],"requested_teams":[]}
JSON
      ;;
  esac
  exit 0
fi

printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$TMP_DIR/bin/gh"
export GH_FAKE_CALLS="$TMP_DIR/gh-calls.log"

GH_FAKE_PR_CASE=persisted dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-persisted.out" 2>&1
assert_contains "pr edit 7 --repo example/repo --add-reviewer reviewer" "$GH_FAKE_CALLS"

GH_FAKE_PR_CASE=missing dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-missing.out" 2>&1
assert_contains "no review request persisted" "$TMP_DIR/reviewer-missing.out"

GH_FAKE_PR_CASE=author dx_maintenance_request_reviewer 7 reviewer example/repo > "$TMP_DIR/reviewer-author.out" 2>&1
assert_contains "does not allow requesting the PR author" "$TMP_DIR/reviewer-author.out"

GH_FAKE_PR_CASE=copilot dx_maintenance_request_reviewer 7 Copilot example/repo > "$TMP_DIR/reviewer-copilot.out" 2>&1
assert_contains "pr edit 7 --repo example/repo --add-reviewer @copilot" "$GH_FAKE_CALLS"
assert_eq "@copilot" \
  "$(dx_maintenance_normalize_reviewer 'copilot-pull-request-reviewer[bot]')" \
  "official Copilot reviewer identity normalization"

# Reviewer handles reach gh as arguments, so flag-shaped values from repo
# config must never be forwarded.
for bad_handle in "--repo" "-x" "--repo=owner/evil" "owner/team/extra" "not a name" "name;rm"; do
  if dx_maintenance_reviewer_handle_valid "$bad_handle"; then
    printf 'invalid reviewer handle accepted: %s\n' "$bad_handle" >&2
    exit 1
  fi
done
for good_handle in "mitchellfyi" "@copilot" "org/team" "a" "user-name-1"; do
  if ! dx_maintenance_reviewer_handle_valid "$good_handle"; then
    printf 'valid reviewer handle rejected: %s\n' "$good_handle" >&2
    exit 1
  fi
done

: > "$GH_FAKE_CALLS"
dx_maintenance_request_reviewer 7 "--repo=evil/repo" example/repo > "$TMP_DIR/reviewer-injection.out" 2>&1
assert_contains "Skipping invalid reviewer handle" "$TMP_DIR/reviewer-injection.out"
if grep -Fq "evil/repo" "$GH_FAKE_CALLS"; then
  printf 'flag-shaped reviewer handle reached gh\n' >&2
  cat "$GH_FAKE_CALLS" >&2
  exit 1
fi

last_success_target=$(dx_maintenance_last_success_file "maintenance-test")
mkdir -p "$(dirname "$last_success_target")"
printf 'user-owned temp file\n' > "${last_success_target}.tmp.$$"
dx_maintenance_write_last_success "maintenance-test" "maintain-20260807T120000Z-test-u-12345678"
assert_contains "user-owned temp file" "${last_success_target}.tmp.$$"
assert_contains "run_id=maintain-20260807T120000Z-test-u-12345678" "$last_success_target"

dx_maintenance_source_repo() {
  printf '%s\n' "example/dex"
}

dx_maintenance_source_ref() {
  printf '%s\n' "test-ref"
}

workflow_target="$repo/.github/workflows/dx-maintain.yml"
mkdir -p "$(dirname "$workflow_target")"
printf 'user-owned workflow temp\n' > "${workflow_target}.tmp.$$"
dx_maintenance_install_workflow "$repo" > "$TMP_DIR/workflow-install.out"
assert_contains "user-owned workflow temp" "${workflow_target}.tmp.$$"
assert_contains "DEX_REPO: example/dex" "$workflow_target"
assert_contains "DEX_REF: test-ref" "$workflow_target"

# This repo runs its own installed copy of the workflow, so there are two of
# them: the template every other repo gets, and .github/workflows here. Editing
# the live one and forgetting the template ships a stale workflow everywhere
# else, and nothing would say so. They must match apart from the two values the
# installer substitutes.
python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
template = (root / "templates/github/workflows/dx-maintain.yml").read_text(encoding="utf-8")
installed = (root / ".github/workflows/dx-maintain.yml").read_text(encoding="utf-8")

# Undo the substitution the installer makes, then the two must be identical.
normalized = re.sub(r"(?m)^(  DEX_REPO:) .*$", r"\1 __DEX_REPO__", installed)
normalized = re.sub(r"(?m)^(  DEX_REF:) .*$", r"\1 __DEX_REF__", normalized)
if normalized != template:
    import difflib

    print(
        "templates/github/workflows/dx-maintain.yml and .github/workflows/dx-maintain.yml\n"
        "differ by more than the substituted DEX_REPO/DEX_REF values:",
        file=sys.stderr,
    )
    for line in difflib.unified_diff(
        template.splitlines(), normalized.splitlines(), "template", "installed", n=2, lineterm=""
    ):
        print(line, file=sys.stderr)
    raise SystemExit(1)
print("maintenance workflow template matches the installed copy")
PY

linked_repo="$TMP_DIR/linked-repo"
linked_target="$TMP_DIR/linked-target"
mkdir -p "$linked_repo/.dex" "$linked_target"
printf '# Dex context\n' > "$linked_repo/.dex/dex.md"
ln -s "$linked_target" "$linked_repo/.github"
if dx_maintenance_install_workflow "$linked_repo" > "$TMP_DIR/linked-workflow.out" 2>&1; then
  printf 'linked .github workflow install unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "linked .github path" "$TMP_DIR/linked-workflow.out"
[[ ! -e "$linked_target/workflows/dx-maintain.yml" ]] || assert_at $LINENO

linked_file_repo="$TMP_DIR/linked-file-repo"
mkdir -p "$linked_file_repo/.dex" "$linked_file_repo/.github/workflows"
printf '# Dex context\n' > "$linked_file_repo/.dex/dex.md"
printf 'user workflow\n' > "$TMP_DIR/user-workflow.yml"
ln -s "$TMP_DIR/user-workflow.yml" "$linked_file_repo/.github/workflows/dx-maintain.yml"
if dx_maintenance_install_workflow "$linked_file_repo" 1 > "$TMP_DIR/linked-file-workflow.out" 2>&1; then
  printf 'linked workflow file replacement unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "linked maintenance workflow file" "$TMP_DIR/linked-file-workflow.out"
assert_contains "user workflow" "$TMP_DIR/user-workflow.yml"

# CLI argument validation must fail cleanly, not crash on a missing helper
# (regression: respond/--issue once called an undefined __dx_maintain_require_number).
set +e
bash "$ROOT/bin/maintain.sh" respond --pr notanumber > "$TMP_DIR/respond-bad-pr.out" 2>&1
respond_status=$?
set -e
assert_eq "1" "$respond_status" "respond --pr notanumber exit status"
assert_contains "requires a positive integer" "$TMP_DIR/respond-bad-pr.out"

set +e
bash "$ROOT/bin/maintain.sh" --issue notanumber > "$TMP_DIR/run-bad-issue.out" 2>&1
issue_status=$?
set -e
assert_eq "1" "$issue_status" "--issue notanumber exit status"
assert_contains "requires a positive integer" "$TMP_DIR/run-bad-issue.out"

# Every __dx_maintain_* helper invoked in maintain.sh must be defined there.
undefined_helpers=$(awk '
  match($0, /__dx_maintain_[a-z_]+\(\)/) {
    name = substr($0, RSTART, RLENGTH - 2); defined[name] = 1
  }
  {
    line = $0
    while (match(line, /__dx_maintain_[a-z_]+/)) {
      name = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      if (rest !~ /^\(\)/) used[name] = 1
      line = rest
    }
  }
  END { for (name in used) if (!(name in defined)) print name }
' "$ROOT/bin/maintain.sh")
if [[ -n "$undefined_helpers" ]]; then
  printf 'undefined __dx_maintain_ helpers referenced in bin/maintain.sh:\n%s\n' "$undefined_helpers" >&2
  exit 1
fi

# The branch name reaches `git checkout -B` in the credentialed publish step,
# after the agent process has written it into state. Its second check used to
# discard its own result, so every shape below was accepted.
eval "$(sed -n '/^__dx_maintain_validate_branch_name()/,/^}/p' "$ROOT/bin/maintain.sh")"
branch_accepts() {
  local branch="$1"
  __dx_maintain_validate_branch_name "$branch" \
    || fail "expected the branch name to be accepted: $branch"
}
branch_rejects() {
  local branch="$1"
  if __dx_maintain_validate_branch_name "$branch"; then
    fail "expected the branch name to be rejected: $branch"
  fi
}
branch_accepts "dex/maintain-docs-refresh"
branch_accepts "maintain-plain"
branch_rejects "../../maintain-escape"
branch_rejects "/abs/maintain-x"
branch_rejects "a/./maintain-y"
branch_rejects "dex/maintain-z.lock"
branch_rejects "dex/maintain-a..b"
branch_rejects "dex/not-the-prefix"
branch_rejects 'dex/maintain-$(id)'
branch_rejects ""

# The worktree preparers had no coverage either, and they are where a bad
# branch name or run id would otherwise reach `git worktree add`. These run
# before the git stub below is installed, because they need the real git.
# shellcheck disable=SC1091
source "$ROOT/bin/maintain.sh"

wt_repo="$TMP_DIR/wt-repo"
git init -q -b main "$wt_repo"
git -C "$wt_repo" config user.email test@example.com
git -C "$wt_repo" config user.name Test
git -C "$wt_repo" commit --allow-empty -qm "base"
wt_base_sha="$(git -C "$wt_repo" rev-parse HEAD)"
wt_run_id="maintain-20260807T120000Z-test-u-12345678"

assert_prepared() {
  local label="$1" dir="$2" branch="$3" sha="$4"
  [[ -d "$dir" ]] || { printf '%s: no worktree at %s\n' "$label" "$dir" >&2; exit 1; }
  local head branch_now
  head="$(git -C "$dir" rev-parse HEAD)"
  branch_now="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
  assert_eq "$sha" "$head" "$label head"
  assert_eq "$branch" "$branch_now" "$label branch"
  # A linked worktree has a .git *file* pointing at its gitdir, where a plain
  # clone has a directory. Comparing paths instead would compare /var against
  # /private/var on macOS.
  [[ -f "$dir/.git" ]] || {
    printf '%s: %s is not a linked worktree\n' "$label" "$dir" >&2
    exit 1
  }
  # Resolve the repo path: macOS reports /private/var where mktemp said /var.
  assert_eq "$(cd "$wt_repo" && pwd -P)/.git" \
    "$(git -C "$dir" rev-parse --git-common-dir)" "$label shares the repo"
}

publish_dir="$(__dx_maintain_prepare_publish_worktree \
  "$wt_repo" "dex/maintain-publish" "$wt_base_sha" "$wt_run_id")"
assert_prepared "publish worktree" "$publish_dir" "dex/maintain-publish" "$wt_base_sha"
assert_eq "${wt_run_id}-publish" "$(basename "$publish_dir")" "publish worktree name"

response_dir="$(__dx_maintain_prepare_response_worktree \
  "$wt_repo" "dex/maintain-respond" "$wt_base_sha" "$wt_run_id")"
assert_prepared "response worktree" "$response_dir" "dex/maintain-respond" "$wt_base_sha"
assert_eq "${wt_run_id}-respond" "$(basename "$response_dir")" "response worktree name"

# The temp variant puts its worktree under a fresh mktemp parent rather than in
# the repo, which is why it needs no collision check of its own.
temp_dir="$(__dx_maintain_prepare_response_temp_worktree \
  "$wt_repo" "dex/maintain-temp" "$wt_base_sha" "$wt_run_id")"
assert_prepared "temp response worktree" "$temp_dir" "dex/maintain-temp" "$wt_base_sha"
case "$temp_dir" in
  "$wt_repo"/*)
    printf 'the temp response worktree was created inside the repo: %s\n' "$temp_dir" >&2
    exit 1
    ;;
esac

# A branch name or run id that did not pass validation must never reach
# `git worktree add`, which would happily create the path it names.
for bad_branch in "../../escape" "/abs/x" "dex/maintain-a..b" 'dex/maintain-$(id)' ""; do
  assert_rejected "$LINENO" __dx_maintain_prepare_publish_worktree \
    "$wt_repo" "$bad_branch" "$wt_base_sha" "$wt_run_id" >/dev/null 2>&1
  assert_rejected "$LINENO" __dx_maintain_prepare_response_worktree \
    "$wt_repo" "$bad_branch" "$wt_base_sha" "$wt_run_id" >/dev/null 2>&1
  assert_rejected "$LINENO" __dx_maintain_prepare_response_temp_worktree \
    "$wt_repo" "$bad_branch" "$wt_base_sha" "$wt_run_id" >/dev/null 2>&1
done
for bad_run_id in "../escape" "has space" 'x$(id)' ""; do
  assert_rejected "$LINENO" __dx_maintain_prepare_publish_worktree \
    "$wt_repo" "dex/maintain-ok" "$wt_base_sha" "$bad_run_id" >/dev/null 2>&1
  assert_rejected "$LINENO" __dx_maintain_prepare_response_temp_worktree \
    "$wt_repo" "dex/maintain-ok" "$wt_base_sha" "$bad_run_id" >/dev/null 2>&1
done

# An existing path is refused rather than reused, so two runs cannot land in
# one worktree.
assert_rejected "$LINENO" __dx_maintain_prepare_publish_worktree \
  "$wt_repo" "dex/maintain-publish" "$wt_base_sha" "$wt_run_id" >/dev/null 2>&1

# The GitHub token that `dx maintain` pushes and fetches with had no coverage
# at all, and it is the part worth covering: it must reach git through an
# askpass file and nowhere else — not argv, where any local process can read it
# from ps, and not the environment of the child, which git subprocesses inherit.
maintain_git_log="$TMP_DIR/maintain-git.log"
cat > "$TMP_DIR/bin/git" <<'GITSTUB'
#!/usr/bin/env bash
# Record what the real git would have been handed, then answer the askpass the
# way a credential prompt would.
{
  printf 'argv\t%s\n' "$*"
  printf 'env\tGH_TOKEN=%s\n' "${GH_TOKEN-<unset>}"
  printf 'env\tGITHUB_TOKEN=%s\n' "${GITHUB_TOKEN-<unset>}"
  printf 'env\tDX_MAINTAIN_TOKEN=%s\n' "${DX_MAINTAIN_TOKEN-<unset>}"
  printf 'env\tGIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-<unset>}"
  # Key off Dex's own token file, not GIT_ASKPASS: editors set GIT_ASKPASS in
  # the ambient environment, so its presence says nothing about what Dex did.
  printf 'token-file\t%s\n' "${DX_MAINTAIN_TOKEN_FILE-<unset>}"
  if [[ -n "${DX_MAINTAIN_TOKEN_FILE:-}" && -n "${GIT_ASKPASS:-}" && -x "${GIT_ASKPASS}" ]]; then
    printf 'askpass-user\t%s\n' "$("$GIT_ASKPASS" 'Username for https://github.com: ')"
    printf 'askpass-pass\t%s\n' "$("$GIT_ASKPASS" 'Password for https://github.com: ')"
    printf 'askpass-mode\t%s\n' "$(bash -c 'source "$DEX_DIR/lib/common.sh"; dx_path_mode "$1"' \
      _ "$DX_MAINTAIN_TOKEN_FILE" 2>/dev/null || echo '?')"
    printf 'askpass-script\t%s\n' "$GIT_ASKPASS"
  fi
} >> "$DX_TEST_GIT_LOG"
exit "${DX_TEST_GIT_EXIT:-0}"
GITSTUB
chmod +x "$TMP_DIR/bin/git"
export DX_TEST_GIT_LOG="$maintain_git_log"
# The repo fixture above already ran the real git, so bash has its path cached.
# The token path calls git through `env`, which looks it up afresh and finds the
# stub; the no-token path calls it directly and would reach the real one.
hash -r

: > "$maintain_git_log"
DX_MAINTAIN_TOKEN="ghp_maintaintokenmaintaintokenmaintain" \
DX_MAINTAIN_REPO="example/repo" \
  __dx_maintain_push_branch "$repo" "dex/maintain-cover"

assert_contains "push --set-upstream https://github.com/example/repo.git dex/maintain-cover" "$maintain_git_log"
assert_contains "askpass-user	x-access-token" "$maintain_git_log"
assert_contains "askpass-pass	ghp_maintaintokenmaintaintokenmaintain" "$maintain_git_log"
assert_contains "askpass-mode	600" "$maintain_git_log"
# Unset for the child, so a git subprocess cannot pick them up.
assert_contains "GH_TOKEN=<unset>" "$maintain_git_log"
assert_contains "GITHUB_TOKEN=<unset>" "$maintain_git_log"
assert_contains "DX_MAINTAIN_TOKEN=<unset>" "$maintain_git_log"
assert_contains "GIT_TERMINAL_PROMPT=0" "$maintain_git_log"
if grep -Fq 'ghp_maintaintoken' <<< "$(grep -F 'argv' "$maintain_git_log")"; then
  printf 'the GitHub token reached git argv:\n' >&2
  grep -F 'argv' "$maintain_git_log" >&2
  exit 1
fi
# Both scratch files are gone once the call returns.
while IFS=$'\t' read -r key value; do
  case "$key" in
    askpass-script|token-file)
      [[ ! -e "$value" ]] || {
        printf 'maintain left a credential scratch file behind: %s\n' "$value" >&2
        exit 1
      }
      ;;
  esac
done < "$maintain_git_log"

# git's status is the function's status — a failed push must not read as one
# that worked.
: > "$maintain_git_log"
push_status=0
DX_TEST_GIT_EXIT=7 DX_MAINTAIN_TOKEN="ghp_maintaintokenmaintaintokenmaintain" \
DX_MAINTAIN_REPO="example/repo" \
  __dx_maintain_push_branch "$repo" "dex/maintain-cover" || push_status=$?
assert_eq "7" "$push_status" "push reports git's status"

# Fetch travels the same road.
: > "$maintain_git_log"
DX_MAINTAIN_TOKEN="ghp_maintaintokenmaintaintokenmaintain" \
DX_MAINTAIN_REPO="example/repo" \
  __dx_maintain_fetch_branch "$repo" "dex/maintain-cover"
assert_contains "fetch https://github.com/example/repo.git dex/maintain-cover" "$maintain_git_log"
assert_contains "askpass-pass	ghp_maintaintokenmaintaintokenmaintain" "$maintain_git_log"
if grep -Fq 'ghp_maintaintoken' <<< "$(grep -F 'argv' "$maintain_git_log")"; then
  printf 'the GitHub token reached git argv on the fetch path\n' >&2
  exit 1
fi

# Without a token there is no askpass and no scratch file at all.
: > "$maintain_git_log"
DX_MAINTAIN_TOKEN="" DX_MAINTAIN_REPO="" \
  __dx_maintain_fetch_branch "$repo" "dex/maintain-cover"
assert_contains "fetch origin dex/maintain-cover" "$maintain_git_log"
assert_contains "token-file	<unset>" "$maintain_git_log"

printf 'maintenance tests passed\n'
