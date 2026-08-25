#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-evidence-v3-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"


REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config user.email "dex-test@example.com"
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "test: initialize evidence fixture"

SESSION_ID="$(cd "$REPO" && dx_session_id)"
PASS_ID="evidence-v3-pass-1"
CRITERIA_FILE="$(dx_review_criteria_file "$SESSION_ID")"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Keep review credit pass-bound."],"acceptance_criteria":["Every requirement has auditable evidence."],"verification_requirements":["Run the focused evidence test."]}' > "$CRITERIA_FILE"
CRITERIA_BINDING="$(dx_review_criteria_hash "$CRITERIA_FILE")"
dx_review_approve_criteria "$SESSION_ID" initial "$CRITERIA_BINDING" >/dev/null
SCOPE_FINGERPRINT="$(dx_review_scope_fingerprint "$REPO")"
POLICY_BINDING="$(dx_review_policy_binding 1 3 6)"
OTHER_POLICY_BINDING="$(dx_review_policy_binding 2 4 7)"
PASS_BINDING="$(dx_review_pass_binding "$PASS_ID" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING")"

[[ "$PASS_BINDING" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'pass binding is not a full lowercase SHA-256 digest\n' >&2
  exit 1
}
assert_eq "$PASS_BINDING" \
  "$(dx_review_pass_binding "$PASS_ID" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING")" \
  "pass binding is deterministic"
