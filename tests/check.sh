#!/usr/bin/env bash
# Static checks: shell syntax, shellcheck, Python compile, Node syntax.
#
# Usage: bash tests/check.sh
#
# Optional tools (shellcheck, node) are skipped with a notice when absent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  status=1
}

# Every bash file the repo ships. The scenario rubrics were missing from this
# list: a syntax error in one scores its scenario as failing the rubric rather
# than as broken, which is the wrong answer arriving quietly.
BASH_FILES=(
  "$ROOT"/install.sh "$ROOT"/lib/*.sh "$ROOT"/hooks/*.sh "$ROOT"/bin/*.sh
  "$ROOT"/tests/*.sh "$ROOT"/research/*.sh "$ROOT"/research/lib/*.sh
  "$ROOT"/research/review-loop/*.sh "$ROOT"/research/scenarios/*/*.sh
)

# dx.sh and the evaluation launcher are zsh; everything else must parse as bash.
if command -v zsh >/dev/null 2>&1; then
  zsh -n "$ROOT/dx.sh" || fail "zsh -n dx.sh"
  for path in "$ROOT"/research/review-loop/*.zsh; do
    [[ -f "$path" ]] || continue
    zsh -n "$path" || fail "zsh -n ${path#"$ROOT"/}"
  done
else
  printf 'SKIP zsh syntax (zsh not installed)\n'
fi

for path in "${BASH_FILES[@]}"; do
  [[ -f "$path" ]] || continue
  bash -n "$path" || fail "bash -n ${path#"$ROOT"/}"
done

if command -v shellcheck >/dev/null 2>&1; then
  # Run per-file: shellcheck is much slower on one large invocation.
  for path in "$ROOT"/dx.sh "${BASH_FILES[@]}"; do
    [[ -f "$path" ]] || continue
    shellcheck -S warning "$path" || fail "shellcheck ${path#"$ROOT"/}"
  done
else
  printf 'SKIP shellcheck (not installed)\n'
fi

if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile "$ROOT"/hooks/*.py "$ROOT"/scripts/*.py \
    || fail "python3 -m py_compile"
  # Most of Dex's Python is not in those files: it is embedded in shell
  # heredocs, where py_compile never sees it and a typo only surfaces when a
  # lifecycle reaches that line.
  python3 "$ROOT/tests/inline-python.py" || fail "inline python syntax"
  # bash 3.2 does not apply `set -e` to a failing `[[ … ]]`, so an assertion
  # written that way passes on macOS whatever it claims.
  python3 "$ROOT/tests/bare-assertions.py" || fail "bare test assertions"
  # zsh sources dx.sh and lib/, where names like `status` and `path` are
  # special. shellcheck cannot see this and the suite runs under bash, so
  # nothing else catches it.
  python3 "$ROOT/tests/zsh-reserved-names.py" || fail "zsh reserved names"
else
  printf 'SKIP python compile (python3 not installed)\n'
  printf 'SKIP inline python syntax (python3 not installed)\n'
  printf 'SKIP bare test assertions (python3 not installed)\n'
  printf 'SKIP zsh reserved names (python3 not installed)\n'
fi

if command -v node >/dev/null 2>&1; then
  node --check "$ROOT/scripts/ui-capture.cjs" || fail "node --check scripts/ui-capture.cjs"
else
  printf 'SKIP node syntax (node not installed)\n'
fi

if [[ $status -eq 0 ]]; then
  printf 'all static checks passed\n'
fi
exit "$status"
