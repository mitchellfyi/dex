#!/usr/bin/env bash
# Stop hook — best-effort macOS sound notification.
set -euo pipefail

play_stop_sound() {
  [[ "${DOYAKEN_STOP_SOUND:-1}" != "0" ]] || return 0
  [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]] || return 0
  command -v afplay >/dev/null 2>&1 || return 0

  local sound="${DOYAKEN_STOP_SOUND_FILE:-}"
  if [[ -z "$sound" ]]; then
    local sounds=()
    local candidate
    for candidate in /System/Library/Sounds/*.aiff /System/Library/Sounds/*.caf /Library/Sounds/*.aiff /Library/Sounds/*.caf; do
      [[ -r "$candidate" ]] && sounds+=("$candidate")
    done
    [[ ${#sounds[@]} -gt 0 ]] || return 0
    sound="${sounds[$((RANDOM % ${#sounds[@]}))]}"
  fi

  [[ -r "$sound" ]] || return 0
  (afplay "$sound" >/dev/null 2>&1 &) || true
}

play_stop_sound "$@" || true
exit 0
