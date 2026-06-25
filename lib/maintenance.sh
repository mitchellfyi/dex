# shellcheck shell=bash
# Dex shared library — background maintenance helpers.

DX_MAINTENANCE_DIR="${DX_MAINTENANCE_DIR:-$HOME/.claude/.dex-maintenance}"
dx_maintenance_session_id() {
  dx_scoped_session_id "maintenance"
}

dx_maintenance_sanitize_id_component() {
  local value="$1"
  value=$(printf '%s' "$value" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
  while [[ "$value" == *".."* ]]; do
    value="${value//../.}"
  done
  while [[ "$value" == .* ]]; do
    value="${value#.}"
  done
  while [[ "$value" == *[-.] ]]; do
    value="${value%[-.]}"
  done
  printf '%s\n' "${value:-x}"
}

dx_maintenance_validate_run_id() {
  local run_id="$1"
  [[ -n "$run_id" ]] || return 1
  [[ "$run_id" == maintain-* ]] || return 1
  [[ "$run_id" != *".."* ]] || return 1
  [[ "$run_id" != *"/"* ]] || return 1
  [[ "$run_id" != *$'\n'* && "$run_id" != *$'\r'* && "$run_id" != *$'\t'* ]] || return 1
  [[ "$run_id" =~ ^[A-Za-z0-9._-]+$ ]]
}

dx_maintenance_run_id() {
  local random_part run_id sha suffix timestamp
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
  sha=$(dx_maintenance_sanitize_id_component "$sha")
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    suffix="gh-$(dx_maintenance_sanitize_id_component "$GITHUB_RUN_ID")-$(dx_maintenance_sanitize_id_component "${GITHUB_RUN_ATTEMPT:-1}")"
  elif command -v python3 >/dev/null 2>&1; then
    random_part=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:8])')
    suffix="u-${random_part}"
  else
    random_part=$(mktemp -u "maintain.XXXXXXXX" 2>/dev/null || echo "$$_${RANDOM}")
    suffix="tmp-$(dx_maintenance_sanitize_id_component "${random_part##*.}")"
  fi
  run_id="maintain-${timestamp}-${sha}-${suffix}"
  if ! dx_maintenance_validate_run_id "$run_id"; then
    run_id="maintain-${timestamp}-no-git-fallback"
  fi
  printf '%s\n' "$run_id"
}

dx_maintenance_lock_ttl_seconds() {
  local ttl="${DEX_MAINTAIN_LOCK_TTL_SECONDS:-21600}"
  if [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "$ttl"
  else
    echo "21600"
  fi
}

dx_maintenance_lock_file() {
  printf '%s/%s.lock\n' "$DX_MAINTENANCE_DIR" "$1"
}

dx_maintenance_last_success_file() {
  printf '%s/%s.last-success\n' "$DX_MAINTENANCE_DIR" "$1"
}

dx_maintenance_state_file() {
  printf '%s/%s.state\n' "$DX_MAINTENANCE_DIR" "$1"
}

dx_maintenance_artifact_dir() {
  dx_maintenance_validate_run_id "$1" || return 1
  printf '%s/maintenance/%s\n' "$DX_ARTIFACT_DIR" "$1"
}

dx_maintenance_report_file() {
  printf '%s/report.md\n' "$(dx_maintenance_artifact_dir "$1")"
}

dx_maintenance_config_value() {
  local repo_root="$1" key="$2" default_value="${3:-}" value
  value=$(awk -F'|' -v want="$key" '
    /^## Maintenance[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && /^\|/ {
      k = $2
      v = $3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == want) {
        print v
        exit
      }
    }
  ' "$repo_root/.dex/dex.md" 2>/dev/null || true)
  if [[ -n "$value" && "$value" != "Value" && "$value" != "---" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

dx_maintenance_event_mode() {
  local repo_root="$1" event_name="${2:-}" explicit_mode="${3:-}" mode
  if [[ -n "$explicit_mode" ]]; then
    printf '%s\n' "$explicit_mode"
    return 0
  fi

  case "$event_name" in
    issues)
      mode=$(dx_maintenance_config_value "$repo_root" "issue_mode" "")
      ;;
    schedule)
      mode=$(dx_maintenance_config_value "$repo_root" "schedule_mode" "")
      ;;
    *)
      mode=""
      ;;
  esac
  if [[ -z "$mode" ]]; then
    mode=$(dx_maintenance_config_value "$repo_root" "default_mode" "report")
  fi
  case "$mode" in
    report|propose|fix-scoped)
      printf '%s\n' "$mode"
      ;;
    *)
      printf '%s\n' "report"
      ;;
  esac
}

