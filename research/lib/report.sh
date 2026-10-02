#!/usr/bin/env bash
# Research harness — reporting
# TSV append, summary.json generation, and terminal output.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# report_init_tsv
# Create the scores.tsv header if it doesn't exist.
report_init_tsv() {
  if [[ ! -f "$SCORES_TSV" ]]; then
    mkdir -p "$(dirname "$SCORES_TSV")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "run_id" "timestamp" "iteration" "scenario" \
      "correctness" "test_quality" "robustness" "verification" \
      "issue_detection" "code_quality" "total" \
      "dx_commit" "duration_s" "cost_usd" \
      > "$SCORES_TSV"
  fi
}

# report_append_score <run_id> <iteration> <scenario> <result_dir>
# Append a scenario's score to scores.tsv.
report_append_score() {
  local run_id="$1" iteration="$2" scenario="$3" result_dir="$4"

  report_init_tsv

  local rubric_file="$result_dir/rubric-results.json"
  local timing_file="$result_dir/timing.json"

  if [[ ! -f "$rubric_file" ]]; then
    log_warn "No rubric results for $scenario, skipping TSV append"
    return
  fi

  # Extract scores
  local correctness test_quality robustness verification issue_detection code_quality total
  correctness=$(json_field "$rubric_file" "correctness")
  test_quality=$(json_field "$rubric_file" "test_quality")
  robustness=$(json_field "$rubric_file" "robustness")
  verification=$(json_field "$rubric_file" "verification")
  issue_detection=$(json_field "$rubric_file" "issue_detection")
  code_quality=$(json_field "$rubric_file" "code_quality")
  total=$(json_field "$rubric_file" "total")

  # Extract timing
  local duration="0" cost="0.00"
  if [[ -f "$timing_file" ]]; then
    duration=$(json_field "$timing_file" "duration_s")
  fi

  local dx_commit
  dx_commit=$(dx_commit_hash)
  local timestamp
  timestamp=$(date +%s)

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$timestamp" "$iteration" "$scenario" \
    "$correctness" "$test_quality" "$robustness" "$verification" \
    "$issue_detection" "$code_quality" "$total" \
    "$dx_commit" "$duration" "$cost" \
    >> "$SCORES_TSV"
}

# report_summary <run_id> <run_result_dir>
# Generate summary.json from all scenario results in a run.
report_summary() {
  local run_id="$1" run_dir="$2"

  python3 - "$run_dir" "$run_id" <<'PYEOF'
import json, sys, os, glob

run_dir = sys.argv[1]
run_id = sys.argv[2]

scenarios = {}
totals = []

for rubric_file in sorted(glob.glob(os.path.join(run_dir, "*/rubric-results.json"))):
    with open(rubric_file) as f:
        data = json.load(f)
    scenario = data["scenario"]
    scenarios[scenario] = data
    totals.append(data["total"])

summary = {
    "run_id": run_id,
    "scenario_count": len(scenarios),
    "aggregate_score": round(sum(totals) / len(totals), 1) if totals else 0,
    "min_score": min(totals) if totals else 0,
    "max_score": max(totals) if totals else 0,
    "scenarios": scenarios,
}

summary_path = os.path.join(run_dir, "summary.json")
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")

print(json.dumps(summary, indent=2))
PYEOF
}

# report_table <run_result_dir>
# Print a formatted score table to the terminal.
report_table() {
  local run_dir="$1"

  python3 - "$run_dir" <<'PYEOF'
import json, sys, os, glob

run_dir = sys.argv[1]

# Collect all results
results = []
for rubric_file in sorted(glob.glob(os.path.join(run_dir, "*/rubric-results.json"))):
    with open(rubric_file) as f:
        results.append(json.load(f))

if not results:
    print("No results found.")
    sys.exit(0)

# Header
dims = ["correctness", "test_quality", "robustness", "verification", "issue_detection", "code_quality", "total"]
labels = ["Correct", "Tests", "Robust", "Verify", "Issues", "Quality", "TOTAL"]

# Column widths
name_w = max(len(r["scenario"]) for r in results) + 2
col_w = 8

# Print header
header = f"{'Scenario':<{name_w}}"
for label in labels:
    header += f"{label:>{col_w}}"
print()
print("=" * len(header))
print(header)
print("-" * len(header))

# Print rows
totals_sum = 0
for r in results:
    row = f"{r['scenario']:<{name_w}}"
    for dim in dims:
        val = r.get(dim, 0)
        # Color coding: green >= 80, yellow >= 50, red < 50
        if dim == "total":
            row += f"{val:>{col_w}}"
        else:
            row += f"{val:>{col_w}}"
    print(row)
    totals_sum += r["total"]

print("-" * len(header))
avg = round(totals_sum / len(results), 1)
print(f"{'AVERAGE':<{name_w}}" + " " * (col_w * (len(labels) - 1)) + f"{avg:>{col_w}}")
print("=" * len(header))
print()
PYEOF
}

# report_comparison <prev_summary_json> <curr_summary_json>
# Print a side-by-side comparison of two runs.
report_comparison() {
  local prev="$1" curr="$2"

  python3 - "$prev" "$curr" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    prev = json.load(f)
with open(sys.argv[2]) as f:
    curr = json.load(f)

print()
print(f"{'Scenario':<30} {'Previous':>10} {'Current':>10} {'Delta':>10}")
print("-" * 62)

prev_scenarios = prev.get("scenarios", {})
curr_scenarios = curr.get("scenarios", {})
all_names = sorted(set(list(prev_scenarios.keys()) + list(curr_scenarios.keys())))

for name in all_names:
    p = prev_scenarios.get(name, {}).get("total", 0)
    c = curr_scenarios.get(name, {}).get("total", 0)
    delta = c - p
    sign = "+" if delta > 0 else ""
    print(f"{name:<30} {p:>10} {c:>10} {sign}{delta:>9}")

print("-" * 62)
prev_avg = prev.get("aggregate_score", 0)
curr_avg = curr.get("aggregate_score", 0)
delta = round(curr_avg - prev_avg, 1)
sign = "+" if delta > 0 else ""
print(f"{'AVERAGE':<30} {prev_avg:>10} {curr_avg:>10} {sign}{delta:>9}")
print()
PYEOF
}
