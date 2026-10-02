#!/usr/bin/env bash
# The default evaluator for research/consume.sh: deterministic and cheap.
#
#   consume-eval.sh <baseline-runtime> <candidate-runtime> <candidate-dir> <changed-paths-file>
#
# Two checks on each runtime, printed as one JSON object:
#   static        bash -n / python -m py_compile on the changed files (pass|fail|none)
#   reproduction  the candidate's reproduction/check.sh run with DEX_DIR set to
#                 the runtime (pass|fail|none), under a timeout
# A model-based scenario evaluator can replace this through consume.sh
# --evaluator; this one answers the narrow question a reproducible runtime
# bug asks: does the check fail on the baseline and pass on the candidate?
set -euo pipefail

BASELINE="$1" CANDIDATE="$2" PACKAGE="$3" CHANGED="$4"
TIMEOUT_SECONDS="${DX_CONSUME_REPRO_TIMEOUT:-120}"

static_check() {
  local runtime="$1" rel result="none"
  while IFS= read -r rel; do
    [[ -n "$rel" && -f "$runtime/$rel" ]] || continue
    case "$rel" in
      *.sh)
        result="pass"
        bash -n "$runtime/$rel" >/dev/null 2>&1 || { result="fail"; break; }
        ;;
      *.py)
        result="pass"
        python3 -m py_compile "$runtime/$rel" >/dev/null 2>&1 || { result="fail"; break; }
        ;;
      *)
        [[ "$result" == "fail" ]] || result="pass"
        ;;
    esac
  done < "$CHANGED"
  printf '%s' "$result"
}

reproduction_check() {
  local runtime="$1" check="$PACKAGE/reproduction/check.sh"
  [[ -x "$check" ]] || { printf 'none'; return 0; }
  if (cd "$runtime" && DEX_DIR="$runtime" python3 - "$check" "$TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys

try:
    completed = subprocess.run(["bash", sys.argv[1]], timeout=int(sys.argv[2]),
                               capture_output=True, text=True)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(completed.returncode)
PY
  ) >/dev/null 2>&1; then
    printf 'pass'
  else
    printf 'fail'
  fi
}

printf '{"baseline":{"static":"%s","reproduction":"%s"},"candidate":{"static":"%s","reproduction":"%s"},"evaluator":"research/consume-eval.sh"}\n' \
  "$(static_check "$BASELINE")" "$(reproduction_check "$BASELINE")" \
  "$(static_check "$CANDIDATE")" "$(reproduction_check "$CANDIDATE")"