[[ "$PASS_BINDING" != "$(dx_review_pass_binding evidence-v3-pass-2 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING")" ]] || assert_at $LINENO
[[ "$PASS_BINDING" != "$(dx_review_pass_binding "$PASS_ID" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$OTHER_POLICY_BINDING")" ]] || assert_at $LINENO
assert_rejected "pass binding rejects malformed policy" \
  dx_review_pass_binding "$PASS_ID" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" invalid

CONTEXT_FILE="$TMP_DIR/review-context"
write_context() {
  local include_verification_marker="${1:-1}"
  {
    printf '%s\n\n' '## Scope' 'Review the complete fixture scope for this independent pass.'
    printf '%s\n\n' '## Acceptance Criteria' "Criteria binding: ${CRITERIA_BINDING}"
    printf '%s\n\n' '## Deterministic Checks' 'The focused evidence test covers the format contract.'
    printf '%s\n' 'Evidence-Ref: criteria:objectives:1:scope-review | analysis | The complete candidate scope was checked against the approved objective.'
    printf '%s\n' 'Evidence-Ref: criteria:acceptance_criteria:1:format-contract | file | The evidence manifest contains one exact record for every criteria item.'
    if [[ "$include_verification_marker" == "1" ]]; then
      printf '%s\n' 'Evidence-Ref: criteria:verification_requirements:1:focused-test | test | tests/review-evidence-v3-test.sh completed successfully.'
    fi
    printf '\n%s\n\n' '## Review Coverage' 'Correctness, contracts, tests, security, and architecture were inspected.'
    printf '%s\n' '## Verification' 'The verifier checked the final evidence against the pass inputs.'
  } > "$CONTEXT_FILE"
}
write_context
dx_review_context_valid "$CONTEXT_FILE" "$CRITERIA_BINDING"

EVIDENCE_FILE="$TMP_DIR/review-evidence.json"
write_evidence() {
  local mode="${1:-valid}"
  local pass_id="${2:-$PASS_ID}" pass_binding
  pass_binding="$(dx_review_pass_binding "$pass_id" "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING")"
  MODE="$mode" \
  EVIDENCE_FILE="$EVIDENCE_FILE" \
  SCOPE_FINGERPRINT="$SCOPE_FINGERPRINT" \
  CRITERIA_BINDING="$CRITERIA_BINDING" \
  POLICY_BINDING="$POLICY_BINDING" \
  PASS_BINDING="$pass_binding" \
  python3 - <<'PY'
import json
import os

mode = os.environ["MODE"]
items = {
    "objectives": [{
        "item_hash": None,
        "outcome": "met",
        "evidence_refs": ["criteria:objectives:1:scope-review"],
    }],
    "acceptance_criteria": [{
        "item_hash": None,
        "outcome": "met",
        "evidence_refs": ["criteria:acceptance_criteria:1:format-contract"],
    }],
    "verification_requirements": [{
        "item_hash": None,
        "outcome": "met",
        "evidence_refs": ["criteria:verification_requirements:1:focused-test"],
    }],
}

criteria = {
    "objectives": ["Keep review credit pass-bound."],
    "acceptance_criteria": ["Every requirement has auditable evidence."],
    "verification_requirements": ["Run the focused evidence test."],
}
import hashlib
for section, values in criteria.items():
    for index, value in enumerate(values):
        canonical = json.dumps([section, index, value], ensure_ascii=False, separators=(",", ":"))
        items[section][index]["item_hash"] = hashlib.sha256(canonical.encode()).hexdigest()

payload = {
    "version": 3,
    "scope_fingerprint": os.environ["SCOPE_FINGERPRINT"],
    "criteria_binding": os.environ["CRITERIA_BINDING"],
    "policy_binding": os.environ["POLICY_BINDING"],
    "pass_binding": os.environ["PASS_BINDING"],
    "criteria_evidence": items,
    "deterministic_checks": "pass",
    "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
    "verifier": "pass",
    "verified_findings": 0,
    "fixes_applied": 0,
}

if mode == "version-2":
    payload["version"] = 2
    payload.pop("policy_binding")
    payload.pop("pass_binding")
    payload["criteria_coverage"] = {
        section: [entry["item_hash"] for entry in entries]
        for section, entries in payload.pop("criteria_evidence").items()
    }
elif mode == "wrong-policy":
    payload["policy_binding"] = "0" * 64
elif mode == "wrong-pass":
    payload["pass_binding"] = "0" * 64
elif mode == "missing-item":
    payload["criteria_evidence"]["acceptance_criteria"] = []
elif mode == "wrong-item":
    payload["criteria_evidence"]["objectives"][0]["item_hash"] = "0" * 64
elif mode == "bad-outcome":
    payload["criteria_evidence"]["objectives"][0]["outcome"] = "covered"
elif mode == "unmet-clean":
    payload["criteria_evidence"]["objectives"][0]["outcome"] = "not_met"
elif mode == "empty-refs":
    payload["criteria_evidence"]["objectives"][0]["evidence_refs"] = []
elif mode == "wrong-ref-index":
    payload["criteria_evidence"]["objectives"][0]["evidence_refs"] = [
        "criteria:objectives:2:scope-review"
    ]
elif mode == "duplicate-refs":
    payload["criteria_evidence"]["objectives"][0]["evidence_refs"] *= 2
elif mode == "extra-field":
    payload["criteria_evidence"]["objectives"][0]["note"] = "unbounded prose"

with open(os.environ["EVIDENCE_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}

validate_evidence() {
  dx_review_evidence_valid "$EVIDENCE_FILE" CLEAN light "$SCOPE_FINGERPRINT" \
    "$CRITERIA_BINDING" "$CRITERIA_FILE" "$PASS_ID" "$POLICY_BINDING" "$CONTEXT_FILE"
}

write_evidence valid
validate_evidence
ATTESTATION="$(dx_review_evidence_hash "$EVIDENCE_FILE")"
[[ "$ATTESTATION" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'evidence attestation is not a full lowercase SHA-256 digest\n' >&2
  exit 1
}
HASH_SYMLINK="$TMP_DIR/evidence-hash-symlink.json"
ln -s "$EVIDENCE_FILE" "$HASH_SYMLINK"
assert_rejected "evidence hash does not follow symlinks" \
  dx_review_evidence_hash "$HASH_SYMLINK"
HASH_OVERSIZED="$TMP_DIR/evidence-hash-oversized.json"
dd if=/dev/zero of="$HASH_OVERSIZED" bs=262145 count=1 2>/dev/null
assert_rejected "evidence hash rejects oversized input" \
  dx_review_evidence_hash "$HASH_OVERSIZED"
HASH_EMPTY="$TMP_DIR/evidence-hash-empty.json"
: > "$HASH_EMPTY"
assert_rejected "evidence hash rejects empty input" \
  dx_review_evidence_hash "$HASH_EMPTY"
PASS_ATTESTATION="$(dx_review_pass_attestation "$EVIDENCE_FILE" "$CONTEXT_FILE" CLEAN light \
  "$(dx_review_empty_findings_hash)" "$PASS_BINDING")"
[[ "$PASS_ATTESTATION" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'pass attestation is not a full lowercase SHA-256 digest\n' >&2
  exit 1
}
[[ "$PASS_ATTESTATION" != "$(dx_review_pass_attestation "$EVIDENCE_FILE" "$CONTEXT_FILE" \
  FINDINGS_FIXED:1 light 0123456789abcdef "$PASS_BINDING")" ]]

for mode in version-2 wrong-policy wrong-pass missing-item wrong-item bad-outcome \
  unmet-clean empty-refs wrong-ref-index duplicate-refs extra-field; do
  write_evidence "$mode"
  assert_rejected "gating evidence rejects ${mode}" validate_evidence
done

write_evidence valid
write_context 0
assert_rejected "evidence rejects a missing context marker" validate_evidence
write_context
assert_rejected "evidence rejects the wrong pass identity" \
  dx_review_evidence_valid "$EVIDENCE_FILE" CLEAN light "$SCOPE_FINGERPRINT" \
  "$CRITERIA_BINDING" "$CRITERIA_FILE" evidence-v3-pass-2 "$POLICY_BINDING" "$CONTEXT_FILE"
assert_rejected "evidence rejects the wrong policy binding" \
  dx_review_evidence_valid "$EVIDENCE_FILE" CLEAN light "$SCOPE_FINGERPRINT" \
  "$CRITERIA_BINDING" "$CRITERIA_FILE" "$PASS_ID" "$OTHER_POLICY_BINDING" "$CONTEXT_FILE"
assert_rejected "gating evidence does not infer omitted bindings" \
  dx_review_evidence_valid "$EVIDENCE_FILE" CLEAN light "$SCOPE_FINGERPRINT" \
  "$CRITERIA_BINDING" "$CRITERIA_FILE"

LEGACY_EVIDENCE_FILE="$TMP_DIR/review-evidence-v2.json"
write_evidence version-2
cp "$EVIDENCE_FILE" "$LEGACY_EVIDENCE_FILE"
assert_rejected "legacy evidence cannot pass the gating validator" \
  dx_review_evidence_valid "$LEGACY_EVIDENCE_FILE" CLEAN light "$SCOPE_FINGERPRINT" \
  "$CRITERIA_BINDING" "$CRITERIA_FILE" "$PASS_ID" "$POLICY_BINDING" "$CONTEXT_FILE"

write_evidence valid
ATTESTATION="$(dx_review_evidence_hash "$EVIDENCE_FILE")"
dx_review_write_selection "$SESSION_ID" small environment operator-override "$REPO" 3 "$CRITERIA_BINDING"
for iteration in 1 2 3; do
  ledger_pass_id="evidence-v3-pass-${iteration}"
  write_evidence valid "$ledger_pass_id"
  dx_review_ledger_append "$SESSION_ID" "$iteration" "$ledger_pass_id" light \
    "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING" \
    "$EVIDENCE_FILE" "$CONTEXT_FILE"
done
dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "ledger binds the selected review profile" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" standard
assert_eq "4" "$(cut -f1 "$(dx_review_ledger_file "$SESSION_ID")" | sort -u)" "ledger format version"

PROOF_DIR="$(dx_review_proof_dir "$SESSION_ID")"
for iteration in 1 2 3; do
  [[ -f "$PROOF_DIR/$iteration/evidence.json" && ! -L "$PROOF_DIR/$iteration/evidence.json" ]] || assert_at $LINENO
  [[ -f "$PROOF_DIR/$iteration/context.md" && ! -L "$PROOF_DIR/$iteration/context.md" ]] || assert_at $LINENO
  assert_eq "400" "$(dx_path_mode "$PROOF_DIR/$iteration/evidence.json")" \
    "retained evidence permissions"
  assert_eq "400" "$(dx_path_mode "$PROOF_DIR/$iteration/context.md")" \
    "retained context permissions"
done

first_pass_binding="$(cut -f8 "$(dx_review_ledger_file "$SESSION_ID")" | head -n 1)"
first_recorded_attestation="$(cut -f9 "$(dx_review_ledger_file "$SESSION_ID")" | head -n 1)"
first_computed_attestation="$(dx_review_pass_attestation \
  "$PROOF_DIR/1/evidence.json" "$PROOF_DIR/1/context.md" CLEAN light \
  "$(dx_review_empty_findings_hash)" "$first_pass_binding")"
assert_eq "$first_computed_attestation" "$first_recorded_attestation" \
  "ledger derives the attestation from retained proof"

write_evidence valid evidence-v3-pass-4
ln -s "$EVIDENCE_FILE" "$TMP_DIR/symlink-evidence.json"
assert_rejected "ledger append does not follow a source evidence symlink" \
  dx_review_ledger_append "$SESSION_ID" 4 evidence-v3-pass-4 light \
  "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING" \
  "$TMP_DIR/symlink-evidence.json" "$CONTEXT_FILE"
[[ ! -e "$PROOF_DIR/4" ]] || assert_at $LINENO

COPY_FAILURE_SESSION="evidence-v3-copy-failure"
cp "$CRITERIA_FILE" "$(dx_review_criteria_file "$COPY_FAILURE_SESSION")"
dx_review_approve_criteria "$COPY_FAILURE_SESSION" initial "$CRITERIA_BINDING" >/dev/null
write_evidence valid evidence-v3-copy-failure-pass
chmod 666 "$EVIDENCE_FILE"
assert_rejected "ledger append rejects a writable source evidence manifest" \
  dx_review_ledger_append "$COPY_FAILURE_SESSION" 1 evidence-v3-copy-failure-pass light \
  "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING" \
  "$EVIDENCE_FILE" "$CONTEXT_FILE"
[[ ! -e "$(dx_review_proof_dir "$COPY_FAILURE_SESSION")" ]] || assert_at $LINENO
chmod 644 "$EVIDENCE_FILE"

BAD_LEDGER_SESSION="evidence-v3-bad-ledger"
assert_rejected "ledger rejects the legacy caller-supplied attestation API" \
  dx_review_ledger_append "$BAD_LEDGER_SESSION" 1 bad-pass "$SCOPE_FINGERPRINT" \
    standalone "$POLICY_BINDING" \
    "$(dx_review_pass_binding bad-pass "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING")" \
    0123456789abcdef
printf '3\t1\tlegacy-pass\t%s\t%s\t%s\t%s\t%s\n' \
  "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING" \
  "$(dx_review_pass_binding legacy-pass "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING")" \
  "$ATTESTATION" > "$(dx_review_ledger_file "$BAD_LEDGER_SESSION")"
assert_rejected "gating ledger rejects legacy rows" \
  dx_review_ledger_valid "$BAD_LEDGER_SESSION" 1 "$SCOPE_FINGERPRINT" standalone \
  "$POLICY_BINDING" light

dx_review_write_receipt "$SESSION_ID" small 3 3 "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
receipt_record="$(dx_review_read_receipt "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING")"
IFS=$'\t' read -r receipt_tier receipt_required receipt_clean receipt_fingerprint \
  receipt_ledger_hash receipt_criteria_binding receipt_policy_binding <<EOF
$receipt_record
EOF
assert_eq "small" "$receipt_tier" "receipt tier"
assert_eq "3" "$receipt_required" "receipt gate"
assert_eq "3" "$receipt_clean" "receipt clean count"
assert_eq "$SCOPE_FINGERPRINT" "$receipt_fingerprint" "receipt scope binding"
[[ "$receipt_ledger_hash" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
assert_eq "$CRITERIA_BINDING" "$receipt_criteria_binding" "receipt criteria binding"
assert_eq "$POLICY_BINDING" "$receipt_policy_binding" "receipt policy binding"
dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
assert_eq "5" "$(cut -f1 "$(dx_review_receipt_file "$SESSION_ID")")" "receipt format version"
assert_rejected "receipt rejects a different policy" \
  dx_review_read_receipt "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$OTHER_POLICY_BINDING"
assert_rejected "receipt validation requires an explicit policy binding" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING"

# If neither the revocation marker nor the receipt inode can be invalidated,
# the lifecycle pause must remain non-resumable. Clearing that brake would make
# the old review receipt valid again without another independent review.
set +e
DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" DX_LOOP_DIR="$DX_LOOP_DIR" \
  bash -c '
    source "$DEX_DIR/lib/common.sh"
    dx_review_write_atomic() { return 1; }
    __dx_review_invalidate_private_record() { return 1; }
    dx_review_revoke_receipt "$1"
  ' _ "$SESSION_ID"
REVOKE_FAILURE_RC=$?
set -e
[[ "$REVOKE_FAILURE_RC" -ne 0 ]] || assert_at $LINENO
dx_review_receipt_valid "$SESSION_ID" "$REPO" \
  "$CRITERIA_BINDING" "$POLICY_BINDING"
dx_lifecycle_atomic_write "$(dx_state_file "$SESSION_ID")" 3
REVOKE_FAILURE_GENERATION=$(dx_completion_issue \
  "$SESSION_ID" lifecycle phase 3)
dx_lifecycle_atomic_write "$(dx_loop_config_file "$SESSION_ID")" \
  "3:PHASE_3_COMPLETE:${ROOT}/prompts/phase-audits/3-review-loop.md:1:lifecycle:phase:${REVOKE_FAILURE_GENERATION}"
dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$SESSION_ID")" inline
dx_lifecycle_pause "$SESSION_ID" receipt_revocation_failed review-loop
assert_rejected "unproven receipt revocation cannot be resumed" \
  bash -c 'cd "$1" && DEX_SESSION_ID="$2" bash "$3/bin/control.sh" resume' \
    _ "$REPO" "$SESSION_ID" "$ROOT"
dx_lifecycle_pause_context_state "$SESSION_ID"
assert_eq "receipt_revocation_failed" \
  "$(dx_pause_state_read "$SESSION_ID" reason)" \
  "receipt revocation failure brake"
dx_lifecycle_control_lock_acquire "$SESSION_ID"
dx_lifecycle_pause_clear_unlocked "$SESSION_ID"
dx_lifecycle_control_lock_release "$SESSION_ID"
dx_review_receipt_valid "$SESSION_ID" "$REPO" \
  "$CRITERIA_BINDING" "$POLICY_BINDING"
rm -f "$(dx_state_file "$SESSION_ID")" \
  "$(dx_loop_config_file "$SESSION_ID")" \
  "$(dx_handoff_mode_file "$SESSION_ID")"

cp "$(dx_review_receipt_file "$SESSION_ID")" "$TMP_DIR/receipt-v5"
printf '4\tsmall\t3\t3\t%s\t%s\t%s\t%s\n' \
  "$SCOPE_FINGERPRINT" "$receipt_ledger_hash" "$CRITERIA_BINDING" "$POLICY_BINDING" \
  > "$(dx_review_receipt_file "$SESSION_ID")"
assert_rejected "gating receipt rejects legacy format" \
  dx_review_read_receipt "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
mv "$TMP_DIR/receipt-v5" "$(dx_review_receipt_file "$SESSION_ID")"

cp "$(dx_review_ledger_file "$SESSION_ID")" "$TMP_DIR/ledger-backup"
python3 - "$(dx_review_ledger_file "$SESSION_ID")" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
rows = path.read_text(encoding="ascii").splitlines()
fields = rows[-1].split("\t")
fields[-1] = "0" * 64
rows[-1] = "\t".join(fields)
path.write_text("\n".join(rows) + "\n", encoding="ascii")
PY
assert_rejected "ledger recomputes and rejects a caller-supplied attestation" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt rejects ledger attestation tampering" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
mv "$TMP_DIR/ledger-backup" "$(dx_review_ledger_file "$SESSION_ID")"

chmod 644 "$(dx_review_ledger_file "$SESSION_ID")"
assert_rejected "ledger rejects permissive ledger permissions" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
chmod 600 "$(dx_review_ledger_file "$SESSION_ID")"

chmod 644 "$(dx_review_receipt_file "$SESSION_ID")"
assert_rejected "receipt rejects permissive receipt permissions" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 600 "$(dx_review_receipt_file "$SESSION_ID")"

chmod 700 "$PROOF_DIR/1"
mv "$PROOF_DIR/1/evidence.json" "$TMP_DIR/missing-evidence.json"
chmod 500 "$PROOF_DIR/1"
assert_rejected "ledger rejects a missing retained evidence manifest" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt rejects a missing retained evidence manifest" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 700 "$PROOF_DIR/1"
mv "$TMP_DIR/missing-evidence.json" "$PROOF_DIR/1/evidence.json"
chmod 500 "$PROOF_DIR/1"

cp "$PROOF_DIR/2/evidence.json" "$TMP_DIR/evidence-2-backup.json"
chmod 600 "$PROOF_DIR/2/evidence.json"
printf '\n' >> "$PROOF_DIR/2/evidence.json"
chmod 400 "$PROOF_DIR/2/evidence.json"
assert_rejected "ledger rejects tampered retained evidence" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt recomputes and rejects tampered retained evidence" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 700 "$PROOF_DIR/2"
rm "$PROOF_DIR/2/evidence.json"
mv "$TMP_DIR/evidence-2-backup.json" "$PROOF_DIR/2/evidence.json"
chmod 400 "$PROOF_DIR/2/evidence.json"
chmod 500 "$PROOF_DIR/2"

mkdir "$PROOF_DIR/orphan"
chmod 500 "$PROOF_DIR/orphan"
assert_rejected "ledger rejects an orphan retained proof" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt rejects an orphan retained proof" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 700 "$PROOF_DIR/orphan"
rmdir "$PROOF_DIR/orphan"

chmod 600 "$PROOF_DIR/3/context.md"
assert_rejected "ledger rejects writable retained proof permissions" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
chmod 400 "$PROOF_DIR/3/context.md"
dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"

chmod 700 "$PROOF_DIR/3"
mv "$PROOF_DIR/3/context.md" "$TMP_DIR/context-3-backup.md"
ln -s "$TMP_DIR/context-3-backup.md" "$PROOF_DIR/3/context.md"
chmod 500 "$PROOF_DIR/3"
assert_rejected "ledger does not follow a retained context symlink" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt does not follow a retained context symlink" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 700 "$PROOF_DIR/3"
rm "$PROOF_DIR/3/context.md"
mv "$TMP_DIR/context-3-backup.md" "$PROOF_DIR/3/context.md"
chmod 400 "$PROOF_DIR/3/context.md"
chmod 500 "$PROOF_DIR/3"

chmod 700 "$PROOF_DIR/3"
mv "$PROOF_DIR/3/evidence.json" "$TMP_DIR/evidence-3-backup.json"
dd if=/dev/zero of="$PROOF_DIR/3/evidence.json" bs=262145 count=1 2>/dev/null
chmod 400 "$PROOF_DIR/3/evidence.json"
chmod 500 "$PROOF_DIR/3"
assert_rejected "ledger rejects an oversized retained evidence manifest" \
  dx_review_ledger_valid "$SESSION_ID" 3 "$SCOPE_FINGERPRINT" "$CRITERIA_BINDING" \
  "$POLICY_BINDING" light
assert_rejected "receipt rejects an oversized retained evidence manifest" \
  dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
chmod 700 "$PROOF_DIR/3"
rm "$PROOF_DIR/3/evidence.json"
mv "$TMP_DIR/evidence-3-backup.json" "$PROOF_DIR/3/evidence.json"
chmod 400 "$PROOF_DIR/3/evidence.json"
chmod 500 "$PROOF_DIR/3"
dx_review_receipt_valid "$SESSION_ID" "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"

STANDALONE_SESSION="evidence-v3-standalone"
STANDALONE_CONTEXT="$TMP_DIR/standalone-context.md"
STANDALONE_EVIDENCE="$TMP_DIR/standalone-evidence.json"
{
  printf '%s\n\n' '## Scope' 'Review the complete standalone fixture scope for this independent pass.'
  printf '%s\n\n' '## Acceptance Criteria' 'Criteria binding: standalone'
  printf '%s\n\n' '## Deterministic Checks' 'The focused evidence test covers the standalone evidence contract.'
  printf '%s\n\n' '## Review Coverage' 'Correctness, contracts, tests, security, and architecture were inspected.'
  printf '%s\n' '## Verification' 'The verifier checked the standalone evidence against the pass inputs.'
} > "$STANDALONE_CONTEXT"
write_standalone_evidence() {
  local pass_id="$1" pass_binding
  pass_binding="$(dx_review_pass_binding "$pass_id" "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING")"
  STANDALONE_EVIDENCE="$STANDALONE_EVIDENCE" \
  SCOPE_FINGERPRINT="$SCOPE_FINGERPRINT" \
  POLICY_BINDING="$POLICY_BINDING" \
  PASS_BINDING="$pass_binding" \
    python3 - <<'PY'
import json
import os

payload = {
    "version": 3,
    "scope_fingerprint": os.environ["SCOPE_FINGERPRINT"],
    "criteria_binding": "standalone",
    "policy_binding": os.environ["POLICY_BINDING"],
    "pass_binding": os.environ["PASS_BINDING"],
    "criteria_evidence": {
        "objectives": [],
        "acceptance_criteria": [],
        "verification_requirements": [],
    },
    "deterministic_checks": "pass",
    "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
    "verifier": "pass",
    "verified_findings": 0,
    "fixes_applied": 0,
}
with open(os.environ["STANDALONE_EVIDENCE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
}
dx_review_write_selection "$STANDALONE_SESSION" small environment operator-override \
  "$REPO" 3 standalone "$POLICY_BINDING"
for iteration in 5 7 10; do
  standalone_pass_id="evidence-v3-standalone-${iteration}"
  write_standalone_evidence "$standalone_pass_id"
  dx_review_ledger_append "$STANDALONE_SESSION" "$iteration" "$standalone_pass_id" light \
    "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING" \
    "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
done
dx_review_ledger_valid "$STANDALONE_SESSION" 3 "$SCOPE_FINGERPRINT" standalone \
  "$POLICY_BINDING" light
dx_review_write_receipt "$STANDALONE_SESSION" small 3 3 "$REPO" standalone "$POLICY_BINDING"
dx_review_receipt_valid "$STANDALONE_SESSION" "$REPO" standalone "$POLICY_BINDING"
dx_review_ledger_reset "$STANDALONE_SESSION"

DUPLICATE_ITERATION_SESSION="evidence-v3-duplicate-iteration"
duplicate_pass_id="evidence-v3-duplicate-iteration-5"
write_standalone_evidence "$duplicate_pass_id"
dx_review_ledger_append "$DUPLICATE_ITERATION_SESSION" 5 "$duplicate_pass_id" light \
  "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING" \
  "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
write_standalone_evidence evidence-v3-duplicate-iteration-retry
assert_rejected "ledger rejects a duplicate accepted-pass iteration" \
  dx_review_ledger_append "$DUPLICATE_ITERATION_SESSION" 5 \
    evidence-v3-duplicate-iteration-retry light "$SCOPE_FINGERPRINT" standalone \
    "$POLICY_BINDING" "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
dx_review_ledger_valid "$DUPLICATE_ITERATION_SESSION" 1 "$SCOPE_FINGERPRINT" standalone \
  "$POLICY_BINDING" light
dx_review_ledger_reset "$DUPLICATE_ITERATION_SESSION"

DECREASING_ITERATION_SESSION="evidence-v3-decreasing-iteration"
decreasing_pass_id="evidence-v3-decreasing-iteration-5"
write_standalone_evidence "$decreasing_pass_id"
dx_review_ledger_append "$DECREASING_ITERATION_SESSION" 5 "$decreasing_pass_id" light \
  "$SCOPE_FINGERPRINT" standalone "$POLICY_BINDING" \
  "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
write_standalone_evidence evidence-v3-decreasing-iteration-4
assert_rejected "ledger rejects a decreasing accepted-pass iteration" \
  dx_review_ledger_append "$DECREASING_ITERATION_SESSION" 4 \
    evidence-v3-decreasing-iteration-4 light "$SCOPE_FINGERPRINT" standalone \
    "$POLICY_BINDING" "$STANDALONE_EVIDENCE" "$STANDALONE_CONTEXT"
[[ ! -e "$(dx_review_ledger_file "$DECREASING_ITERATION_SESSION")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_proof_dir "$DECREASING_ITERATION_SESSION")" ]] || assert_at $LINENO

dx_review_ledger_reset "$SESSION_ID"
[[ ! -e "$(dx_review_ledger_file "$SESSION_ID")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_proof_dir "$SESSION_ID")" ]] || assert_at $LINENO

printf 'Review evidence v3 tests passed.\n'
