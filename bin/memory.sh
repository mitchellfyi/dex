#!/usr/bin/env bash
# dx memory — show, trim or critically review the repository's Dex memory store.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
__dx_require_lib memory.sh

usage() {
  cat <<'USAGE'
Usage: dx memory [--repo DIR] <command> [options]

Commands:
  show                 Print the store (entries, statuses, dependencies)
  maintain             Deterministic pass: promote corroborated candidates,
                       retire stale, idle and unused entries
  curate               Run maintain, then ask a fresh bounded model session
                       to review every entry critically and apply its decisions
  export               Print what the curator would read, with the due verdict
  land                 Write curator-promoted entries into .dex/memory on a
                       dex/memory-* branch, commit, push and open an auto-merging
                       PR (no remote: the branch stays local)

Options:
  --repo DIR           Repository to curate (default: the current checkout)
  --force              Curate even when the store did not change enough
  --dry-run            curate: ask the model but apply nothing; land: print the
                       plan and write nothing
  --in-place           land: write into the checkout instead of a branch (what
                       dx sync does before its own run publishes)
  --no-pr              land: commit on the branch but neither push nor open a PR
  --max-turns N        Model turns for the review (default 12)
  --budget-seconds N   Wall-clock cap for the review (default 600)
  --min-changes N      Changed entries that make a review due (default 5)
  --max-age-days N     Days after which one change makes a review due (default 7)
  --stale-days N       Days a needs-recheck entry waits before retiring (default 14)
  --idle-days N        Days an unseen candidate waits before retiring (default 45)
  --unused-days N      Days an unretrieved active entry waits before retiring (default 90)
  -h, --help           Show this help

Environment: DEX_MEMORY_CURATE=0 disables curation from the lifecycle,
DEX_MEMORY_LAND=0 disables landing from the lifecycle, DX_MEMORY_GH_BIN names
the GitHub CLI used for the PR (default gh),
DX_MEMORY_CURATOR_BIN names the model CLI (default claude),
DEX_MEMORY_CURATOR_MODEL selects its model, DX_MEMORY_STORE_DIR overrides
the store location.
USAGE
}

REPO=""
COMMAND=""
FORCE=0
DRY_RUN=0
IN_PLACE=0
NO_PR=0
MAX_TURNS="${DEX_MEMORY_CURATE_MAX_TURNS:-12}"
BUDGET_SECONDS="${DEX_MEMORY_CURATE_BUDGET_SECONDS:-600}"
MIN_CHANGES="${DEX_MEMORY_CURATE_MIN_CHANGES:-5}"
MAX_AGE_DAYS="${DEX_MEMORY_CURATE_MAX_AGE_DAYS:-7}"
MAINTAIN_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [[ $# -ge 2 ]] || { dx_error "--repo requires a directory"; exit 1; }; REPO="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --in-place) IN_PLACE=1; shift ;;
    --no-pr) NO_PR=1; shift ;;
    --max-turns) [[ $# -ge 2 ]] || { dx_error "--max-turns requires a number"; exit 1; }; MAX_TURNS="$2"; shift 2 ;;
    --budget-seconds) [[ $# -ge 2 ]] || { dx_error "--budget-seconds requires a number"; exit 1; }; BUDGET_SECONDS="$2"; shift 2 ;;
    --min-changes) [[ $# -ge 2 ]] || { dx_error "--min-changes requires a number"; exit 1; }; MIN_CHANGES="$2"; shift 2 ;;
    --max-age-days) [[ $# -ge 2 ]] || { dx_error "--max-age-days requires a number"; exit 1; }; MAX_AGE_DAYS="$2"; shift 2 ;;
    --stale-days|--idle-days|--unused-days)
      [[ $# -ge 2 ]] || { dx_error "$1 requires a number"; exit 1; }
      MAINTAIN_ARGS+=("$1" "$2"); shift 2 ;;
    show|maintain|curate|export|land)
      [[ -z "$COMMAND" ]] || { dx_error "One command at a time: $COMMAND and $1"; usage >&2; exit 1; }
      COMMAND="$1"; shift ;;
    -*) dx_error "Unknown memory option: $1"; usage >&2; exit 1 ;;
    *) dx_error "Unknown memory command: $1"; usage >&2; exit 1 ;;
  esac
done
[[ -n "$COMMAND" ]] || { usage >&2; exit 1; }
for value in "$MAX_TURNS" "$BUDGET_SECONDS" "$MIN_CHANGES"; do
  [[ "$value" =~ ^[1-9][0-9]{0,8}$ ]] || { dx_error "Expected a positive integer, got: $value"; exit 1; }
done

if [[ -z "$REPO" ]]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { dx_error "Not inside a git repository; pass --repo"; exit 1; }
fi
REPO=$(cd "$REPO" && pwd -P)
STORE_DIR=$(dx_memory_store_dir "$REPO") || { dx_error "Could not derive the memory store for $REPO"; exit 1; }
STORE_PY="$DEX_DIR/scripts/memory_store.py"

store() { python3 "$STORE_PY" "$STORE_DIR" "$@"; }

run_maintain() {
  store maintain --repo "$REPO" "${MAINTAIN_ARGS[@]+"${MAINTAIN_ARGS[@]}"}"
}

run_export() {
  store review-export --repo "$REPO" --min-changes "$MIN_CHANGES" --max-age-days "$MAX_AGE_DAYS"
}

plan_counts() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["landed"]), len(d["status_changes"]))' "$1"
}

