#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034
DX_COMMON_MODULES="output provider"
# shellcheck disable=SC1091
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  printf '%s\n' 'Usage: dx setup [--direct|--router]' '' \
    'Choose direct native agents or optional CCR subscription routing.' \
    'CCR adds multiple accounts, quota display and model fallback within Claude Code.'
}

setup_choice="${1:-}"
case "$setup_choice" in -h|--help) usage; exit 0 ;; esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }
if [[ -z "$setup_choice" ]]; then
  if [[ ! -t 0 ]]; then
    dx_info "Direct agents are available. Run dx setup --router to add optional subscription routing."
    exit 0
  fi
  setup_saved=$(python3 - "$HOME/.dex/setup.json" <<'PY'
import json
import os
import stat
import sys
try:
    info = os.lstat(sys.argv[1])
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unsafe setup choice")
    with open(sys.argv[1], encoding="utf-8") as handle:
        print("2" if json.load(handle).get("routing") == "ccr" else "1")
except (OSError, ValueError):
    print("1")
PY
  )
  dx_info "Dex works directly with Claude Code and Codex. Optional CCR adds account pools, usage display and model fallback."
  printf '%s\n' '  1. Keep direct agents' '  2. Set up optional CCR routing'
  read -r -p "Choose [$setup_saved]: " setup_choice
  setup_choice="${setup_choice:-$setup_saved}"
  case "$setup_choice" in 2) setup_choice="--router" ;; ""|1) setup_choice="--direct" ;; *) dx_error "Choose 1 or 2."; exit 2 ;; esac
fi
case "$setup_choice" in
  --direct)
    setup_default=$(__dx_provider_json_default "$DX_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
    if [[ "$setup_default" == "ccr-subscription" ]]; then
      dx_provider_command use claude-subscription
    fi
    dx_ok "Direct agents selected. CCR can be added later with dx router setup."
    ;;
  --router)
    bash "$DEX_DIR/bin/router.sh" router setup
    dx_provider_command use ccr-subscription
    ;;
  *) usage >&2; exit 2 ;;
esac
python3 - "$HOME/.dex/setup.json" "$setup_choice" <<'PY'
import json
import os
import sys
import tempfile
file, choice = sys.argv[1:]
os.makedirs(os.path.dirname(file), mode=0o700, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(file))
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "routing": "ccr" if choice == "--router" else "direct"}, handle)
    os.replace(temporary, file)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
