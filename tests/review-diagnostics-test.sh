#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-diagnostics.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
source "$ROOT/lib/common.sh"
PARENT=diagnostic-parent
printf '{"action":"resume","source":"agent","generation":"1-2-3"}\n' > "$DX_LOOP_DIR/$PARENT.review-control.json"
printf 'outside\n' > "$TMP_DIR/outside"
for wave in 1 2 3 4 5 6; do
  CHILD="diagnostic-pass-$wave"
  printf 'CLEAN\n' > "$(dx_review_result_file "$CHILD")"
  printf 'Exact review context for wave %s.\n' "$wave" > "$(dx_review_context_file "$CHILD")"
  printf '{"wave":%s}\n' "$wave" > "$(dx_review_evidence_file "$CHILD")"
  printf '{"duration":40}\n' > "$(dx_review_metrics_file "$CHILD")"
  printf 'reason=invalid-completion-context\nsource=phase-loop\n' > "$(dx_pause_state_file "$CHILD")"
  if [[ "$wave" -eq 6 ]]; then
    rm "$(dx_review_context_file "$CHILD")"
    ln -s "$TMP_DIR/outside" "$(dx_review_context_file "$CHILD")"
  fi
  __dx_review_cleanup_pass "$PARENT" "$CHILD" completion_receipt_missing
  assert_no_file "$(dx_review_result_file "$CHILD")"
done
python3 - "$DX_LOOP_DIR/$PARENT.review-diagnostics" <<'PY'
import json
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
bundles = sorted(root.iterdir())
assert len(bundles) == 4, bundles
waves = []
for bundle in bundles:
    data = json.loads((bundle / "manifest.json").read_text())
    waves.append(int(data["child_session"].rsplit("-", 1)[1]))
    assert data["reason"] == "completion_receipt_missing", data
    assert (bundle / "review-result").read_text() == "CLEAN\n"
    assert (bundle / "parent-control.json").exists()
    assert (bundle / "review-metrics.json").exists()
    assert "completion-receipt" in data["missing"], data
    assert (bundle.stat().st_mode & 0o777) == 0o700
    for item in bundle.iterdir():
        assert not item.is_symlink(), item
        assert (item.stat().st_mode & 0o777) == 0o600, item
    if data["child_session"].endswith("-6"):
        assert "review-context" in data["errors"], data
        assert not (bundle / "review-context").exists()
assert waves == [3, 4, 5, 6], waves
PY
assert_eq outside "$(cat "$TMP_DIR/outside")" 'diagnostics never follow a child symlink'
python3 - "$DX_LOOP_DIR" "$ROOT/scripts" <<'PY'
from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[2])
import review_diagnostics as diagnostics
base = Path(sys.argv[1])
with patch.object(diagnostics.time, "time_ns", return_value=1):
    retained = diagnostics.capture(base, "diagnostic-parent", "clock-rollback", "provider_error")
assert retained.is_dir(), retained
assert len(list(retained.parent.iterdir())) == 4
(retained / "parent-control.json").write_text("changed")
try:
    diagnostics.capture(base, "diagnostic-parent", "clock-rollback", "provider_error")
except diagnostics.AcceptanceError:
    pass
else:
    raise AssertionError("changed diagnostics allowed child cleanup")
PY
dx_cleanup_session "$PARENT"
[[ ! -e "$DX_LOOP_DIR/$PARENT.review-diagnostics" ]] || assert_at "$LINENO"
printf 'review-diagnostics tests passed\n'
