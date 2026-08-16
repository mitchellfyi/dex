#!/usr/bin/env bash
# Research harness — safety layer
# Regression gating, auto-revert, cost tracking, branch protection.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# safety_check_branch
# Abort if on main/master unless the caller explicitly opted into main mode.
safety_check_branch() {
  if is_main_branch; then
    if [[ "${RESEARCH_ALLOW_MAIN:-0}" == "1" ]]; then
      log_warn "Running research workflow on $(dx_branch) because RESEARCH_ALLOW_MAIN=1"
      return 0
    fi

    log_error "Refusing to run improvement loop on main/master branch."
    log_error "To run on main intentionally, pass --allow-main or set RESEARCH_ALLOW_MAIN=1."
    log_error "Create a research branch first: git checkout -b research/improve-\$(date +%Y%m%d)"
    return 1
  fi
}

# safety_check_clean
# Abort if there are uncommitted changes in the DX repo.
safety_check_clean() {
  if [[ -n "$(git -C "$DEX_DIR" status --porcelain 2>/dev/null)" ]]; then
    log_error "DX repo has uncommitted changes. Commit or stash them first."
    return 1
  fi
}

# safety_tag_checkpoint <iteration>
# Create a git tag before applying improvements. Nothing in the harness
# consumes these tags; they exist so a human can find the pre-patch commit
# after an aborted or misbehaving run.
safety_tag_checkpoint() {
  local iter="$1"
  local tag="dx-research/pre-iter-${iter}"
  git -C "$DEX_DIR" tag -f "$tag" HEAD 2>/dev/null
  log_info "Tagged checkpoint: $tag"
}

# safety_apply_patch <patch-file>
# Apply a generated patch: individual .N parts first (better fuzz/offset
# tolerance than one combined diff), the combined file when no parts exist.
# Records which parts applied in <patch-file>.applied-parts so
# safety_reverse_patch can undo exactly those, and only counts success when
# at least one part landed.
safety_apply_patch() {
  local patch_file="$1"
  local applied=0 part_idx=0
  local applied_record="${patch_file}.applied-parts"

  if [[ -z "$patch_file" || ! -f "$patch_file" ]]; then
    log_error "Patch file not found: $patch_file"
    return 1
  fi

  : > "$applied_record"
  while [[ -f "${patch_file}.${part_idx}" ]]; do
    if (cd "$DEX_DIR" && patch -p1 --fuzz=3 --no-backup-if-mismatch < "${patch_file}.${part_idx}" 2>/dev/null); then
      applied=$((applied + 1))
      printf '%s\n' "${patch_file}.${part_idx}" >> "$applied_record"
    else
      log_warn "Patch part $part_idx failed to apply"
    fi
    part_idx=$((part_idx + 1))
  done

  if [[ $part_idx -eq 0 ]]; then
    if (cd "$DEX_DIR" && patch -p1 --fuzz=3 --no-backup-if-mismatch < "$patch_file" 2>/dev/null); then
      applied=1
      printf '%s\n' "$patch_file" >> "$applied_record"
    fi
  fi

  if [[ $applied -eq 0 ]]; then
    rm -f "$applied_record"
    return 1
  fi
  log_info "Applied $applied patch part(s)"
  return 0
}

# safety_reverse_patch <patch-file>
# Remove an uncommitted generated patch without rewriting branch history.
# When safety_apply_patch recorded which parts applied, every one of them
# must reverse — a partial reversal used to report success and leave the
# repo half-reverted against a wrong baseline.
safety_reverse_patch() {
  local patch_file="$1"
  local part_idx=0
  local reversed=0
  local parts=()
  local part
  local applied_record="${patch_file}.applied-parts"

  if [[ -z "$patch_file" || ! -f "$patch_file" ]]; then
    log_error "Patch file not found: $patch_file"
    return 1
  fi

  if [[ -s "$applied_record" ]]; then
    while IFS= read -r part; do
      [[ -n "$part" && -f "$part" ]] || { log_error "Recorded patch part missing: $part"; return 1; }
      parts+=("$part")
    done < "$applied_record"
    for ((part_idx=${#parts[@]} - 1; part_idx >= 0; part_idx--)); do
      part="${parts[$part_idx]}"
      if ! (cd "$DEX_DIR" && patch -p1 --reverse --dry-run --fuzz=3 --no-backup-if-mismatch < "$part" >/dev/null 2>&1) ||
         ! (cd "$DEX_DIR" && patch -p1 --reverse --fuzz=3 --no-backup-if-mismatch < "$part" >/dev/null); then
        log_error "Could not reverse applied patch part: $part"
        return 1
      fi
      reversed=$((reversed + 1))
    done
    rm -f "$applied_record"
    log_success "Reversed $reversed applied patch part(s)"
    return 0
  fi

  if git -C "$DEX_DIR" apply --reverse --check "$patch_file" 2>/dev/null; then
    git -C "$DEX_DIR" apply --reverse "$patch_file"
    log_success "Reversed generated patch"
    return 0
  fi

  while [[ -f "${patch_file}.${part_idx}" ]]; do
    parts+=("${patch_file}.${part_idx}")
    part_idx=$((part_idx + 1))
  done

  if [[ ${#parts[@]} -eq 0 ]]; then
    parts=("$patch_file")
  fi

  for ((part_idx=${#parts[@]} - 1; part_idx >= 0; part_idx--)); do
    part="${parts[$part_idx]}"
    if (cd "$DEX_DIR" && patch -p1 --reverse --dry-run --fuzz=3 --no-backup-if-mismatch < "$part" >/dev/null 2>&1); then
      (cd "$DEX_DIR" && patch -p1 --reverse --fuzz=3 --no-backup-if-mismatch < "$part" >/dev/null)
      reversed=$((reversed + 1))
    fi
  done

  if [[ $reversed -gt 0 ]]; then
    log_success "Reversed $reversed generated patch part(s)"
    return 0
  fi

  log_error "Could not reverse generated patch cleanly"
  return 1
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
if limit <= 0:
    print(f'Cost tracking: \${cumulative:.2f} spent; no limit configured')
    sys.exit(0)
if cumulative > limit:
    print(f'COST LIMIT: \${cumulative:.2f} exceeds limit of \${limit:.2f}')
    sys.exit(1)
print(f'Cost OK: \${cumulative:.2f} / \${limit:.2f}')
sys.exit(0)
"
}
