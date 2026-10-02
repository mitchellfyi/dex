#!/usr/bin/env python3
"""Turn what a lifecycle left behind into observations for the memory store.

    lifecycle_harvest.py <session-id> --repo DIR [--state-dir DIR] [--loop-dir DIR]

Reads, when present:

  $DX_LOOP_DIR/<sid>.review-findings.json     review ledger rows
  $DX_STATE_DIR/<sid>.overrides               override / waive / jump journal
  $DX_STATE_DIR/<sid>.phase-outcomes          phase outcome ledger
  $DX_LOOP_DIR/<sid>.gate-receipts/*.json     gate receipts (failed ones)
  $DX_LOOP_DIR/<sid>.gate-receipts/ungated.jsonl
  $DX_LOOP_DIR/<sid>.guard-warnings.jsonl     guard warnings the agent saw

and prints one JSON observation per line: lesson, evidence, scope, type,
signal, session. Findings that were real (fixed or still open) become facts
about their file; overrides, waivers and waived or skipped phases become
decisions with their reason; a failed gate becomes a fact carrying a capped,
redacted log tail; heavy work outside a gate is a measurement; guard warnings
are aggregated per guard. Notes, the implementer's own seeded rows, rejected
findings, passed gates and completed phases are not lessons. No model call;
the output is deterministic for the same artifacts. Standard library only.
"""

import argparse
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import dex_redact  # noqa: E402
except ImportError:  # pragma: no cover - the repository ships it
    dex_redact = None

SECRET_RE = re.compile(r"(?i)\b(token|secret|password|passwd|api[_-]?key|authorization)\b\s*[=:]\s*\S+")
KEY_RE = re.compile(r"\b(?:sk|ghp|gho|xox[baprs]|AKIA)[-_A-Za-z0-9]{8,}\b")
SESSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,179}$")


def redact(text):
    if dex_redact is not None:
        for name in ("redact_text", "redact", "redact_string"):
            func = getattr(dex_redact, name, None)
            if callable(func):
                try:
                    return str(func(text))
                except Exception:  # noqa: BLE001 - fall back to the local rules
                    break
    text = SECRET_RE.sub(lambda m: f"{m.group(1)}=[REDACTED]", text)
    return KEY_RE.sub("[REDACTED]", text)


