#!/usr/bin/env bash
set -euo pipefail

# Claims in AGENTS.md and .dex/dex.md that can be checked against the tree.
#
# These are the ones that had gone stale, each found by reading rather than by
# anything failing: a module table missing a module, a "23 modules" count, a
# guard list, a skill count, a file-size claim. Documentation an agent reads as
# instructions is worth the same guard rail as code.
#
# Only mechanically derivable claims belong here. Prose about intent cannot be
# checked and should not be forced into a shape that can be.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
agents = (root / "AGENTS.md").read_text(encoding="utf-8")
dex_md = (root / ".dex/dex.md").read_text(encoding="utf-8")
problems = []


def tracked(pattern):
    return subprocess.run(
        ["git", "-C", str(root), "ls-files", pattern],
        capture_output=True, text=True, check=True,
    ).stdout.split()


# The lib module table must name every module, and only real ones.
tabled = set(re.findall(r"^\| `([a-z-]+\.sh)` \|", agents, re.M))
on_disk = {Path(p).name for p in tracked("lib/*.sh")}
if tabled != on_disk:
    problems.append(
        "AGENTS.md lib module table is out of step with lib/: "
        f"only in the table {sorted(tabled - on_disk)}, "
        f"only on disk {sorted(on_disk - tabled)}"
    )

# The list of what sourcing common.sh pulls in, and its count.
sourced = set(re.findall(r"__dx_require_lib ([a-z-]+\.sh)", (root / "lib/common.sh").read_text()))
count = re.search(r"Shared shell libraries \((\d+) modules sourced by common\.sh", agents)
if count and int(count.group(1)) != len(sourced):
    problems.append(
        f"AGENTS.md says {count.group(1)} modules are sourced by common.sh; it sources {len(sourced)}"
    )
listing = re.search(r"Sourcing `common\.sh` also sources.*?\n\n", agents, re.S)
if listing:
    listed = set(re.findall(r"`([a-z-]+\.sh)`", listing.group(0))) - {"common.sh"}
    if listed != sourced:
        problems.append(
            "the common.sh source list in AGENTS.md is out of step: "
            f"only listed {sorted(listed - sourced)}, only sourced {sorted(sourced - listed)}"
        )

# Every built-in guard must be named, so nobody writes a duplicate of one.
guards = set()
for path in tracked("hooks/guards/*.md"):
    name = re.search(r"^name: (\S+)", (root / path).read_text(encoding="utf-8"), re.M)
    if name:
        guards.add(name.group(1))
undocumented = guards - set(re.findall(r"`(warn-[a-z-]+)`", agents))
if undocumented:
    problems.append(f"built-in guards not named in AGENTS.md: {sorted(undocumented)}")

# The hook table must match settings.json in both directions.
settings = json.loads((root / "settings.json").read_text(encoding="utf-8"))
wired = set()
for event, entries in settings.get("hooks", {}).items():
    for entry in entries:
        for hook in entry.get("hooks", []):
            script = re.search(r"(hooks/[A-Za-z0-9._-]+)", hook.get("command", ""))
            if script:
                wired.add((event, script.group(1)))
table = re.search(r"\| Hook \| Matcher \| Script \| Purpose \|(.*?)\n\n", agents, re.S)
documented = set()
if table:
    for row in table.group(1).strip().splitlines()[1:]:
        cells = [cell.strip() for cell in row.strip("|").split("|")]
        if len(cells) >= 3:
            for script in re.findall(r"`([a-z0-9.-]+\.(?:sh|py))`", cells[2]):
                documented.add((cells[0], f"hooks/{script}"))
if wired != documented:
    problems.append(
        "the hook table in AGENTS.md is out of step with settings.json: "
        f"only wired {sorted(wired - documented)}, only documented {sorted(documented - wired)}"
    )

# Counts and sizes quoted in prose.
skills = len(tracked("skills/*/SKILL.md"))
claimed_skills = re.search(r"Lifecycle skills \((\d+) total", dex_md)
if claimed_skills and int(claimed_skills.group(1)) != skills:
    problems.append(f".dex/dex.md says {claimed_skills.group(1)} skills; there are {skills}")

dx_lines = len((root / "dx.sh").read_text(encoding="utf-8").splitlines())
for match in re.finditer(r"~(\d{3,5}) lines", agents + dex_md):
    claimed = int(match.group(1))
    # Only the dx.sh claims are in this range; allow drift within a rounding step.
    if 2000 < claimed < 6000 and abs(claimed - dx_lines) > 150:
        problems.append(f"dx.sh is described as ~{claimed} lines; it is {dx_lines}")

if problems:
    for problem in problems:
        print(f"docs: {problem}", file=sys.stderr)
    raise SystemExit(1)

print(
    f"docs-consistency: {len(on_disk)} lib modules, {len(guards)} guards, "
    f"{len(wired)} hooks, {skills} skills all match the docs"
)
PY

printf 'documentation consistency tests passed\n'
