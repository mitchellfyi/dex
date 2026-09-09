#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-control.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
source "$ROOT/lib/common.sh"
SID=control-review
printf '3\n' > "$(dx_state_file "$SID")"

# Operational policy can change at each decision boundary without becoming a
# pause request, including while the parent holds its acceptance lock.
dx_override_set "$SID" review.max-waves 9 phase 3 agent 'Extend the wave budget' 0
TOKEN=$(__dx_review_parent_busy_begin "$SID" 'Control fixture' 900)
dx_override_set "$SID" review.max-waves 12 phase 3 human 'Extend the live wave budget' 0
dx_override_set "$SID" control.resume requested phase 3 agent 'Record the completed resume request' 0
assert_eq '' "$(dx_lifecycle_control_snapshot "$SID")" 'overrides do not publish control'
__dx_review_parent_busy_finish "$SID" "$TOKEN"
__dx_review_parent_acceptance_lock "$SID" 0
dx_override_set "$SID" review.max-waves 15 phase 3 agent 'Extend the budget during acceptance' 0
__dx_review_parent_acceptance_unlock "$SID"
assert_no_file "$DX_LOOP_DIR/$SID.review-control.json"

for action in pause cancel resume jump complete; do
  target=""
  [[ "$action" != jump && "$action" != complete ]] || target=4
  dx_write_lifecycle_control "$SID" "$action" "$target" agent '' 3 ''
  snapshot=$(dx_lifecycle_control_snapshot "$SID")
  generation=$(dx_lifecycle_control_value "$snapshot" generation)
  for point in wave-start acceptance; do
    DECISION_RC=0
    if [[ "$point" == wave-start ]]; then
      __dx_review_parent_busy_begin "$SID" 'Pending control' 900 > "$TMP_DIR/result" 2> "$TMP_DIR/notice" || DECISION_RC=$?
    else
      __dx_review_parent_acceptance_lock "$SID" 0 > "$TMP_DIR/result" 2> "$TMP_DIR/notice" || DECISION_RC=$?
    fi
    assert_eq 2 "$DECISION_RC" 'pending control retains precedence'
    assert_eq '' "$(cat "$TMP_DIR/result")" 'control diagnostics do not pollute returned values'
    assert_eq "$snapshot" "$(dx_lifecycle_control_snapshot "$SID")" 'decision does not consume control'
    python3 - "$DX_LOOP_DIR/$SID.review-control.json" "$point" "$action" "$generation" <<'PY'
import json
import sys
from pathlib import Path
target, point, action, generation = sys.argv[1:]
data = json.loads(Path(target).read_text())
assert data["decision_point"] == point, data
assert data["action"] == action, data
assert data["source"] == "agent", data
assert data["generation"] == generation, data
assert data["reason"] == ("stop-request" if action in {"pause", "cancel"} else "transition-request"), data
PY
  done
  rm "$(dx_lifecycle_control_file "$SID")"
done

printf 'invalid\n' > "$(dx_lifecycle_control_file "$SID")"
assert_rejected 'invalid control fails closed' __dx_review_parent_acceptance_lock "$SID" 0
python3 - "$DX_LOOP_DIR/$SID.review-control.json" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1]))["reason"] == "invalid-control"
PY
dx_cleanup_session "$SID"
assert_no_file "$DX_LOOP_DIR/$SID.review-control.json"
printf 'review-control-decision tests passed\n'