dx_maintenance_lock_acquire() {
  local session_id="$1" owner="${2:-$$}" lock_file raw epoch now age ttl
  [[ -n "$session_id" ]] || return 1
  mkdir -p "$DX_MAINTENANCE_DIR"
  lock_file=$(dx_maintenance_lock_file "$session_id")

  if ( set -C; printf '%s\t%s\t%s\n' "$(date +%s)" "$$" "$owner" > "$lock_file" ) 2>/dev/null; then
    return 0
  fi

  now=$(date +%s)
  ttl=$(dx_maintenance_lock_ttl_seconds)

  if [[ -f "$lock_file" ]]; then
    raw=$(cat "$lock_file" 2>/dev/null || echo "")
    epoch="${raw%%$'\t'*}"
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then
      age=$((now - epoch))
      if [[ "$age" -lt "$ttl" ]]; then
        return 1
      fi
    fi
  fi

  rm -f "$lock_file" 2>/dev/null || true
  ( set -C; printf '%s\t%s\t%s\n' "$(date +%s)" "$$" "$owner" > "$lock_file" ) 2>/dev/null
}

dx_maintenance_lock_release() {
  local session_id="$1" owner="${2:-}" lock_file raw current_owner
  [[ -n "$session_id" ]] || return 0
  lock_file=$(dx_maintenance_lock_file "$session_id")
  if [[ -n "$owner" && -f "$lock_file" ]]; then
    raw=$(cat "$lock_file" 2>/dev/null || echo "")
    current_owner="${raw##*$'\t'}"
    [[ "$current_owner" == "$owner" ]] || return 0
  fi
  rm -f "$lock_file" 2>/dev/null || true
}

dx_maintenance_write_last_success() {
  local session_id="$1" run_id="$2" ref target tmp_file
  [[ -n "$session_id" && -n "$run_id" ]] || return 1
  dx_maintenance_validate_run_id "$run_id" || return 1
  mkdir -p "$DX_MAINTENANCE_DIR"
  ref=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  target=$(dx_maintenance_last_success_file "$session_id")
  tmp_file="${target}.tmp.$$"
  printf 'run_id=%s\nref=%s\nepoch=%s\n' "$run_id" "$ref" "$(date +%s)" > "$tmp_file"
  mv "$tmp_file" "$target"
}

dx_maintenance_workflow_template() {
  printf '%s/templates/github/workflows/dx-maintain.yml\n' "$DEX_DIR"
}

dx_maintenance_source_repo() {
  local override="${DEX_MAINTAIN_SOURCE_REPO:-}" remote repo
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  remote=$(git -C "$DEX_DIR" remote get-url origin 2>/dev/null || echo "")
  case "$remote" in
    https://github.com/*/*.git)
      repo="${remote#https://github.com/}"
      printf '%s\n' "${repo%.git}"
      ;;
    https://github.com/*/*)
      printf '%s\n' "${remote#https://github.com/}"
      ;;
    git@github.com:*/*.git)
      repo="${remote#git@github.com:}"
      printf '%s\n' "${repo%.git}"
      ;;
    git@github.com:*/*)
      printf '%s\n' "${remote#git@github.com:}"
      ;;
    *)
      printf '%s\n' "mitchellfyi/dex"
      ;;
  esac
}

dx_maintenance_source_ref_fetchable() {
  local source_repo="$1" ref="$2" remote_url
  [[ -n "$source_repo" && -n "$ref" ]] || return 1
  case "$ref" in
    *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*'~'*|*'^'*|*':'*|*'?'*|*'['*|*\\*)
      return 1
      ;;
  esac
  remote_url="https://github.com/${source_repo}.git"
  if [[ "$ref" =~ ^[0-9A-Fa-f]{40,64}$ ]]; then
    git ls-remote "$remote_url" 2>/dev/null | awk -v want="$ref" '$1 == want { found = 1 } END { exit found ? 0 : 1 }'
    return $?
  fi
  git ls-remote --exit-code "$remote_url" "$ref" >/dev/null 2>&1 ||
    git ls-remote --exit-code "$remote_url" "refs/heads/${ref}" >/dev/null 2>&1 ||
    git ls-remote --exit-code "$remote_url" "refs/tags/${ref}" >/dev/null 2>&1
}