plan_lines() {
  python3 - "$1" <<'PY_PLAN'
import json, sys
plan = json.load(open(sys.argv[1]))
for item in plan["landed"]:
    print(f"- {item['id']}: {item['title']} ({item['file']}; store obs:{item['store_id']})")
for change in plan["status_changes"]:
    print(f"- {change['id']}: status {change['status']} ({change['file']})")
PY_PLAN
}

plural() { [[ "$1" == 1 ]] && printf '%s' "$2" || printf '%s' "$3"; }

emit_landed_event() {
  [[ -n "${DEX_SESSION_ID:-}" ]] && command -v dx_event_emit_for_session >/dev/null 2>&1 || return 0
  dx_event_emit_for_session "$DEX_SESSION_ID" memory.landed info "Curated memory landed in the repository" \
    "${DEX_LOOP_PHASE:-}" "$(python3 -c 'import json,sys; print(json.dumps({"entries": int(sys.argv[1]), "status_changes": int(sys.argv[2]), "branch": sys.argv[3], "commit": sys.argv[4], "pr": sys.argv[5] or None}))' "$1" "$2" "$3" "$4" "$5")" \
    >/dev/null 2>&1 || true
}

# land: curator-promoted entries become tracked .dex/memory entries. The plan
# is computed against the tree it will be written to, so entry numbers never
# collide with what that tree already has.
run_land() {
  local work_dir plan_file entries changes default_branch base_ref wt branch stamp sha short_sha
  local subject body_file remote=0 pr_url="" gh_bin
  work_dir=$(mktemp -d "${DX_SESSION_TMP:-${TMPDIR:-/tmp}}/dx-memory-land.XXXXXX") || return 1
  plan_file="$work_dir/plan.json"
  if ! store materialize --repo "$REPO" --out-repo "$REPO" > "$plan_file"; then
    dx_error "Memory: could not plan the landing."
    rm -rf "$work_dir"
    return 1
  fi
  read -r entries changes < <(plan_counts "$plan_file")
  if [[ "$entries" == 0 && "$changes" == 0 ]]; then
    dx_info "Memory: nothing to land."
    rm -rf "$work_dir"
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    dx_info "Memory landing dry run: would land ${entries} $(plural "$entries" entry entries) and ${changes} status $(plural "$changes" change changes); nothing written."
    plan_lines "$plan_file"
    cat "$plan_file"
    rm -rf "$work_dir"
    return 0
  fi
  if [[ "$IN_PLACE" == 1 ]]; then
    store materialize --repo "$REPO" --out-repo "$REPO" --write > "$plan_file" || { rm -rf "$work_dir"; return 1; }
    store mark-landed --commit working-tree "$plan_file" > /dev/null || { rm -rf "$work_dir"; return 1; }
    dx_done "Memory: landed ${entries} $(plural "$entries" entry entries) and ${changes} status $(plural "$changes" change changes) into the checkout; the run that publishes this tree carries them."
    plan_lines "$plan_file"
    rm -rf "$work_dir"
    return 0
  fi

  default_branch=$(dx_default_branch "$REPO" 2>/dev/null) || default_branch=""
  if [[ -z "$default_branch" ]]; then
    dx_error "Memory: could not resolve the default branch of $REPO."
    rm -rf "$work_dir"
    return 1
  fi
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    remote=1
    git -C "$REPO" fetch -q origin "$default_branch" >/dev/null 2>&1 || true
  fi
  base_ref=$(dx_default_branch_base_ref "$REPO" "$default_branch" no-fetch 2>/dev/null) || base_ref="$default_branch"
  wt="$work_dir/wt"
  if ! git -C "$REPO" worktree add -q --detach "$wt" "$base_ref" >/dev/null 2>&1; then
    dx_error "Memory: could not create a worktree from ${base_ref}."
    rm -rf "$work_dir"
    return 1
  fi
  cleanup_wt() { git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -rf "$work_dir"; }
  if ! store materialize --repo "$REPO" --out-repo "$wt" --write > "$plan_file"; then
    dx_error "Memory: could not write the entries."
    cleanup_wt
    return 1
  fi
  read -r entries changes < <(plan_counts "$plan_file")
  if [[ "$entries" == 0 && "$changes" == 0 ]]; then
    dx_info "Memory: nothing to land on ${base_ref}."
    cleanup_wt
    return 0
  fi
  stamp=$(date -u +%Y%m%d-%H%M%S)
  branch="dex/memory-${stamp}"
  while git -C "$REPO" rev-parse --verify -q "refs/heads/${branch}" >/dev/null 2>&1; do
    branch="dex/memory-${stamp}-$RANDOM"
  done
  subject="chore(memory): land ${entries} curated memory $(plural "$entries" entry entries)"
  [[ "$entries" == 0 ]] && subject="chore(memory): update ${changes} memory entry $(plural "$changes" status statuses)"
  body_file="$work_dir/message.txt"
  {
    printf '%s\n\n' "$subject"
    printf 'Promoted by the Dex memory curator from observations verified against this repository.\n\n'
    plan_lines "$plan_file"
    printf '\nRollback: revert this commit; the store keeps the entries.\n'
  } > "$body_file"
  if ! git -C "$wt" checkout -q -b "$branch" \
    || ! git -C "$wt" add -A -- .dex/memory \
    || ! git -C "$wt" commit -q --no-gpg-sign -F "$body_file"; then
    dx_error "Memory: could not commit on ${branch}."
    cleanup_wt
    return 1
  fi
  sha=$(git -C "$wt" rev-parse HEAD)
  short_sha=${sha:0:10}
  if [[ "$remote" == 1 && "$NO_PR" == 0 ]]; then
    if git -C "$wt" push -q -u origin "$branch" >/dev/null 2>&1; then
      gh_bin="${DX_MEMORY_GH_BIN:-gh}"
      if command -v "$gh_bin" >/dev/null 2>&1; then
        pr_url=$(cd "$wt" && "$gh_bin" pr create --base "$default_branch" --head "$branch" --title "$subject" --body-file "$body_file" 2>/dev/null | tail -1) || pr_url=""
        if [[ -n "$pr_url" ]]; then
          if ! (cd "$wt" && "$gh_bin" pr merge "$pr_url" --auto --squash >/dev/null 2>&1); then
            dx_warn "Memory: auto-merge was not accepted for ${pr_url}; the PR waits for the repository's checks or a merge."
          fi
        else
          dx_warn "Memory: pushed ${branch} but could not open a PR; open one from that branch."
        fi
      else
        dx_warn "Memory: pushed ${branch}; ${gh_bin} is not installed, so no PR was opened."
      fi
    else
      dx_warn "Memory: could not push ${branch}; the branch stays local."
    fi
  elif [[ "$remote" == 0 ]]; then
    dx_info "Memory: no remote; branch ${branch} is left in the repository."
  fi
  if [[ -n "$pr_url" ]]; then
    store mark-landed --commit "$sha" --pr "$pr_url" "$plan_file" > /dev/null || true
  else
    store mark-landed --commit "$sha" "$plan_file" > /dev/null || true
  fi
  cleanup_wt
  dx_done "Memory: landed ${entries} $(plural "$entries" entry entries) and ${changes} status $(plural "$changes" change changes) on ${branch} (${short_sha})${pr_url:+; PR ${pr_url}}"
  plan_lines "$plan_file" 2>/dev/null || true
  emit_landed_event "$entries" "$changes" "$branch" "$sha" "$pr_url"
  return 0
}

