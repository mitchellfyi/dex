#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

for shell_name in bash zsh; do
  # The child shell expands DEX_DIR after it inherits the scoped environment.
  # shellcheck disable=SC2016
  DEX_DIR="$ROOT" "$shell_name" -c '
    set -eu
    source "$DEX_DIR/lib/common.sh"
    command -v dx_review_transition >/dev/null
    command -v dx_review_findings_history_append >/dev/null
    preview_dir=$(mktemp -d)
    trap "rm -rf \"$preview_dir\"" EXIT
    history_file="$preview_dir/history"
    [[ "$(dx_review_findings_history_preview "$history_file" 1111111111111111)" == none ]] || exit 1
    [[ ! -e "$history_file" ]] || exit 1
    dx_review_findings_history_append "$history_file" 1111111111111111
    dx_review_findings_history_append "$history_file" 1111111111111111
    [[ "$(dx_review_findings_history_preview "$history_file" 1111111111111111)" == repeated_fingerprint ]] || exit 1
    [[ "$(wc -l < "$history_file" | tr -d " ")" == 2 ]] || exit 1
    printf "%s\n" 1111111111111111 2222222222222222 1111111111111111 > "$history_file"
    [[ "$(dx_review_findings_history_preview "$history_file" 2222222222222222)" == alternating_fingerprints ]] || exit 1
    [[ "$(wc -l < "$history_file" | tr -d " ")" == 3 ]] || exit 1
  '
done

# The child zsh inspects the functions loaded from this checkout. dxreviewloop
# is a thin wrapper in dx.sh; the loop itself is dx_review_loop_run in
# lib/review-loop.sh, and that is what has to reach the controller.
# shellcheck disable=SC2016
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  wrapper_body=$(functions dxreviewloop)
  [[ "$wrapper_body" == *"dx_review_loop_run"* ]] || assert_at $LINENO
  loop_body=$(functions dx_review_loop_run)
  [[ "$loop_body" == *"dx_review_transition"* ]] || assert_at $LINENO
'

printf 'review-controller-integration-test passed\n'
