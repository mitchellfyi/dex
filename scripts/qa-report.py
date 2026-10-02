#!/usr/bin/env python3
"""Validate and finalize a Dex manual QA report.

    qa-report.py finalize <draft> --criteria FILE --session-id ID --session-dir DIR
        --out JSON --markdown MD [--approval-hash HASH] [--checkout SHA] [--working SHA]
    qa-report.py terminal BLOCKED|N_A --reason TEXT --session-id ID --session-dir DIR
        --out JSON --markdown MD [--criteria FILE] [--approval-hash HASH]
        [--checkout SHA] [--working SHA]
    qa-report.py validate <report>
    qa-report.py status <report>

The agent supplies rows; this script decides the status. A drafted `status` is
ignored. Exit 0 on success, 1 when the draft or report is invalid (the reasons
go to stderr), 2 on a usage error. Standard library only.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

VERSION = 1
OUTCOMES = ("MET", "NOT_MET", "BLOCKED", "N_A")
STATUSES = ("PASSED", "FINDINGS", "BLOCKED", "N_A")
KINDS = {"acceptance": "acceptance_criteria", "verification": "verification_requirements"}
SEVERITIES = ("high", "medium", "low")
DISPOSITIONS = ("fixed", "follow-up", "note")
SURFACES = ("web", "cli", "api", "native", "none")
MAX_CRITERIA = 128
MAX_EXPLORATORY = 200
MAX_STRING = 4000
MAX_BYTES = 1024 * 1024
INVALID = 1
USAGE = 2


class Invalid(Exception):
    """A draft or report that must not become the recorded QA result."""


def load_json(path, limit=MAX_BYTES):
    try:
        if os.path.getsize(path) > limit:
            raise Invalid(f"{path} exceeds {limit} bytes")
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as error:
        raise Invalid(f"{path} could not be read: {error}") from error
    except (UnicodeError, json.JSONDecodeError) as error:
        raise Invalid(f"{path} is not valid JSON: {error}") from error


def text(value, label, required=True, limit=MAX_STRING):
    if not isinstance(value, str):
        raise Invalid(f"{label} must be a string")
    if required and not value.strip():
        raise Invalid(f"{label} must not be empty")
    if len(value) > limit:
        raise Invalid(f"{label} exceeds {limit} characters")
    return value


def expected_rows(criteria):
    if not isinstance(criteria, dict):
        raise Invalid("the criteria file is not a JSON object")
    rows = []
    for kind, key in KINDS.items():
        values = criteria.get(key)
        if not isinstance(values, list) or not all(isinstance(item, str) for item in values):
            raise Invalid(f"the criteria file has no {key} list")
        rows.extend((kind, index + 1, item) for index, item in enumerate(values))
    return rows


def evidence_paths(values, label, session_dir, required):
    if not isinstance(values, list):
        raise Invalid(f"{label}.evidence must be a list")
    if required and not values:
        raise Invalid(f"{label} needs at least one evidence file")
    # Only files the pass itself saved count; the report, the draft and the
    # session's other bookkeeping are not evidence of the behaviour.
    root = os.path.realpath(os.path.join(session_dir, "evidence"))
    checked = []
    for position, candidate in enumerate(values):
        item = f"{label}.evidence[{position}]"
        text(candidate, item, limit=4096)
        if not os.path.isabs(candidate):
            raise Invalid(f"{item} must be an absolute path")
        try:
            details = os.lstat(candidate)
        except OSError as error:
            raise Invalid(f"{item} is missing: {error}") from error
        if os.path.islink(candidate):
            raise Invalid(f"{item} is a symlink")
        if not os.path.isfile(candidate) or details.st_size == 0:
            raise Invalid(f"{item} must be a regular, non-empty file")
        real = os.path.realpath(candidate)
        if os.path.commonpath([root, real]) != root or real == root:
            raise Invalid(f"{item} is outside the QA evidence directory")
        checked.append(candidate)
    return checked


def validate_criteria(draft_rows, expected, session_dir):
    if not isinstance(draft_rows, list):
        raise Invalid("criteria must be a list")
    if len(draft_rows) > MAX_CRITERIA:
        raise Invalid(f"criteria has more than {MAX_CRITERIA} rows")
    seen = {}
    rows = []
    for position, row in enumerate(draft_rows):
        label = f"criteria[{position}]"
        if not isinstance(row, dict):
            raise Invalid(f"{label} must be an object")
        kind = row.get("kind")
        if kind not in KINDS:
            raise Invalid(f"{label}.kind must be acceptance or verification")
        index = row.get("index")
        if isinstance(index, bool) or not isinstance(index, int) or index < 1:
            raise Invalid(f"{label}.index must be a positive integer")
        key = (kind, index)
        if key in seen:
            raise Invalid(f"{label} repeats {kind} {index}")
        seen[key] = position
        outcome = row.get("outcome")
        if outcome not in OUTCOMES:
            raise Invalid(f"{label}.outcome must be one of {', '.join(OUTCOMES)}")
        notes = text(row.get("notes", ""), f"{label}.notes", required=outcome in ("BLOCKED", "N_A"))
        evidence = evidence_paths(row.get("evidence", []), label, session_dir, outcome in ("MET", "NOT_MET"))
        rows.append({
            "kind": kind,
            "index": index,
            "text": text(row.get("text"), f"{label}.text"),
            "outcome": outcome,
            "evidence": evidence,
            "notes": notes,
        })
    wanted = {(kind, index): item for kind, index, item in expected}
    missing = [f"{kind} {index}" for (kind, index) in wanted if (kind, index) not in seen]
    if missing:
        raise Invalid(f"criteria rows are missing for: {', '.join(missing)}")
    for row in rows:
        key = (row["kind"], row["index"])
        if key not in wanted:
            raise Invalid(f"criteria row {row['kind']} {row['index']} has no approved criterion")
        if row["text"] != wanted[key]:
            raise Invalid(f"criteria row {row['kind']} {row['index']} text differs from the approved criterion")
    rows.sort(key=lambda row: (row["kind"] != "acceptance", row["index"]))
    return rows


def validate_exploratory(items, session_dir):
    if items is None:
        return []
    if not isinstance(items, list):
        raise Invalid("exploratory must be a list")
    if len(items) > MAX_EXPLORATORY:
        raise Invalid(f"exploratory has more than {MAX_EXPLORATORY} items")
    ids = set()
    rows = []
    for position, item in enumerate(items):
        label = f"exploratory[{position}]"
        if not isinstance(item, dict):
            raise Invalid(f"{label} must be an object")
        identifier = text(item.get("id"), f"{label}.id", limit=64)
        if identifier in ids:
            raise Invalid(f"{label}.id repeats {identifier}")
        ids.add(identifier)
        severity = item.get("severity")
        if severity not in SEVERITIES:
            raise Invalid(f"{label}.severity must be high, medium, or low")
        disposition = item.get("disposition")
        if disposition not in DISPOSITIONS:
            raise Invalid(f"{label}.disposition must be fixed, follow-up, or note")
        reference = text(item.get("reference", ""), f"{label}.reference", required=disposition == "follow-up", limit=200)
        rows.append({
            "id": identifier,
            "severity": severity,
            "title": text(item.get("title"), f"{label}.title", limit=300),
            "repro": text(item.get("repro"), f"{label}.repro"),
            "expected": text(item.get("expected", ""), f"{label}.expected", required=False),
            "actual": text(item.get("actual", ""), f"{label}.actual", required=False),
            "evidence": evidence_paths(item.get("evidence", []), label, session_dir, False),
            "disposition": disposition,
            "reference": reference,
        })
    return rows


def derive_status(criteria, exploratory):
    if any(row["outcome"] == "NOT_MET" for row in criteria):
        return "FINDINGS"
    # A fixed finding is gone and a filed follow-up is routed; only a medium or
    # high finding parked as a note is still open.
    if any(item["severity"] in ("high", "medium") and item["disposition"] == "note" for item in exploratory):
        return "FINDINGS"
    if any(row["outcome"] == "BLOCKED" for row in criteria):
        return "BLOCKED"
    return "PASSED"


def describe(criteria, exploratory):
    total = len(criteria)
    counts = {outcome: sum(1 for row in criteria if row["outcome"] == outcome) for outcome in OUTCOMES}
    parts = [f"{counts['MET']}/{total} criteria MET"]
    for outcome in ("NOT_MET", "BLOCKED", "N_A"):
        if counts[outcome]:
            parts.append(f"{counts[outcome]} {outcome}")
    if exploratory:
        dispositions = {name: sum(1 for item in exploratory if item["disposition"] == name) for name in DISPOSITIONS}
        noun = "finding" if len(exploratory) == 1 else "findings"
        detail = ", ".join(f"{count} {name}" for name, count in dispositions.items() if count)
        parts.append(f"{len(exploratory)} exploratory {noun}: {detail}")
    return "; ".join(parts)


def hands(values):
    if values is None:
        return []
    if not isinstance(values, list) or len(values) > 16:
        raise Invalid("hands must be a list of at most 16 names")
    return [text(item, "hands[]", limit=64) for item in values]


def build_report(args, criteria, exploratory, status, message, surface, used_hands):
    return {
        "version": VERSION,
        "status": status,
        "message": message,
        "session_id": args.session_id,
        "ui_surface": surface,
        "hands": used_hands,
        "criteria_source": {
            "file": args.criteria or "",
            "approval_hash": args.approval_hash or "",
        },
        "criteria": criteria,
        "exploratory": exploratory,
        "checkout_fingerprint": args.checkout or "",
        "working_fingerprint": args.working or "",
        "phase_state": "active",
        "completed_epoch": 0,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ").strip()


def relative_evidence(paths, session_dir):
    shown = []
    for candidate in paths:
        try:
            shown.append(os.path.relpath(candidate, session_dir))
        except ValueError:
            shown.append(candidate)
    return ", ".join(shown) if shown else "-"


def render_markdown(report, session_dir):
    lines = [
        "# Manual QA",
        "",
        f"Status: {report['status']}",
        f"Message: {report['message']}",
        f"Session: {report['session_id']}",
        f"Surface: {report['ui_surface']}",
        f"Hands: {', '.join(report['hands']) if report['hands'] else 'none recorded'}",
        "",
        "## Criteria",
        "",
    ]
    if report["criteria"]:
        lines.append("| # | Kind | Criterion | Outcome | Evidence | Notes |")
        lines.append("|---|---|---|---|---|---|")
        for row in report["criteria"]:
            lines.append(
                f"| {row['index']} | {row['kind']} | {cell(row['text'])} | {row['outcome']} | "
                f"{cell(relative_evidence(row['evidence'], session_dir))} | {cell(row['notes']) or '-'} |"
            )
    else:
        lines.append("- No approved criteria were available to this pass.")
    lines.extend(["", "## Exploratory findings", ""])
    if report["exploratory"]:
        for item in report["exploratory"]:
            reference = f" ({item['reference']})" if item["reference"] else ""
            lines.append(f"- {item['id']} [{item['severity']}, {item['disposition']}{reference}]: {item['title']}")
            lines.append(f"  - Repro: {item['repro']}")
            if item["expected"]:
                lines.append(f"  - Expected: {item['expected']}")
            if item["actual"]:
                lines.append(f"  - Actual: {item['actual']}")
            if item["evidence"]:
                lines.append(f"  - Evidence: {relative_evidence(item['evidence'], session_dir)}")
    else:
        lines.append("- None recorded.")
    lines.extend([
        "",
        "## Provenance",
        "",
        f"- Criteria file: {report['criteria_source']['file'] or 'none'}",
        f"- Approval hash: {report['criteria_source']['approval_hash'] or 'not sealed'}",
        f"- Checkout: {report['checkout_fingerprint'] or 'unknown'}",
        f"- Working tree: {report['working_fingerprint'] or 'unknown'}",
        f"- Updated: {report['updated_at']}",
        "",
        "Do not commit this directory. It is temporary evidence under the Dex artifact root.",
        "",
    ])
    return "\n".join(lines)


def write_outputs(args, report):
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")
    with open(args.markdown, "w", encoding="utf-8") as handle:
        handle.write(render_markdown(report, args.session_dir))


def finalize(args):
    draft = load_json(args.draft)
    if not isinstance(draft, dict):
        raise Invalid("the draft must be a JSON object")
    if draft.get("version") != VERSION or isinstance(draft.get("version"), bool):
        raise Invalid(f"draft.version must be {VERSION}")
    surface = draft.get("ui_surface", "none")
    if surface not in SURFACES:
        raise Invalid(f"draft.ui_surface must be one of {', '.join(SURFACES)}")
    expected = expected_rows(load_json(args.criteria, limit=65536))
    criteria = validate_criteria(draft.get("criteria"), expected, args.session_dir)
    exploratory = validate_exploratory(draft.get("exploratory"), args.session_dir)
    status = derive_status(criteria, exploratory)
    report = build_report(args, criteria, exploratory, status, describe(criteria, exploratory), surface, hands(draft.get("hands")))
    write_outputs(args, report)
    print(status)


def terminal(args):
    reason = text(args.reason, "--reason")
    rows = []
    if args.criteria and os.path.isfile(args.criteria):
        # A criteria file that no longer validates is one of the reasons a pass
        # is blocked, so it must not stop the record of that fact.
        try:
            expected = expected_rows(load_json(args.criteria, limit=65536))
        except Invalid:
            expected = []
        for kind, index, item in expected:
            rows.append({"kind": kind, "index": index, "text": item, "outcome": args.outcome, "evidence": [], "notes": reason})
    report = build_report(args, rows, [], args.outcome, reason, "none", [])
    write_outputs(args, report)
    print(args.outcome)


def validate(args):
    report = load_json(args.report)
    if not isinstance(report, dict) or report.get("status") not in STATUSES:
        raise Invalid("the report has no recognised status")
    if report.get("version") != VERSION:
        raise Invalid(f"report.version must be {VERSION}")
    for key in ("criteria", "exploratory", "hands"):
        if not isinstance(report.get(key), list):
            raise Invalid(f"report.{key} must be a list")
    print(report["status"])


def main(argv):
    parser = argparse.ArgumentParser(prog="qa-report.py", add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)

    def common(sub):
        sub.add_argument("--session-id", required=True)
        sub.add_argument("--session-dir", required=True)
        sub.add_argument("--out", required=True)
        sub.add_argument("--markdown", required=True)
        sub.add_argument("--approval-hash", default="")
        sub.add_argument("--checkout", default="")
        sub.add_argument("--working", default="")

    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("draft")
    finalize_parser.add_argument("--criteria", required=True)
    common(finalize_parser)
    finalize_parser.set_defaults(run=finalize)

    terminal_parser = commands.add_parser("terminal")
    terminal_parser.add_argument("outcome", choices=("BLOCKED", "N_A"))
    terminal_parser.add_argument("--reason", required=True)
    terminal_parser.add_argument("--criteria", default="")
    common(terminal_parser)
    terminal_parser.set_defaults(run=terminal)

    validate_parser = commands.add_parser("validate")
    validate_parser.add_argument("report")
    validate_parser.set_defaults(run=validate)

    status_parser = commands.add_parser("status")
    status_parser.add_argument("report")
    status_parser.set_defaults(run=validate)

    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return USAGE
    try:
        args.run(args)
    except Invalid as error:
        print(f"qa-report: {error}", file=sys.stderr)
        return INVALID
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
