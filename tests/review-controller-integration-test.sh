#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for shell_name in bash zsh; do
  # The child shell expands DEX_DIR after it inherits the scoped environment.
  # shellcheck disable=SC2016
  DEX_DIR="$ROOT" "$shell_name" -c '
    set -eu
    source "$DEX_DIR/lib/common.sh"
    command -v dx_review_transition >/dev/null
    command -v dx_review_findings_history_append >/dev/null
  '
done

# The child zsh inspects the function loaded from this checkout.
# shellcheck disable=SC2016
DEX_DIR="$ROOT" zsh -fc '
  source "$DEX_DIR/dx.sh"
  function_body=$(functions dxreviewloop)
  [[ "$function_body" == *"dx_review_transition"* ]]
'

printf 'review-controller-integration-test passed\n'
