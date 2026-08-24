#!/usr/bin/env python3
"""Compare each scenario's floor against the scores runs have actually reached.

seed-baseline.sh says what a rubric awards for doing nothing. This says what
the recorded runs did with the rest of the scale, which is the other half of
the same question: a dimension whose real scores sit at its floor is not
separating anything, whatever the weight on it says.

A ceiling would be the direct measure, but research/scenarios ships no
reference solutions — only the review-loop tree has canonical fixes. The score
history answers it empirically instead, and needs nothing that does not already
exist.

  python3 research/observed-range.py

The line worth reading is the last: dimensions that have never varied. Those
contribute a fixed offset to a scenario's total and no information at all. Some
are deliberate — a planning scenario declares `echo 30  # not applicable` for
test quality — and the rest are worth a look.
"""

import csv
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DIMENSIONS = ('correctness', 'test_quality', 'robustness', 'issue_detection')

# Floors, as reported by research/seed-baseline.sh.
floors = {}
output = subprocess.run(
    ['bash', 'research/seed-baseline.sh'], cwd=REPO,
    capture_output=True, text=True,
).stdout
for line in output.splitlines():
    parts = line.split()
    if len(parts) == 7 and parts[1] in {'seed', 'empty'}:
        name, start = parts[0], parts[1]
        values = []
        for raw in parts[2:6]:
            values.append(int(raw) if raw.isdigit() else None)
        floors[name] = (start, values)

# Observed scores.
observed = defaultdict(lambda: defaultdict(list))
with (REPO / 'research/results/scores.tsv').open() as handle:
    for row in csv.DictReader(handle, delimiter='\t'):
        for dimension in DIMENSIONS:
            raw = (row.get(dimension) or '').strip()
            if raw.lstrip('-').isdigit():
                observed[row['scenario']][dimension].append(int(raw))

print(f"{'scenario':<30} {'start':<6} {'dimension':<16} {'floor':>5} "
      f"{'runs':>5} {'min':>4} {'med':>4} {'max':>4}  {'used above floor'}")
print('-' * 108)

for name in sorted(floors):
    start, values = floors[name]
    if name not in observed:
        print(f'{name:<30} {start:<6} {"(no recorded runs)":<16}')
        continue
    for dimension, floor in zip(DIMENSIONS, values):
        scores = sorted(observed[name].get(dimension, []))
        if floor is None or not scores:
            continue
        median = scores[len(scores) // 2]
        headroom = 100 - floor
        used = max(scores) - floor
        share = f'{used}/{headroom}' if headroom else 'floor is 100'
        print(f'{name:<30} {start:<6} {dimension:<16} {floor:>5} {len(scores):>5} '
              f'{scores[0]:>4} {median:>4} {scores[-1]:>4}  {share}')

constant = [
    (name, dimension, scores)
    for name in sorted(observed)
    for dimension, scores in observed[name].items()
    if len(scores) > 1 and len(set(scores)) == 1
]
if constant:
    print()
    print('Never varied across the recorded runs:')
    for name, dimension, scores in constant:
        print(f'  {name:<30} {dimension:<16} constant at {scores[0]} '
              f'across {len(scores)} runs')
