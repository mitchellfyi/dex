"""Read the review telemetry Dex already writes and report it per risk tier.

The point is to set the tier defaults from data instead of opinion. Every
number here comes from `~/.dex/runs/*/events.jsonl`: `review.tier.selected`
opens a loop, `review.pass.finished` records each wave's result kind, findings
count and duration, and `review.completed` with `reason=clean_gate_reached`
says the loop reached its gate.

Two of these columns exist to answer one question — whether requiring more than
one consecutive clean pass buys anything measurable. "found after clean" counts
the passes that ran with clean credit already banked and still found something;
"reversed a clean" counts how many loops had at least one of those. If both
stay at zero over a meaningful sample, the extra confirmation passes are
costing time and buying nothing, and the defaults should change. Publish the
numbers in the PR that changes one.
"""

import json
import os
import statistics
import sys
from pathlib import Path

TIER_ORDER = ["trivial", "small", "normal", "complex"]
FOUND_KINDS = {"findings", "findings_fixed"}
CLEAN_KINDS = {"clean", "notes"}


class Loop:
    """One review loop: a run's tier selection and every pass that followed.

    A journal holds one loop until that loop finishes. A resumed or re-invoked
    loop emits another `review.tier.selected` into the same file, and counting
    those as separate loops is what turned 66 real loops into 170 rows with a
    median of two passes each — the opposite of the "10 passes, 156 minutes"
    the report exists to show. A selection *after* a `review.completed` is a
    different story: that loop ended, and the next one is its own row, or a
    second stall in the same journal disappears behind the first one's gate.
    """

    def __init__(self, tier):
        self.tier = tier
        self.closed = False
        self.passes = 0
        self.seconds = 0
        self.findings = 0
        self.after_clean = 0
        self.after_clean_found = 0
        self.reversed_clean = False
        self.completed = False
        self.first_clean_seconds = None

    def raise_tier(self, tier):
        """A loop keeps the deepest tier it ran at; review never downgrades."""
        if tier not in TIER_ORDER:
            return
        if self.tier not in TIER_ORDER or TIER_ORDER.index(tier) > TIER_ORDER.index(self.tier):
            self.tier = tier


def event_name(event):
    """The event's name. It is `type` in the run log and `name` in some
    exported copies; `event` is not a field either of them uses."""
    for field in ("type", "name"):
        value = event.get(field)
        if isinstance(value, str) and value:
            return value
    return ""