case "$COMMAND" in
  show)
    store show
    exit 0 ;;
  land)
    run_land
    exit $? ;;
  maintain)
    run_maintain
    exit 0 ;;
  export)
    run_export
    exit 0 ;;
esac

# curate: maintenance first, then the model only when the store earned a review.
MAINTAIN_SUMMARY=$(run_maintain) || { dx_error "Memory maintenance failed"; exit 1; }
WORK_DIR=$(mktemp -d "${DX_SESSION_TMP:-${TMPDIR:-/tmp}}/dx-memory-curate.XXXXXX") || exit 1
trap 'rm -rf "$WORK_DIR"' EXIT
EXPORT_FILE="$WORK_DIR/export.json"
run_export > "$EXPORT_FILE" || { dx_error "Could not export the memory store"; exit 1; }
DUE=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("1" if d["due"] else "0"); print(d["changed_since_curation"]); print(len(d["entries"]))' "$EXPORT_FILE")
IS_DUE=$(printf '%s\n' "$DUE" | sed -n 1p)
CHANGED=$(printf '%s\n' "$DUE" | sed -n 2p)
LIVE=$(printf '%s\n' "$DUE" | sed -n 3p)
if [[ "$IS_DUE" != 1 && "$FORCE" != 1 ]]; then
  dx_info "Memory curation not due: ${CHANGED} entries changed since the last review (threshold ${MIN_CHANGES}); ${LIVE} live entries after maintenance."
  exit 0
