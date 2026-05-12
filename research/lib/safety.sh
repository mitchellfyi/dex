#!/usr/bin/env bash
# Research harness — safety layer
# Regression gating, auto-revert, cost tracking, branch protection.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# safety_check_branch
# Abort if on main/master.
safety_check_branch() {
  if is_main_branch; then
    log_error "Refusing to run improvement loop on main/master branch."
    log_error "Create a research branch first: git checkout -b research/improve-\$(date +%Y%m%d)"
    return 1
  fi
}

# safety_check_clean
# Abort if there are uncommitted changes in the DK repo.
safety_check_clean() {
  if [[ -n "$(git -C "$DOYAKEN_DIR" status --porcelain 2>/dev/null)" ]]; then
    log_error "DK repo has uncommitted changes. Commit or stash them first."
    return 1
  fi
}

# safety_tag_checkpoint <iteration>
# Create a git tag before applying improvements.
safety_tag_checkpoint() {
  local iter="$1"
  local tag="dk-research/pre-iter-${iter}"
  git -C "$DOYAKEN_DIR" tag -f "$tag" HEAD 2>/dev/null
  log_info "Tagged checkpoint: $tag"
}

# safety_revert_to_checkpoint <iteration>
# Revert DK repo to the checkpoint tag for a given iteration.
safety_revert_to_checkpoint() {
  local iter="$1"
  local tag="dk-research/pre-iter-${iter}"

  if ! git -C "$DOYAKEN_DIR" rev-parse --verify "$tag" &>/dev/null; then
    log_error "Checkpoint tag $tag not found"
    return 1
  fi

  log_warn "Reverting to checkpoint: $tag"
  git -C "$DOYAKEN_DIR" reset --hard "$tag" 2>/dev/null
  log_success "Reverted to $tag"
}

# safety_check_regression <prev_summary_json> <curr_summary_json>
# Returns 0 if no regression, 1 if regression detected.
safety_check_regression() {
  local prev="$1" curr="$2"

  python3 - "$prev" "$curr" "$REGRESSION_THRESHOLD" "$SCENARIO_REGRESSION_THRESHOLD" <<'PYEOF'
import json, sys

prev_file, curr_file = sys.argv[1], sys.argv[2]
agg_threshold = float(sys.argv[3])
scenario_threshold = float(sys.argv[4])

with open(prev_file) as f:
    prev = json.load(f)
with open(curr_file) as f:
    curr = json.load(f)

prev_avg = prev.get("aggregate_score", 0)
curr_avg = curr.get("aggregate_score", 0)

# Check aggregate regression
agg_drop = prev_avg - curr_avg
if agg_drop > agg_threshold:
    print(f"REGRESSION: Aggregate score dropped by {agg_drop:.1f}% ({prev_avg:.1f} -> {curr_avg:.1f})")
    sys.exit(1)

# Check per-scenario regression
prev_scenarios = prev.get("scenarios", {})
curr_scenarios = curr.get("scenarios", {})

for name in prev_scenarios:
    if name in curr_scenarios:
        p = prev_scenarios[name].get("total", 0)
        c = curr_scenarios[name].get("total", 0)
        drop = p - c
        if drop > scenario_threshold:
            print(f"REGRESSION: {name} dropped by {drop} points ({p} -> {c})")
            sys.exit(1)

print("OK: No regression detected")
sys.exit(0)
PYEOF
}

# safety_validate_diff
# Check that a git diff only touches allowed files.
# Reads diff from stdin.
safety_validate_diff() {
  python3 -c '
import sys, fnmatch

patterns = sys.argv[1:]
violations = []

def clean_path(path):
    path = path.strip()
    if path in {"", "/dev/null"}:
        return ""
    if path[:1] == chr(34) and path[-1:] == chr(34):
        path = path[1:-1]
    if path.startswith("a/") or path.startswith("b/"):
        path = path[2:]
    return path

def check_path(path):
    path = clean_path(path)
    if not path:
        return
    if not any(fnmatch.fnmatch(path, p) for p in patterns):
        violations.append(path)

for line in sys.stdin:
    line = line.strip()
    if line.startswith("diff --git "):
        parts = line.split()
        if len(parts) < 4:
            violations.append(f"unparseable diff header: {line}")
            continue
        check_path(parts[2])
        check_path(parts[3])
        continue
    if line.startswith("--- ") or line.startswith("+++ "):
        parts = line.split(maxsplit=1)
        if len(parts) < 2:
            violations.append(f"unparseable file header: {line}")
            continue
        check_path(parts[1])
        continue
    if line.startswith("rename from ") or line.startswith("rename to "):
        check_path(line.split(" ", 2)[2] if len(line.split(" ", 2)) == 3 else "")
        continue
    if line.startswith(("old mode ", "new mode ", "deleted file mode ", "new file mode ")):
        continue
    if line.startswith(("index ", "similarity index ", "dissimilarity index ")):
        continue

if violations:
    print("SCOPE VIOLATION: Changes touch files outside allowed patterns:")
    for v in sorted(set(violations)):
        print(f"  - {v}")
    sys.exit(1)

print("OK: All changes within allowed scope")
sys.exit(0)
' "${ALLOWED_MODIFY_PATTERNS[@]}"
}

# safety_cost_check <cumulative_usd>
# Returns 1 if cost limit exceeded.
safety_cost_check() {
  local cumulative="$1"
  local limit="${COST_LIMIT:-$COST_LIMIT_USD}"

  CUMULATIVE_COST="$cumulative" COST_LIMIT_EFFECTIVE="$limit" python3 -c "
import os, sys
cumulative = float(os.environ['CUMULATIVE_COST'])
limit = float(os.environ['COST_LIMIT_EFFECTIVE'])
if cumulative > limit:
    print(f'COST LIMIT: \${cumulative:.2f} exceeds limit of \${limit:.2f}')
    sys.exit(1)
print(f'Cost OK: \${cumulative:.2f} / \${limit:.2f}')
sys.exit(0)
"
}

# safety_cleanup_tags
# Remove all dk-research tags.
safety_cleanup_tags() {
  git -C "$DOYAKEN_DIR" tag -l "dk-research/*" | while read -r tag; do
    git -C "$DOYAKEN_DIR" tag -d "$tag" 2>/dev/null
  done
  log_info "Cleaned up research tags"
}
