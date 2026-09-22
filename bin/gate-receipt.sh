#!/usr/bin/env bash
set -euo pipefail

# Does a passing gate result already exist for the tree in front of us?
#
# `dx run-gate` writes a receipt keyed by the checkout and working-tree
# fingerprints, under the name the caller gave it (`--name`, or one derived
# from the command). Phase 4's job is the complete gate, not the complete gate
# twice: when Phase 2 already ran it and nothing has changed since, the
# recorded result is the evidence. This is the read side of that — it runs no
# command, and it never claims a result for a tree the receipt is not about.
#
# It answers for the gates it is asked about, by name. A receipt for some other
# gate — a linter Phase 2 ran through `dx run-gate` — is not evidence for the
# complete suite, so with no name it lists what exists and answers "run it".
# Receipts are this session's by default: another worktree on the same commit
# has the same tree but not the same environment, so reading every session's
# receipts is an explicit `--all-sessions`.
#
# Exit status is the answer:
#   0  every named gate has a passing receipt for this exact tree (reuse them)
#   1  a named gate has no receipt for this tree, or no gate was named (run
#      the gate)
#   2  bad arguments, or the fingerprints cannot be computed
#   3  a named gate's receipt for this tree records a failure (fix, do not
#      re-run and hope)

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage_line() {
  dx_error "Usage: gate-receipt.sh [--session <id> | --all-sessions] <gate-name>..."
}

GATE_SCOPE=""
GATE_NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)
      [[ $# -ge 2 ]] || { usage_line; exit 2; }
      GATE_SCOPE="$2"
      shift 2
      ;;
    --all-sessions)
      GATE_SCOPE="-"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_line
      exit 2
      ;;
    *)
      GATE_NAMES+=("$1")
      shift
      ;;
  esac
done
while [[ $# -gt 0 ]]; do
  GATE_NAMES+=("$1")
  shift
done

if [[ -z "$GATE_SCOPE" ]]; then
  GATE_SCOPE="${DEX_SESSION_ID:-$(dx_session_id)}"
fi
if [[ "$GATE_SCOPE" != "-" ]] && ! dx_session_id_valid "$GATE_SCOPE"; then
  dx_error "gate-receipt: '${GATE_SCOPE}' is not a session ID"
  exit 2
fi
for GATE_NAME in "${GATE_NAMES[@]+"${GATE_NAMES[@]}"}"; do
  dx_gate_receipt_slot "$GATE_NAME" >/dev/null 2>&1 || {
    dx_error "gate-receipt: '${GATE_NAME}' is not a gate name (A-Za-z0-9._-, starting alphanumeric, max 64)"
    exit 2
  }
done

GATE_CHECKOUT=$(git rev-parse --verify HEAD 2>/dev/null || printf '%s\n' unborn)
if ! GATE_WORKING=$(dx_review_working_fingerprint "$PWD" 2>/dev/null); then
  dx_error "gate-receipt: could not fingerprint the working tree"
  exit 2
fi

GATE_ROWS=""
GATE_STATUS=0
GATE_ROWS=$(dx_gate_receipt_lookup "$GATE_SCOPE" "$GATE_CHECKOUT" \
  "$GATE_WORKING") || GATE_STATUS=$?
if [[ "$GATE_STATUS" -eq 2 ]]; then
  dx_error "gate-receipt: could not read gate receipts"
  exit 2
fi
[[ "$GATE_STATUS" -eq 0 ]] || GATE_ROWS=""

# Newest first, so the first row per gate is that gate's current answer. Every
# receipt for this tree is printed, so a caller with no name in mind can see
# what exists — but only a named gate can turn that into "reuse".
GATE_SEEN=""
GATE_PASSED=""
GATE_FAILED_NAMES=""
while IFS=$'\t' read -r row_session row_gate row_exit row_duration row_at row_command; do
  [[ -n "$row_gate" ]] || continue
  case " $GATE_SEEN " in
    *" $row_gate "*) continue ;;
  esac
  GATE_SEEN="$GATE_SEEN $row_gate"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$row_session" "$row_gate" "$row_exit" "$row_duration" "$row_at" "$row_command"
  if [[ "$row_exit" == "0" ]]; then
    GATE_PASSED="$GATE_PASSED $row_gate"
    dx_ok "${row_gate}: passed on this exact tree ($(dx_format_duration "${row_duration:-0}"), recorded ${row_at})"
  else
    GATE_FAILED_NAMES="$GATE_FAILED_NAMES $row_gate"
    dx_error "${row_gate}: failed on this exact tree (exit ${row_exit}, recorded ${row_at})"
  fi
done <<EOF_ROWS
$GATE_ROWS
EOF_ROWS

if [[ ${#GATE_NAMES[@]} -eq 0 ]]; then
  if [[ -n "$GATE_SEEN" ]]; then
    dx_info "Name the gate you need (gate-receipt.sh <gate-name>); a receipt for another gate is not evidence for it. Run the gate."
  else
    dx_info "No gate receipt for this tree; run the gate."
  fi
  exit 1
fi

GATE_MISSING=0
GATE_FAILED=0
for GATE_NAME in "${GATE_NAMES[@]}"; do
  case " $GATE_FAILED_NAMES " in
    *" $GATE_NAME "*)
      GATE_FAILED=1
      continue
      ;;
  esac
  case " $GATE_PASSED " in
    *" $GATE_NAME "*) continue ;;
  esac
  GATE_MISSING=1
  dx_info "No gate receipt for this tree (${GATE_NAME}); run the gate."
done
[[ "$GATE_FAILED" -eq 0 ]] || exit 3
[[ "$GATE_MISSING" -eq 0 ]] || exit 1
exit 0
