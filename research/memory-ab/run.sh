#!/usr/bin/env bash
# Memory on/off comparison on one A/B task.
#
#   bash research/memory-ab/run.sh --task <scenario> --trial-root DIR [--dex-dir DIR]
#                                  [--max-minutes N] [--seed-only] [--dry-run]
#
# Three runs of the same arm (B0, the candidate Dex) on the same fixture task,
# in sequence:
#
#   seed   a fresh store; the lifecycle's harvest and observations fill it
#   on     a copy of the seeded store, memory injected at session and helper start
#   off    the same copy, DEX_MEMORY_RETRIEVAL=0, so nothing is injected
#
# `on` and `off` differ only in that switch. Metrics come from
# research/ab/collect.sh for each run; compare.md puts them side by side.
# Three runs are a pilot: they show whether the pipeline moves the numbers at
# all, not a result. Agent runs vary by several points between replicates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TASK="" TRIAL_ROOT="" DEX_DIR_ARG="" MAX_MINUTES="" SEED_ONLY=0 DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="${2:-}"; shift 2 ;;
    --trial-root) TRIAL_ROOT="${2:-}"; shift 2 ;;
    --dex-dir) DEX_DIR_ARG="${2:-}"; shift 2 ;;
    --max-minutes) MAX_MINUTES="${2:-}"; shift 2 ;;
    --seed-only) SEED_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Usage: run.sh --task <scenario> --trial-root DIR [--dex-dir DIR] [--max-minutes N] [--seed-only] [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ -n "$TASK" && -n "$TRIAL_ROOT" ]] || { echo "memory-ab: --task and --trial-root are required" >&2; exit 2; }
mkdir -p "$TRIAL_ROOT"
TRIAL_ROOT="$(cd "$TRIAL_ROOT" && pwd -P)"
LAUNCH="$ROOT/research/ab/launch-arm.sh"
COLLECT="$ROOT/research/ab/collect.sh"
SEED_STORE="$TRIAL_ROOT/memory-seed"
SHARED_STORE="$TRIAL_ROOT/memory-shared"

launch() {
  local label="$1" store="$2" retrieval="$3"
  local -a args=(--arm B0 --task "$TASK" --trial-root "$TRIAL_ROOT" --memory-store "$store" --label "$label")
  [[ -n "$retrieval" ]] && args+=(--retrieval "$retrieval")
  [[ -n "$DEX_DIR_ARG" ]] && args+=(--dex-dir "$DEX_DIR_ARG")
  [[ -n "$MAX_MINUTES" ]] && args+=(--max-minutes "$MAX_MINUTES")
  [[ "$DRY_RUN" -eq 1 ]] && args+=(--dry-run)
  printf '== %s ==\n' "$label"
  bash "$LAUNCH" "${args[@]}"
}

collect() {
  local label="$1"
  [[ "$DRY_RUN" -eq 0 && -x "$COLLECT" ]] || return 0
  bash "$COLLECT" --arm-dir "$TRIAL_ROOT/$TASK/$label" > "$TRIAL_ROOT/$TASK/$label/metrics.json" 2> "$TRIAL_ROOT/$TASK/$label/collect.err" || true
}

mkdir -p "$SEED_STORE"
launch seed "$SEED_STORE" ""
collect seed
if [[ "$SEED_ONLY" -eq 1 ]]; then
  printf 'Seeded store: %s\n' "$SEED_STORE"
  exit 0
fi
# Both comparison runs read the same copy of what the seed run learned.
rm -rf "$SHARED_STORE"
cp -R "$SEED_STORE" "$SHARED_STORE"
launch mem-on "$SHARED_STORE" on
collect mem-on
launch mem-off "$SHARED_STORE" off
collect mem-off

[[ "$DRY_RUN" -eq 0 ]] || exit 0
python3 - "$TRIAL_ROOT/$TASK" <<'PY'
import json, os, sys
base = sys.argv[1]
rows = []
for label in ("seed", "mem-on", "mem-off"):
    path = os.path.join(base, label, "metrics.json")
    try:
        rows.append((label, json.load(open(path))))
    except (OSError, ValueError):
        rows.append((label, {}))
keys = ["rubric_score", "wall_seconds", "requests", "prompt_tokens_total", "output_tokens", "review_passes", "gate_reused", "phase_reached"]
lines = ["# Memory on/off pilot: " + os.path.basename(base), "",
         "| metric | " + " | ".join(l for l, _ in rows) + " |",
         "|---|" + "---|" * len(rows)]
for key in keys:
    lines.append(f"| {key} | " + " | ".join(str(m.get(key, "unknown")) for _, m in rows) + " |")
lines += ["", "`on` and `off` differ only in `DEX_MEMORY_RETRIEVAL`; both read the store the `seed` run left.",
          "One replicate per cell is a pilot, not evidence of a gain."]
open(os.path.join(base, "compare.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY
