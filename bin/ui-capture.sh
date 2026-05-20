#!/usr/bin/env bash
# shellcheck disable=SC1091
# doyaken UI capture — Playwright-backed screenshots, traces, and videos
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  ui-capture.sh --url <url> [--name <name>] [--desktop] [--mobile] [--video] [--trace] [--flow <file>] [--wait-ms <ms>]
  ui-capture.sh --install-only

Artifacts are written to:
  ${DK_ARTIFACT_DIR:-~/.claude/.doyaken-artifacts}/ui/<session>/
USAGE
}

slugify() {
  local value="$1"
  printf '%s\n' "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-80
}

url=""
name="capture"
out_dir=""
install_only=0
runner_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-only)
      install_only=1
      shift
      ;;
    --url)
      [[ $# -ge 2 ]] || {
        dk_error "--url requires a value"
        usage
        exit 2
      }
      url="$2"
      runner_args+=("--url" "$2")
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || {
        dk_error "--name requires a value"
        usage
        exit 2
      }
      name="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || {
        dk_error "--out requires a value"
        usage
        exit 2
      }
      out_dir="$2"
      runner_args+=("--out" "$2")
      shift 2
      ;;
    --desktop|--mobile|--video|--trace)
      runner_args+=("$1")
      shift
      ;;
    --flow|--wait-ms)
      [[ $# -ge 2 ]] || {
        dk_error "$1 requires a value"
        usage
        exit 2
      }
      runner_args+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      dk_error "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if ! dk_install_ui_capture_playwright; then
  dk_error "UI capture tooling is not ready"
  exit 1
fi

mcp_failed=0
dk_install_claude_ui_mcp_servers || mcp_failed=1
dk_install_codex_ui_mcp_servers || mcp_failed=1

if [[ "$mcp_failed" -eq 1 ]]; then
  if [[ "$install_only" -eq 1 ]]; then
    dk_error "Browser MCP server setup is incomplete"
    exit 1
  fi
  dk_warn "Browser MCP server setup is incomplete; continuing with deterministic Playwright capture"
fi

if [[ "$install_only" -eq 1 ]]; then
  exit 0
fi

if [[ -z "$url" ]]; then
  dk_error "Missing required --url"
  usage
  exit 2
fi

session_id="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
run_name=$(slugify "$name")
[[ -n "$run_name" ]] || run_name="capture"

if [[ -z "$out_dir" ]]; then
  out_dir=$(dk_ui_capture_run_dir "$session_id" "$run_name")
  runner_args+=("--out" "$out_dir")
fi

abs_out_dir="$out_dir"
case "$abs_out_dir" in
  /*) ;;
  *) abs_out_dir="$(pwd)/$abs_out_dir" ;;
esac

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$repo_root" ]]; then
  case "$abs_out_dir" in
    "$repo_root"/*)
      if ! git check-ignore -q "$abs_out_dir"; then
        dk_error "UI artifact directory is inside the repo and is not ignored: $abs_out_dir"
        exit 1
      fi
      ;;
  esac
fi

mkdir -p "$out_dir"

dk_info "Capturing UI artifacts for ${url}"
capture_output=$(
  DK_UI_CAPTURE_TOOLS_DIR="$(dk_ui_capture_tools_dir)" \
    node "$DOYAKEN_DIR/scripts/ui-capture.cjs" "${runner_args[@]}"
)
printf '%s\n' "$capture_output"

manifest="$(dk_ui_capture_manifest_file "$session_id")"
mkdir -p "$(dirname "$manifest")"
if [[ ! -f "$manifest" ]]; then
  {
    printf '# Visual Evidence\n\n'
    printf 'Session: %s\n' "$session_id"
    printf 'PR: pending\n'
    printf 'Upload note: local files do not render in GitHub; upload before/after screenshots manually to the PR body or a PR comment.\n'
  } > "$manifest"
fi

{
  printf '\n## Capture: %s\n\n' "$run_name"
  printf -- "- URL: \`%s\`\n" "$url"
  printf -- '- Directory: [%s](%s)\n' "$abs_out_dir" "$abs_out_dir"
  printf '\n'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf -- '- %s\n' "$line"
  done <<< "$capture_output"
} >> "$manifest"
printf 'manifest: %s\n' "$manifest"