dx_maintenance_source_ref() {
  local source_repo="${1:-}" override="${DEX_MAINTAIN_SOURCE_REF:-}" ref tag
  [[ -n "$source_repo" ]] || source_repo=$(dx_maintenance_source_repo)
  if [[ -n "$override" ]]; then
    if ! dx_maintenance_source_ref_fetchable "$source_repo" "$override"; then
      dx_error "DX maintain source ref is not fetchable from ${source_repo}: ${override}"
      return 1
    fi
    printf '%s\n' "$override"
    return 0
  fi

  ref=$(git -C "$DEX_DIR" branch --show-current 2>/dev/null || echo "")
  if [[ -n "$ref" ]] && dx_maintenance_source_ref_fetchable "$source_repo" "$ref"; then
    printf '%s\n' "$ref"
    return 0
  fi
  tag=$(git -C "$DEX_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo "")
  if [[ -n "$tag" ]] && dx_maintenance_source_ref_fetchable "$source_repo" "$tag"; then
    printf '%s\n' "$tag"
    return 0
  fi
  if dx_maintenance_source_ref_fetchable "$source_repo" "main"; then
    printf '%s\n' "main"
    return 0
  fi
  if dx_maintenance_source_ref_fetchable "$source_repo" "master"; then
    printf '%s\n' "master"
    return 0
  fi
  dx_error "Could not choose a fetchable DX maintain source ref from ${source_repo}."
  dx_info "Set DEX_MAINTAIN_SOURCE_REF to a pushed branch, tag, or advertised SHA."
  return 1
}

dx_maintenance_install_workflow() {
  local repo_root="$1" force="${2:-0}" template target target_dir tmp_file source_repo source_ref
  [[ -n "$repo_root" ]] || return 1
  template=$(dx_maintenance_workflow_template)
  target_dir="$repo_root/.github/workflows"
  target="$target_dir/dx-maintain.yml"

  if [[ ! -f "$template" ]]; then
    dx_error "DX maintain workflow template not found: $template"
    return 1
  fi
  if [[ ! -f "$repo_root/.dex/dex.md" ]]; then
    dx_error "DX maintain workflow requires Dex project context."
    dx_info "Run 'dx init --install-maintenance-workflow' or 'dx init' before installing the maintenance workflow."
    return 1
  fi

  mkdir -p "$target_dir"
  source_repo=$(dx_maintenance_source_repo)
  source_ref=$(dx_maintenance_source_ref "$source_repo") || return 1
  tmp_file="${target}.tmp.$$"
  python3 - "$template" "$tmp_file" "$source_repo" "$source_ref" <<'PY'
import sys
from pathlib import Path

template = Path(sys.argv[1])
target = Path(sys.argv[2])
source_repo = sys.argv[3]
source_ref = sys.argv[4]

content = template.read_text(encoding="utf-8")
content = content.replace("__DEX_REPO__", source_repo)
content = content.replace("__DEX_REF__", source_ref)
target.write_text(content, encoding="utf-8")
PY

  if [[ -f "$target" ]]; then
    if cmp -s "$tmp_file" "$target"; then
      rm -f "$tmp_file"
      dx_ok ".github/workflows/dx-maintain.yml already up to date"
      return 0
    fi
    if [[ "$force" != "1" ]]; then
      rm -f "$tmp_file"
      dx_error ".github/workflows/dx-maintain.yml already exists and differs."
      dx_info "Run 'dx maintain install-workflow --force' to replace it."
      return 1
    fi
  fi

  mv "$tmp_file" "$target"
  dx_done "Installed .github/workflows/dx-maintain.yml"
  dx_info "Pinned Dex source: ${source_repo}@${source_ref}"
}

dx_maintenance_normalize_reviewer() {
  local handle="$1" lower stripped
  stripped="${handle#@}"
  lower=$(printf '%s' "$stripped" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    copilot|github-copilot|github-copilot-review)
      printf '%s\n' "@copilot"
      ;;
    *)
      printf '%s\n' "$stripped"
      ;;
  esac
}

