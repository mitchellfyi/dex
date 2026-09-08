"""Compile reviewer conclusions into the existing version-3 evidence contract."""

import hashlib
import json
import os
from pathlib import Path
import sys

from review_checks import CheckError, regular_json


SECTIONS = ("objectives", "acceptance_criteria", "verification_requirements")


def compile_report(report, hashes, bindings):
    """Derive bookkeeping only; outcomes and evidence must come from the reviewer."""
    if (not isinstance(report, dict) or set(report) != {
            "version", "result", "context", "criteria", "deterministic_checks",
            "coverage", "verifier", "findings", "fixes_applied"}
            or type(report["version"]) is not int or report["version"] != 1):
        raise CheckError("Expected a version-1 review report")
    context = report["context"]
    if (not isinstance(context, dict) or set(context) != {"scope", "checks", "coverage", "verification"}
            or any(not isinstance(value, str) or not 12 <= len(value.strip()) <= 32000
                   or any(line.startswith("Evidence-Ref:") for line in value.splitlines())
                   for value in context.values())):
        raise CheckError("Report needs substantive scope, checks, coverage, and verification")
    if (not isinstance(report["criteria"], dict) or set(report["criteria"]) != set(SECTIONS)
            or not isinstance(report["findings"], list)
            or any(not isinstance(item, str) or not 12 <= len(item.strip()) <= 4000
                   or "\n" in item or "\r" in item for item in report["findings"])
            or len(set(report["findings"])) != len(report["findings"])):
        raise CheckError("Invalid criteria or verified finding descriptions")
    evidence_lines, criteria_evidence = [], {}
    for section in SECTIONS:
        supplied = report["criteria"][section]
        if not isinstance(supplied, list) or len(supplied) != len(hashes[section]):
            raise CheckError("Every supplied criterion needs an explicit outcome and evidence")
        entries = []
        for index, (item, item_hash) in enumerate(zip(supplied, hashes[section]), start=1):
            if (not isinstance(item, dict) or set(item) != {"outcome", "evidence"}
                    or not isinstance(item["evidence"], list) or not 1 <= len(item["evidence"]) <= 8):
                raise CheckError("Each criterion needs an outcome and one to eight evidence entries")
            refs = []
            for number, observation in enumerate(item["evidence"], start=1):
                if not isinstance(observation, dict) or set(observation) != {"kind", "detail"}:
                    raise CheckError("Evidence entries need kind and detail")
                # The existing evidence validator checks kinds, details, and outcomes.
                if not all(isinstance(value, str) and "\n" not in value and "\r" not in value
                           for value in observation.values()):
                    raise CheckError("Evidence must be single-line text")
                marker = f"criteria:{section}:{index}:e{number}"
                refs.append(marker)
                evidence_lines.append(f"Evidence-Ref: {marker} | {observation['kind']} | {observation['detail']}")
            entries.append({"item_hash": item_hash, "outcome": item["outcome"], "evidence_refs": refs})
        criteria_evidence[section] = entries
    scope, criteria, policy, pass_binding = bindings
    context_text = (
        f"## Scope\n\n{context['scope']}\n\n## Acceptance Criteria\n\nCriteria binding: {criteria}\n\n"
        + ("\n".join(evidence_lines) if evidence_lines else "N/A: standalone review.")
        + f"\n\n## Deterministic Checks\n\n{context['checks']}\n\n## Review Coverage\n\n{context['coverage']}"
        + f"\n\n## Verification\n\n{context['verification']}\n"
    )
    evidence = {"version": 3, "scope_fingerprint": scope, "criteria_binding": criteria,
                "policy_binding": policy, "pass_binding": pass_binding,
                "criteria_evidence": criteria_evidence,
                **{field: report[field] for field in ("deterministic_checks", "coverage", "verifier", "fixes_applied")},
                "verified_findings": len(report["findings"])}
    finding_text = "\n".join(sorted(report["findings"])) if report["findings"] else "EMPTY"
    finding_hash = hashlib.sha256((finding_text + "\n").encode()).hexdigest()[:16]
    if not isinstance(report["result"], str) or "\n" in report["result"] or "\r" in report["result"]:
        raise CheckError("Expected a single-line result")
    return {"context": context_text, "evidence": json.dumps(evidence, sort_keys=True) + "\n",
            "findings": finding_hash + "\n", "result": report["result"] + "\n"}


def main(arguments):
    try:
        report_file, output_dir, hashes_json, *bindings = arguments
        if len(bindings) != 4:
            raise CheckError("Missing review bindings")
        compiled = compile_report(regular_json(report_file), json.loads(hashes_json), bindings)
        for name, value in compiled.items():
            if len(value.encode()) > 262144:
                raise CheckError("Compiled review report exceeds the evidence limit")
            target = Path(output_dir) / name
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(value)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"review-result: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
