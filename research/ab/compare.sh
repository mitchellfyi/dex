#!/usr/bin/env bash
# Print the paired comparison of two arm metrics files as Markdown.
#
#   compare.sh <metrics-A.json> <metrics-B0.json>
#
# Absolute numbers side by side, then the paired difference. Unavailable
# fields print as "unavailable"; no ratio is computed from an unknown or zero
# baseline. One pair is a smoke test, and the output says so.
set -euo pipefail
[[ $# -eq 2 && -f "$1" && -f "$2" ]] || { echo "Usage: compare.sh <metrics-A.json> <metrics-B0.json>" >&2; exit 2; }
python3 - "$1" "$2" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])

def get(d, path):
    # "events.counts.<type>" keeps the event type whole, since types contain dots.
    if path.startswith("events.counts."):
        counts = (d.get("events") or {}).get("counts") or {}
        return counts.get(path[len("events.counts."):])
    cur = d
    for key in path.split("."):
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur

def cell(v):
    if v is None:
        return "unavailable"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, (int, float)):
        return f"{v:,}"
    return str(v)

def diff(x, y):
    if isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool):
        d = y - x
        if x:
            return f"{d:+,} ({d / x:+.0%})"
        return f"{d:+,} (no ratio: zero baseline)"
    return "n/a"

rows = [
    ("Status", "status"),
    ("Phase reached", "phase_reached"),
    ("Timed out", "time.timed_out"),
    ("Wall seconds to endpoint", "time.wall_seconds"),
    ("Acceptance total (rubric /100)", "acceptance.total"),
    ("  correctness", "acceptance.correctness"),
    ("  test quality", "acceptance.test_quality"),
    ("  verification", "acceptance.verification"),
    ("Prompt tokens total", "tokens.totals.prompt_tokens_total"),
    ("  cache read", "tokens.totals.cache_read_input_tokens"),
    ("  cache creation", "tokens.totals.cache_creation_input_tokens"),
    ("Output tokens", "tokens.totals.output_tokens"),
    ("Requests", "tokens.totals.requests"),
    ("Provider sessions", "tokens.sessions"),
    ("Gate receipts", "receipts.gate_receipts"),
    ("Ungated heavy commands", "receipts.ungated_heavy_commands"),
    ("gate.reused events", "events.counts.gate.reused"),
    ("Review passes started", "events.counts.review.pass.started"),
    ("Heavy gates run (gate.finished)", "events.counts.gate.finished"),
    ("Mission decisions (B0)", "coordination.decisions"),
    ("Self-checks recorded (B0)", "coordination.selfchecks"),
    ("Worktrees", "fragmentation.worktrees"),
    ("Branches (fixture + origin)", "fragmentation.branches_including_origin"),
    ("Lifecycle branch commits", "fragmentation.lifecycle_branch_commits"),
    ("Helper assignments (B0)", "coordination.assignments"),
    ("Lease generations (B0)", "coordination.lease_generations"),
    ("Guard violations (B0)", "coordination.violations"),
]
print(f"# Paired comparison: {a.get('task')} (A vs B0)\n")
print("One pair is a smoke test, not a benchmark. Numbers are measured where available; a missing")
print("measurement is unavailable, not zero.\n")
print("| Metric | A | B0 | B0 minus A |")
print("|---|---|---|---|")
for label, path in rows:
    x, y = get(a, path), get(b, path)
    if path == "tokens.sessions":
        x = len(x) if isinstance(x, list) else None
        y = len(y) if isinstance(y, list) else None
    if label.startswith("gate.reused") or label.startswith("Review passes"):
        x = x if x is not None else (0 if get(a, "events.available") else None)
        y = y if y is not None else (0 if get(b, "events.available") else None)
    print(f"| {label} | {cell(x)} | {cell(y)} | {diff(x, y)} |")
print()
for name, m in (("A", a), ("B0", b)):
    acc = m.get("acceptance", {})
    print(f"- {name} acceptance evaluator: {acc.get('evaluator', 'unavailable')}")
    tok = m.get("tokens", {})
    print(f"- {name} token provenance: {tok.get('provenance', tok.get('reason', 'unavailable'))}")
    if m.get("endpoint_watcher"):
        print(f"- {name} endpoint: {m['endpoint_watcher']}")
PY