def cap(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def read_tsv(path):
    """Rows of a header-first TSV as dicts; [] when absent or malformed."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []
    if not lines:
        return []
    header = lines[0].split("\t")
    rows = []
    for line in lines[1:]:
        cells = line.split("\t")
        if len(cells) < len(header):
            cells += [""] * (len(header) - len(cells))
        rows.append(dict(zip(header, cells)))
    return rows


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return []
    return rows


def observation(lesson, evidence, scope, kind, signal, session):
    return {"lesson": cap(lesson, 600), "evidence": cap(evidence, 600), "scope": scope,
            "type": kind, "signal": signal, "session": session}


def harvest_findings(path, session):
    rows = read_json(path)
    out = []
    if not isinstance(rows, list):
        return out
    for row in rows:
        if not isinstance(row, dict):
            continue
        status = row.get("status")
        if status not in ("fixed", "open"):
            continue
        evidence = str(row.get("evidence", "")).strip()
        if "self-review" in evidence.lower():
            continue
        file_name = str(row.get("file", "")).strip()
        lens = str(row.get("lens", "")).strip() or "review"
        if not file_name or not evidence:
            continue
        lesson = f"Review ({lens}) found in {file_name}: {evidence}"
        detail = f"{file_name}; {lens} finding {row.get('id', '?')} of lifecycle {session}, status {status}"
        if row.get("wave_fixed") is not None:
            detail += f", fixed in wave {row.get('wave_fixed')}"
        out.append(observation(lesson, detail, "repo", "fact", "review-finding", session))
    return out


VERB = {"override": "overridden", "waive": "waived", "jump": "jumped"}


def harvest_overrides(path, session):
    out = []
    for row in read_tsv(path):
        action = row.get("action", "")
        if action not in VERB:
            continue
        gate = row.get("gate", "").strip()
        reason = row.get("reason", "").strip()
        if not gate or not reason:
            continue
        phase = row.get("phase", "").strip() or "?"
        value = row.get("value", "").strip()
        lesson = f"Gate {gate} was {VERB[action]} in phase {phase}: {reason}"
        detail = f"{action} by {row.get('source', '?')} in phase {phase} of lifecycle {session}"
        if value:
            detail += f"; value {value}"
        out.append(observation(lesson, detail, "repo", "decision", "override", session))
    return out


def harvest_phase_outcomes(path, session):
    out = []
    for row in read_tsv(path):
        outcome = row.get("outcome", "")
        if outcome not in ("waived", "skipped", "invalidated"):
            continue
        phase = row.get("phase", "").strip() or "?"
        reason = row.get("reason", "").strip() or "no reason recorded"
        lesson = f"Phase {phase} was {outcome}: {reason}"
        detail = f"{outcome} by {row.get('source', '?')} in lifecycle {session}"
        out.append(observation(lesson, detail, "repo", "decision", "phase-outcome", session))
    return out


def log_tail(path, lines=12, per_line=200, total=600):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            tail = handle.read().splitlines()[-lines:]
    except OSError:
        return ""
    text = " | ".join(cap(redact(line), per_line) for line in tail if line.strip())
    return cap(text, total)


def harvest_gates(receipt_dir, session):
    out = []
    for path in sorted(glob.glob(os.path.join(receipt_dir, "*.json"))):
        receipt = read_json(path)
        if not isinstance(receipt, dict):
            continue
        try:
            code = int(receipt.get("exit_code", 0))
        except (TypeError, ValueError):
            continue
        if code == 0:
            continue
        command = receipt.get("command")
        command_text = " ".join(command) if isinstance(command, list) else str(command or "")
        gate = receipt.get("gate") or os.path.splitext(os.path.basename(path))[0]
        lesson = f"Gate {gate} failed (exit {code}): {command_text}"
        tail = log_tail(receipt["log"]) if receipt.get("log") else ""
        detail = f"log tail: {tail}" if tail else f"receipt {os.path.basename(path)} of lifecycle {session}"
        out.append(observation(lesson, detail, "repo", "fact", "gate-failure", session))
    ungated = read_jsonl(os.path.join(receipt_dir, "ungated.jsonl"))
    if ungated:
        example = cap(redact(str(ungated[0].get("command", ""))), 80)
        lesson = (f"{len(ungated)} heavy command(s) ran outside dx run-gate in lifecycle {session}"
                  f" (for example: {example})")
        out.append(observation(lesson, f"{len(ungated)} ungated.jsonl rows of lifecycle {session}",
                               "environment", "measurement", "ungated-heavy", session))
    return out


def harvest_guard_warnings(path, session):
    counts = {}
    examples = {}
    events = {}
    for row in read_jsonl(path):
        guard = str(row.get("guard", "")).strip()
        if not guard:
            continue
        counts[guard] = counts.get(guard, 0) + 1
        examples.setdefault(guard, cap(redact(str(row.get("head", ""))), 100))
        events.setdefault(guard, set()).add(str(row.get("event", "")))
    out = []
    for guard in sorted(counts):
        n = counts[guard]
        times = "time" if n == 1 else "times"
        lesson = f"Guard {guard} warned {n} {times} in lifecycle {session} (for example: {examples[guard]})"
        detail = f"guard {guard}; {n} warnings on {', '.join(sorted(e for e in events[guard] if e))} tool calls"
        out.append(observation(lesson, detail, "repo", "fact", "guard-warning", session))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description="Harvest a lifecycle's artifacts into observations")
    parser.add_argument("session_id")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--state-dir", default=os.environ.get("DX_STATE_DIR") or os.path.expanduser("~/.claude/.dex-phases"))
    parser.add_argument("--loop-dir", default=os.environ.get("DX_LOOP_DIR") or os.path.expanduser("~/.claude/.dex-loops"))
    args = parser.parse_args(argv)
    session = args.session_id
    if not SESSION_RE.match(session):
        print("lifecycle_harvest: invalid session id", file=sys.stderr)
        return 2
    rows = []
    rows += harvest_findings(os.path.join(args.loop_dir, f"{session}.review-findings.json"), session)
    rows += harvest_overrides(os.path.join(args.state_dir, f"{session}.overrides"), session)
    rows += harvest_phase_outcomes(os.path.join(args.state_dir, f"{session}.phase-outcomes"), session)
    rows += harvest_gates(os.path.join(args.loop_dir, f"{session}.gate-receipts"), session)
    rows += harvest_guard_warnings(os.path.join(args.loop_dir, f"{session}.guard-warnings.jsonl"), session)
    for row in rows:
        print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
