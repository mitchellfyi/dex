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

if bash -c 'enable -f sleep sleep' 2>/dev/null; then
  # Where bash ships its sleep builtin, dx_pause loads it and stops forking.
  bash -c 'source "$DEX_DIR/lib/common.sh"; dx_pause 0.05; [[ "${__DX_PAUSE_SLEEP:-}" == builtin && "$(type -t sleep)" == builtin ]]' \
    || { printf 'bash: dx_pause did not adopt the loadable sleep builtin\n' >&2; exit 1; }
  start=$(now)
  bash -c 'source "$DEX_DIR/lib/common.sh"; for _ in 1 2 3 4 5 6 7 8 9 10; do dx_pause 0.02; done'
  end=$(now)
  elapsed_between "$start" "$end" 0.2 5 || { printf 'bash builtin: repeated waits ran short\n' >&2; exit 1; }
else
  bash -c 'source "$DEX_DIR/lib/common.sh"; dx_pause 0.05; [[ "${__DX_PAUSE_SLEEP:-}" == external ]]' \
    || { printf 'bash: dx_pause did not record the external fallback\n' >&2; exit 1; }
fi

# A caller that shadows sleep with a function keeps that function, builtin or not.
bash -c 'source "$DEX_DIR/lib/common.sh"; sleep() { printf shadowed; }; dx_pause 0.01' | grep -q '^shadowed$' \
  || { printf 'bash: a sleep function no longer shadows dx_pause\n' >&2; exit 1; }

# A trapped signal during a wait must run the trap normally, not abort the shell.
bash -c 'source "$DEX_DIR/lib/common.sh"; trap "printf trapped; exit 0" TERM; ( sleep 0.2; kill -TERM $$ ) & while :; do dx_pause 0.05; done' 2>/dev/null | grep -q '^trapped$' \
  || { printf 'bash: a signal during dx_pause did not reach its trap cleanly\n' >&2; exit 1; }

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