dx_maintenance_review_request_is_unavailable() {
  local output="$1"
  case "$output" in
    *"Reviews may only be requested from collaborators"*|\
    *"not a collaborator"*|\
    *"Could not resolve to a node"*|\
    *"Could not resolve to a User"*|\
    *"not a user, team, or app"*|\
    *"Review cannot be requested from pull request author"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

dx_maintenance_review_request_persisted() {
  local pr_num="${1:-}" reviewer="${2:-}" repo="${3:-}" api_repo response
  [[ -n "$pr_num" && -n "$reviewer" ]] || return 3

  api_repo="$repo"
  if [[ -z "$api_repo" ]]; then
    api_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || return 3
  fi
  [[ -n "$api_repo" ]] || return 3

  response=$(gh api "repos/${api_repo}/pulls/${pr_num}" 2>/dev/null) || return 3
  DX_REVIEWER_HANDLE="$reviewer" python3 - "$response" <<'PY'
import json
import os
import sys

COPILOT_ALIASES = {"copilot", "github-copilot", "github-copilot-review", "github-copilot[bot]"}


def normalize(value):
    value = str(value or "").strip()
    value = value[1:] if value.startswith("@") else value
    value = value.lower()
    return "copilot" if value in COPILOT_ALIASES else value


try:
    payload = json.loads(sys.argv[1])
except (IndexError, json.JSONDecodeError):
    raise SystemExit(3)

reviewer = normalize(os.environ.get("DX_REVIEWER_HANDLE", ""))
if not reviewer:
    raise SystemExit(3)

author = normalize((payload.get("user") or {}).get("login", ""))
if author and reviewer == author:
    raise SystemExit(10)

requested_users = {
    normalize(item.get("login", ""))
    for item in payload.get("requested_reviewers") or []
    if isinstance(item, dict)
}
requested_teams = {
    normalize(item.get("slug", ""))
    for item in payload.get("requested_teams") or []
    if isinstance(item, dict)
}

team_candidate = normalize(reviewer.rsplit("/", 1)[-1])
if reviewer in requested_users or reviewer in requested_teams or team_candidate in requested_teams:
    raise SystemExit(0)
if reviewer == "copilot" and requested_users.intersection(COPILOT_ALIASES):
    raise SystemExit(0)

raise SystemExit(11)
PY
}

dx_maintenance_request_reviewer() {
  local pr_num="${1:-}" handle="${2:-}" repo="${3:-}" reviewer output command_status
  local gh_args

  if [[ -z "$pr_num" || -z "$handle" ]]; then
    dx_error "Usage: dx_maintenance_request_reviewer <pr-number> <reviewer> [repo]"
    return 2
  fi

  case "$handle" in
    _none_|Handle|-|--|"") return 0 ;;
  esac

  reviewer=$(dx_maintenance_normalize_reviewer "$handle")
  gh_args=(pr edit "$pr_num")
  if [[ -n "$repo" ]]; then
    gh_args+=(--repo "$repo")
  fi
  gh_args+=(--add-reviewer "$reviewer")

  output=$(gh "${gh_args[@]}" 2>&1) && command_status=0 || command_status=$?
  if [[ "$command_status" -eq 0 ]]; then
    dx_maintenance_review_request_persisted "$pr_num" "$reviewer" "$repo" && command_status=0 || command_status=$?
    case "$command_status" in
      0)
        return 0
        ;;
      10)
        dx_warn "Could not request reviewer ${reviewer} on PR #${pr_num}; GitHub does not allow requesting the PR author."
        return 0
        ;;
      11)
        dx_warn "Could not confirm reviewer ${reviewer} on PR #${pr_num}; GitHub accepted the command but no review request persisted."
        if [[ "$reviewer" == "@copilot" ]]; then
          dx_info "Copilot review requests may be unavailable on draft PRs or disabled for this repository."
        fi
        return 0
        ;;
      *)
        dx_warn "Could not verify reviewer ${reviewer} on PR #${pr_num} after GitHub accepted the request."
        return 0
        ;;
    esac
  fi

  if dx_maintenance_review_request_is_unavailable "$output"; then
    dx_warn "Could not request reviewer ${reviewer} on PR #${pr_num}; GitHub says that reviewer is not requestable for this repository."
    if [[ "$reviewer" == "@copilot" ]]; then
      dx_info "GitHub supports @copilot review requests only when Copilot code review is enabled and requestable for the repository."
    fi
    return 0
  fi

  dx_error "Could not request reviewer ${reviewer} on PR #${pr_num}."
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
  fi
  return "$command_status"
}