def collect(root):
    """One loop per run journal, in name order."""
    loops = []
    for events_file in sorted(Path(root).glob("*/events.jsonl")):
        current = None
        try:
            with events_file.open("r", encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(event, dict):
                        continue
                    data = event.get("data")
                    data = data if isinstance(data, dict) else {}
                    name = event_name(event)
                    if name not in {
                        "review.tier.selected", "review.tier.escalated",
                        "review.pass.finished", "review.completed",
                    }:
                        continue
                    if current is None or (
                        current.closed and name == "review.tier.selected"
                    ):
                        current = Loop("unknown")
                        loops.append(current)
                    if name in {"review.tier.selected", "review.tier.escalated"}:
                        current.raise_tier(data.get("tier"))
                        continue
                    if name == "review.completed":
                        current.raise_tier(data.get("tier"))
                        current.closed = True
                        if data.get("reason") == "clean_gate_reached":
                            current.completed = True
                        continue
                    current.passes += 1
                    duration = data.get("duration_seconds")
                    duration = duration if isinstance(duration, int) and not isinstance(duration, bool) else 0
                    current.seconds += max(0, duration)
                    kind = data.get("result_kind")
                    found = data.get("findings")
                    found = found if isinstance(found, int) and not isinstance(found, bool) else 0
                    before = data.get("clean_before")
                    before = before if isinstance(before, int) and not isinstance(before, bool) else 0
                    if kind in FOUND_KINDS:
                        current.findings += found
                    if kind in CLEAN_KINDS and current.first_clean_seconds is None:
                        current.first_clean_seconds = current.seconds
                    if before >= 1:
                        current.after_clean += 1
                        if kind in FOUND_KINDS:
                            current.after_clean_found += 1
                            current.reversed_clean = True
        except OSError:
            continue
    return [loop for loop in loops if loop.passes or loop.completed]


def median(values):
    return statistics.median(values) if values else 0


def report(loops):
    """One row per tier, plus a total row. Returns the lines to print."""
    rows = []
    tiers = [tier for tier in TIER_ORDER if any(loop.tier == tier for loop in loops)]
    tiers += sorted({loop.tier for loop in loops} - set(TIER_ORDER))
    for tier in tiers + ["all"]:
        scoped = loops if tier == "all" else [loop for loop in loops if loop.tier == tier]
        if not scoped:
            continue
        after_clean = sum(loop.after_clean for loop in scoped)
        after_clean_found = sum(loop.after_clean_found for loop in scoped)
        # Time to first clean is the number Item 12 asks a human to watch: it
        # says when intervening at pass 4 beats waiting for pass 14. Loops that
        # never went clean have no value to contribute, so they are left out
        # rather than counted as zero.
        first_clean = [round(loop.first_clean_seconds / 60) for loop in scoped
                       if loop.first_clean_seconds is not None]
        rows.append({
            "tier": tier,
            "loops": len(scoped),
            "passes_per_loop": median([loop.passes for loop in scoped]),
            "minutes_per_loop": median([round(loop.seconds / 60) for loop in scoped]),
            "minutes_to_first_clean": median(first_clean),
            "loops_reaching_clean": len(first_clean),
            "reached_gate": sum(1 for loop in scoped if loop.completed),
            "never_reached": sum(1 for loop in scoped if not loop.completed),
            "passes_after_clean": after_clean,
            "found_after_clean": after_clean_found,
            "found_after_clean_share": round(100 * after_clean_found / after_clean) if after_clean else 0,
            "loops_reversing_clean": sum(1 for loop in scoped if loop.reversed_clean),
        })
    return rows


def render(rows):
    header = (
        f"{'tier':<9}{'loops':>6}{'passes':>8}{'minutes':>9}{'1st clean':>11}"
        f"{'of':>4}{'gate':>6}{'stalled':>9}{'conf':>6}{'found':>7}{'share':>7}"
        f"{'reversed':>10}"
    )
    lines = [header, "-" * len(header)]
    for row in rows:
        lines.append(
            f"{row['tier']:<9}{row['loops']:>6}{row['passes_per_loop']:>8}"
            f"{row['minutes_per_loop']:>9}{row['minutes_to_first_clean']:>11}"
            f"{row['loops_reaching_clean']:>4}{row['reached_gate']:>6}"
            f"{row['never_reached']:>9}"
            f"{row['passes_after_clean']:>6}{row['found_after_clean']:>7}"
            f"{str(row['found_after_clean_share']) + '%':>7}"
            f"{row['loops_reversing_clean']:>10}"
        )
    lines.append("")
    lines.append("One loop per run, ended by its completion event. passes/minutes and 1st")
    lines.append("clean are medians; 1st clean is minutes to the first clean or notes pass,")
    lines.append("over the `of` loops that got one. gate: loops that reached the clean gate;")
    lines.append("stalled: loops that never did. conf: passes that ran with clean credit")
    lines.append("already banked; found: how many of those found something; reversed: loops")
    lines.append("where one of them reversed an earlier clean pass.")
    return "\n".join(lines)


def main(arguments):
    root = os.environ.get("DX_RUN_ROOT") or str(Path.home() / ".dex/runs")
    as_json = False
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--json":
            as_json = True
        elif argument == "--root" and index + 1 < len(arguments):
            index += 1
            root = arguments[index]
        else:
            print(f"review stats: unknown argument {argument}", file=sys.stderr)
            return 2
        index += 1
    if not Path(root).is_dir():
        print(f"review stats: no run telemetry under {root}", file=sys.stderr)
        return 1
    rows = report(collect(root))
    if not rows:
        print(f"review stats: no review loops recorded under {root}", file=sys.stderr)
        return 1
    print(json.dumps(rows, indent=1, sort_keys=True) if as_json else render(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
