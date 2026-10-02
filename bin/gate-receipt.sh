#!/usr/bin/env bash
set -euo pipefail

# Does a passing gate result already exist for the tree in front of us?
#
# `dx run-gate` writes a receipt keyed by the checkout and working-tree
# fingerprints and bound to an environment fingerprint, under the name the
# caller gave it (`--name`, or one derived from the command). Phase 4's job is
# the complete gate, not the complete gate twice: when Phase 2 already ran it
# and nothing has changed since — not the tree, and not the toolchain, job
# budget or manifests the gate ran with — the recorded result is the evidence.
# This is the read side of that — it runs no command, and it never claims a
# result for a tree or an environment the receipt is not about.
#
# It answers for the gates it is asked about, by name. A receipt for some other
# gate — a linter Phase 2 ran through `dx run-gate` — is not evidence for the
# complete suite, so with no name it lists what exists and answers "run it".
# Receipts are this session's by default; reading every session's receipts is
# an explicit `--all-sessions`.
#
# A reuse is journaled as `gate.reused` to this session's run, so the run
# shows where a gate was skipped on evidence rather than never run.
#
# Exit status is the answer:
#   0  every named gate has a passing receipt for this exact tree and
#      environment (reuse them)
#   1  a named gate has no such receipt, or no gate was named (run the gate)
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

if ! GATE_REPO=$(git rev-parse --show-toplevel 2>/dev/null); then
  GATE_REPO="$PWD"
fi
GATE_CHECKOUT=$(git rev-parse --verify HEAD 2>/dev/null || printf '%s\n' unborn)
if ! GATE_WORKING=$(dx_review_working_fingerprint "$PWD" 2>/dev/null); then
  dx_error "gate-receipt: could not fingerprint the working tree"
  exit 2
fi
# The environment a gate would run in now, computed the way run-gate computed
# it when it wrote the receipt: the effective job budget bound to DX_TEST_JOBS
# and the project's declared parallelism variables.
if ! GATE_ENV=$(dx_gate_env_fingerprint "$GATE_REPO" 2>/dev/null); then
  dx_error "gate-receipt: could not fingerprint the environment"
  exit 2
fi

GATE_ROWS=""
GATE_STATUS=0
GATE_ROWS=$(dx_gate_receipt_lookup "$GATE_SCOPE" "$GATE_CHECKOUT" \
  "$GATE_WORKING" "" "$GATE_ENV") || GATE_STATUS=$?
if [[ "$GATE_STATUS" -eq 2 ]]; then
  dx_error "gate-receipt: could not read gate receipts"
  exit 2
fi
[[ "$GATE_STATUS" -eq 0 ]] || GATE_ROWS=""

# Newest first, so the first row per gate is that gate's current answer. Every
# receipt for this tree and environment is printed, so a caller with no name in
# mind can see what exists — but only a named gate can turn that into "reuse".
GATE_SEEN=""
GATE_PASSED=""
GATE_FAILED_NAMES=""
GATE_ROW_GATES=()
GATE_ROW_SESSIONS=()
GATE_ROW_RECORDED=()
while IFS=$'\t' read -r row_session row_gate row_exit row_duration row_at row_command; do
  [[ -n "$row_gate" ]] || continue
  case " $GATE_SEEN " in
    *" $row_gate "*) continue ;;
  esac
  GATE_SEEN="$GATE_SEEN $row_gate"
  GATE_ROW_GATES+=("$row_gate")
  GATE_ROW_SESSIONS+=("$row_session")
  GATE_ROW_RECORDED+=("$row_at")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$row_session" "$row_gate" "$row_exit" "$row_duration" "$row_at" "$row_command"
  if [[ "$row_exit" == "0" ]]; then
    GATE_PASSED="$GATE_PASSED $row_gate"
    dx_ok "${row_gate}: passed on this exact tree and environment ($(dx_format_duration "${row_duration:-0}"), recorded ${row_at})"
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

# A named gate with no match here may still have a receipt for this tree from
# another environment — a different job budget, an upgraded interpreter, a
# moved lockfile — or from before receipts were environment-bound. Saying which
# is what makes a "run it" answer legible. One tree-only lookup covers every
# missing name.
GATE_TREE_ONLY=""
gate_tree_only_names() {
  if [[ -z "$GATE_TREE_ONLY" ]]; then
    GATE_TREE_ONLY=$(dx_gate_receipt_lookup "$GATE_SCOPE" "$GATE_CHECKOUT" \
      "$GATE_WORKING" 2>/dev/null | cut -f2 | tr '\n' ' ') || GATE_TREE_ONLY=""
    GATE_TREE_ONLY=" ${GATE_TREE_ONLY:-} "
  fi
  printf '%s' "$GATE_TREE_ONLY"
}

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
  case "$(gate_tree_only_names)" in
    *" $GATE_NAME "*)
      dx_info "A gate receipt exists for this tree (${GATE_NAME}) but from a different environment; run the gate."
      ;;
    *)
      dx_info "No gate receipt for this tree (${GATE_NAME}); run the gate."
      ;;
  esac
done
[[ "$GATE_FAILED" -eq 0 ]] || exit 3
[[ "$GATE_MISSING" -eq 0 ]] || exit 1

# Every named gate is reused on evidence. Say so in this session's run journal
# — the session doing the reusing, which with --session or --all-sessions is
# not necessarily the one whose receipt it was — so the run shows a gate that
# was skipped on a recorded pass rather than one that never ran.
GATE_EVENT_SESSION="${DEX_SESSION_ID:-$(dx_session_id 2>/dev/null || true)}"
if dx_session_id_valid "$GATE_EVENT_SESSION" 2>/dev/null; then
  for GATE_NAME in "${GATE_NAMES[@]}"; do
    GATE_ROW_INDEX=0
    while [[ "$GATE_ROW_INDEX" -lt ${#GATE_ROW_GATES[@]} ]]; do
      if [[ "${GATE_ROW_GATES[$GATE_ROW_INDEX]}" == "$GATE_NAME" ]]; then
        GATE_RECEIPT_SESSION_JSON=$(dx_event_json_string \
          "${GATE_ROW_SESSIONS[$GATE_ROW_INDEX]}" 200) || GATE_RECEIPT_SESSION_JSON='""'
        GATE_RECEIPT_AT_JSON=$(dx_event_json_string \
          "${GATE_ROW_RECORDED[$GATE_ROW_INDEX]}" 40) || GATE_RECEIPT_AT_JSON='""'
        dx_event_emit_for_session "$GATE_EVENT_SESSION" "gate.reused" "info" \
          "Heavy gate ${GATE_NAME} reused a recorded pass for this tree and environment" "" \
          "$(printf '{"gate":"%s","checkout_fingerprint":"%s","working_fingerprint":"%s","env_fingerprint":"%s","receipt_recorded_at":%s,"receipt_session":%s}' \
            "$GATE_NAME" "$GATE_CHECKOUT" "$GATE_WORKING" "$GATE_ENV" \
            "$GATE_RECEIPT_AT_JSON" "$GATE_RECEIPT_SESSION_JSON")" \
          2>/dev/null || true
        break
      fi
      GATE_ROW_INDEX=$((GATE_ROW_INDEX + 1))
    done
  done
fi
exit 0