fi
if [[ "$LIVE" == 0 ]]; then
  dx_info "Memory store has no live entries; nothing to curate."
  exit 0
fi

CURATOR_BIN="${DX_MEMORY_CURATOR_BIN:-claude}"
if ! command -v "$CURATOR_BIN" >/dev/null 2>&1; then
  dx_warn "Memory curator CLI not found: $CURATOR_BIN. Maintenance ran; the review is skipped."
  exit 0
fi

PROMPT_FILE="$WORK_DIR/prompt.md"
{
  cat "$DEX_DIR/prompts/memory-curator.md"
  printf '\n\n# Store export\n\nRepository: %s\n\n```json\n' "$REPO"
  cat "$EXPORT_FILE"
  printf '```\n'
} > "$PROMPT_FILE"

CURATOR_ARGS=(-p --output-format text --max-turns "$MAX_TURNS"
  --allowedTools "Read,Grep,Glob"
  --disallowedTools "Edit,Write,NotebookEdit,Bash,Agent"
  --setting-sources "project,local" --strict-mcp-config)
[[ -n "${DEX_MEMORY_CURATOR_MODEL:-}" ]] && CURATOR_ARGS+=(--model "$DEX_MEMORY_CURATOR_MODEL")

ANSWER_FILE="$WORK_DIR/answer.txt"
dx_info "Memory curation: reviewing ${LIVE} live entries in a fresh read-only session (max ${MAX_TURNS} turns, ${BUDGET_SECONDS}s)."
# The timeout wrapper runs its command in the background, where a
# non-interactive shell replaces stdin with /dev/null, so the prompt is
# redirected inside the child instead of on the wrapper.
export DX_MEMORY_CURATOR_PROMPT="$PROMPT_FILE"
set +e
(
  cd "$REPO" && dx_run_with_timeout "$BUDGET_SECONDS" \
    bash -c 'exec "$@" < "$DX_MEMORY_CURATOR_PROMPT"' dx-memory-curator "$CURATOR_BIN" "${CURATOR_ARGS[@]}"
) > "$ANSWER_FILE" 2> "$WORK_DIR/answer.err"
CURATOR_RC=$?
set -e
if [[ "$CURATOR_RC" -ne 0 ]]; then
  dx_error "Memory curator exited with status ${CURATOR_RC}; the store is unchanged apart from maintenance."
  head -c 2000 "$WORK_DIR/answer.err" >&2 || true
  exit 1
fi

DECISIONS_FILE="$WORK_DIR/decisions.json"
if ! python3 - "$ANSWER_FILE" "$DECISIONS_FILE" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"```(?:json)?\s*\n(.*?)```", text, flags=re.S)
payload = None
for block in reversed(blocks):
    try:
        candidate = json.loads(block)
    except ValueError:
        continue
    if isinstance(candidate, dict) and isinstance(candidate.get("decisions"), list):
        payload = candidate
        break
if payload is None:
    sys.exit(1)
json.dump(payload, open(sys.argv[2], "w"), indent=1)
print(len(payload["decisions"]))
PY
then
  dx_error "Memory curator returned no decisions block; the store is unchanged apart from maintenance."
  exit 1
fi
PROPOSED=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["decisions"]))' "$DECISIONS_FILE")

if [[ "$DRY_RUN" == 1 ]]; then
  dx_info "Memory curation dry run: ${PROPOSED} decision(s) proposed, none applied."
  cat "$DECISIONS_FILE"
  exit 0
fi

ACTOR="curator:$(basename "$CURATOR_BIN")"
APPLY=$(store curate-apply --repo "$REPO" --actor "$ACTOR" "$DECISIONS_FILE") || {
  dx_error "Applying the curator's decisions failed; see ${STORE_DIR}/curation.log."
  exit 1
}
APPLIED=$(printf '%s' "$APPLY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["applied"]))')
REJECTED=$(printf '%s' "$APPLY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["rejected"]))')
dx_done "Memory curation applied ${APPLIED} decision(s), rejected ${REJECTED}; maintenance: ${MAINTAIN_SUMMARY}"
if [[ -n "${DEX_SESSION_ID:-}" ]] && command -v dx_event_emit_for_session >/dev/null 2>&1; then
  dx_event_emit_for_session "$DEX_SESSION_ID" memory.curated info "Memory store curated" "${DEX_LOOP_PHASE:-}" \
    "$(printf '%s' "$APPLY" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"applied": len(d["applied"]), "rejected": len(d["rejected"]), "actor": d["actor"]}))')" \
    >/dev/null 2>&1 || true
fi
exit 0
