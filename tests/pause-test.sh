#!/usr/bin/env bash
# dx_pause waits the requested time in bash and zsh, survives errexit, and on
# shells that can wait without forking it does so.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/helpers.sh"
cd "$TEST_DIR/.."
export DEX_DIR="$PWD"

now() { python3 -c 'import time; print(time.time())'; }
elapsed_between() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
start, end, low, high = map(float, sys.argv[1:])
elapsed = end - start
sys.exit(0 if low <= elapsed <= high else 1)
PY
}

start=$(now)
bash -c 'source "$DEX_DIR/lib/common.sh"; dx_pause 0.3; dx_pause 0.05'
end=$(now)
elapsed_between "$start" "$end" 0.3 5 || { printf 'bash: dx_pause did not wait long enough\n' >&2; exit 1; }

# An errexit caller must not exit because the wait timed out.
bash -c 'set -e; source "$DEX_DIR/lib/common.sh"; dx_pause 0.05; printf ok' | grep -q '^ok$' \
  || { printf 'bash: dx_pause aborted an errexit shell\n' >&2; exit 1; }

if bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]'; then
  # Bash 4+ keeps a pipe open and reads from it with a timeout instead of
  # forking sleep. A pipe that returned EOF would busy-loop, so the helper
  # must have proven a timeout before adopting it.
  bash -c 'source "$DEX_DIR/lib/common.sh"; dx_pause 0.05
    [[ -n "${__DX_PAUSE_FD:-}" && "$__DX_PAUSE_FD" != none ]]' \
    || { printf 'bash 4+: dx_pause fell back to sleep\n' >&2; exit 1; }
  start=$(now)
  bash -c 'source "$DEX_DIR/lib/common.sh"; for _ in 1 2 3 4 5 6 7 8 9 10; do dx_pause 0.02; done'
  end=$(now)
  elapsed_between "$start" "$end" 0.2 5 || { printf 'bash 4+: repeated waits ran short\n' >&2; exit 1; }
fi

if command -v zsh >/dev/null 2>&1; then
  start=$(now)
  zsh -fc 'source "$DEX_DIR/lib/common.sh"; dx_pause 0.3; zmodload -e zsh/zselect' \
    || { printf 'zsh: dx_pause did not use zselect\n' >&2; exit 1; }
  end=$(now)
  elapsed_between "$start" "$end" 0.3 5 || { printf 'zsh: dx_pause did not wait long enough\n' >&2; exit 1; }
  zsh -fc 'set -e; source "$DEX_DIR/lib/common.sh"; dx_pause 0.05; printf ok' | grep -q '^ok$' \
    || { printf 'zsh: dx_pause aborted an errexit shell\n' >&2; exit 1; }
fi

# The hot loops no longer fork a sleep for sub-second waits.
if grep -rnE 'sleep 0\.[0-9]+' bin lib; then
  printf 'a sub-second sleep remains in bin/ or lib/; use dx_pause\n' >&2
  exit 1
fi

printf 'pause-test: ok\n'
