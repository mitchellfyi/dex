# shellcheck shell=bash
# Helpers for tests that need recomputable clean-pass proof bundles.

# dx_test_write_clean_review_proof <session-id> <pass-id> <profile>
#   <fingerprint> <criteria-binding> <policy-binding> <evidence-file> <context-file>
dx_test_write_clean_review_proof() {
  [[ $# -eq 8 ]] || return 1
  local session_id="$1" pass_id="$2" profile="$3" fingerprint="$4"
  local criteria_binding="$5" policy_binding="$6" evidence_file="$7" context_file="$8"
  local criteria_file="" pass_binding

  if [[ "$criteria_binding" != "standalone" ]]; then
    criteria_file=$(dx_review_criteria_file "$session_id") || return 1
  fi
  pass_binding=$(dx_review_pass_binding \
    "$pass_id" "$fingerprint" "$criteria_binding" "$policy_binding") || return 1
  mkdir -p "$(dirname "$evidence_file")" "$(dirname "$context_file")" || return 1

  DX_TEST_REVIEW_PROFILE="$profile" \
  DX_TEST_REVIEW_FINGERPRINT="$fingerprint" \
  DX_TEST_REVIEW_CRITERIA_BINDING="$criteria_binding" \
  DX_TEST_REVIEW_POLICY_BINDING="$policy_binding" \
  DX_TEST_REVIEW_PASS_BINDING="$pass_binding" \
  DX_TEST_REVIEW_CRITERIA_FILE="$criteria_file" \
    python3 - "$evidence_file" "$context_file" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

evidence_path = Path(sys.argv[1])
context_path = Path(sys.argv[2])
profile = os.environ["DX_TEST_REVIEW_PROFILE"]
binding = os.environ["DX_TEST_REVIEW_CRITERIA_BINDING"]
sections = ("objectives", "acceptance_criteria", "verification_requirements")

if profile not in {"light", "standard", "thorough"}:
    raise SystemExit(1)

if binding == "standalone":
    criteria = {section: [] for section in sections}
else:
    with open(os.environ["DX_TEST_REVIEW_CRITERIA_FILE"], encoding="utf-8") as handle:
        criteria = json.load(handle)

criteria_evidence = {}
evidence_lines = []
for section in sections:
    entries = []
    for index, value in enumerate(criteria[section], start=1):
        item_hash = hashlib.sha256(
            json.dumps(
                [section, index - 1, value],
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        marker = f"criteria:{section}:{index}:fixture-proof"
        entries.append(
            {"item_hash": item_hash, "outcome": "met", "evidence_refs": [marker]}
        )
        evidence_lines.append(
            f"Evidence-Ref: {marker} | test | The focused fixture verified this approved review criterion."
        )
    criteria_evidence[section] = entries

context_lines = [
    "## Scope",
    "",
    "Reviewed the complete supplied scope for this retained-proof fixture.",
    "",
    "## Acceptance Criteria",
    "",
    f"Criteria binding: {binding}",
    "",
    "## Deterministic Checks",
    "",
    "All applicable focused fixture checks passed.",
]
if evidence_lines:
    context_lines.extend(["", *evidence_lines])
context_lines.extend(
    [
        "",
        "## Review Coverage",
        "",
        "Correctness, security, contracts, tests, and architecture were covered.",
        "",
        "## Verification",
        "",
        "The fixture verifier rechecked the final clean result and its evidence.",
    ]
)
context_path.write_text("\n".join(context_lines) + "\n", encoding="utf-8")

coverage = ["correctness", "security", "contracts", "tests", "architecture"]
if profile == "thorough":
    coverage.extend(["frontend", "devops", "performance", "observability"])
payload = {
    "version": 3,
    "scope_fingerprint": os.environ["DX_TEST_REVIEW_FINGERPRINT"],
    "criteria_binding": binding,
    "policy_binding": os.environ["DX_TEST_REVIEW_POLICY_BINDING"],
    "pass_binding": os.environ["DX_TEST_REVIEW_PASS_BINDING"],
    "criteria_evidence": criteria_evidence,
    "deterministic_checks": "pass",
    "coverage": coverage,
    "verifier": "pass",
    "verified_findings": 0,
    "fixes_applied": 0,
}
evidence_path.write_text(
    json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}
