#!/usr/bin/env bash
# Run one arm of the A/B comparison from an isolated trial root.
#
#   launch-arm.sh --arm A|B0 --task <scenario> --trial-root DIR [--dex-dir DIR]
#                 [--max-minutes N] [--dry-run]
#
# The arm's Dex checkout is --dex-dir (default: the arm's worktree named in
# research/ab/manifest.json). Everything the run touches lives under
# <trial-root>/<task>/<arm>/: a fresh fixture repository with a bare origin,
# Dex state and journals, the memory store, the feedback outbox, artifacts,
# the auto-memory directory, logs. The arm's settings are the checkout's
# settings.json plus autoMemoryDirectory, handed to the provider by a `claude`
# shim on PATH that adds --setting-sources project,local --settings <file>, so
# the operator's user settings and global hooks never load. The lifecycle is
# `dx run --spec` (headless, in place, plan approval not required), stdin from
# /dev/null, under a wall-clock cap. A watcher stops the lifecycle with
# `dx control stop` once the phase passes the endpoint (Phase 4 verified).
# --dry-run prepares all of that and prints the plan without launching.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$HERE/manifest.json"

ARM="" TASK="" TRIAL_ROOT="" ARM_DEX_DIR="" MAX_MINUTES="" DRY_RUN=0
MEMORY_STORE="" RETRIEVAL="" LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arm) ARM="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --trial-root) TRIAL_ROOT="${2:-}"; shift 2 ;;
    --dex-dir) ARM_DEX_DIR="${2:-}"; shift 2 ;;
    --max-minutes) MAX_MINUTES="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    # The memory on/off comparison: the same arm, run against a given store
    # with retrieval on or off, under its own label so the two do not collide.
    --memory-store) MEMORY_STORE="${2:-}"; shift 2 ;;
    --retrieval) RETRIEVAL="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    *) echo "Usage: launch-arm.sh --arm A|B0 --task <scenario> --trial-root DIR [--dex-dir DIR] [--max-minutes N] [--memory-store DIR] [--retrieval on|off] [--label NAME] [--dry-run]" >&2; exit 2 ;;
  esac
done
[[ "$ARM" == "A" || "$ARM" == "B0" ]] || { echo "launch-arm: --arm must be A or B0" >&2; exit 2; }
[[ -n "$TASK" && -n "$TRIAL_ROOT" ]] || { echo "launch-arm: --task and --trial-root are required" >&2; exit 2; }
[[ "$TASK" =~ ^[a-z0-9-]+$ ]] || { echo "launch-arm: bad task name" >&2; exit 2; }
SCENARIO_DIR="$ROOT/research/scenarios/$TASK"
[[ -f "$SCENARIO_DIR/prompt.md" && -f "$SCENARIO_DIR/rubric.sh" ]] || { echo "launch-arm: no scenario $TASK" >&2; exit 2; }

MODE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arms"][sys.argv[2]]["orchestration_mode"])' "$MANIFEST" "$ARM")
if [[ -z "$ARM_DEX_DIR" ]]; then
  ARM_DEX_DIR="$ROOT/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arms"][sys.argv[2]]["dex_dir"])' "$MANIFEST" "$ARM")"
fi
[[ -f "$ARM_DEX_DIR/dx.sh" && -f "$ARM_DEX_DIR/settings.json" ]] || { echo "launch-arm: $ARM_DEX_DIR is not a Dex checkout" >&2; exit 2; }
if [[ -z "$MAX_MINUTES" ]]; then
  MAX_MINUTES=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(next(t["max_minutes_per_arm"] for t in m["tasks"] if t["scenario"]==sys.argv[2]))' "$MANIFEST" "$TASK" 2>/dev/null || echo 60)
fi
[[ "$MAX_MINUTES" =~ ^[1-9][0-9]*$ ]] || { echo "launch-arm: --max-minutes must be a positive integer" >&2; exit 2; }
[[ -z "$RETRIEVAL" || "$RETRIEVAL" == on || "$RETRIEVAL" == off ]] || { echo "launch-arm: --retrieval must be on or off" >&2; exit 2; }
[[ -z "$LABEL" || "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$ ]] || { echo "launch-arm: --label must be a short name" >&2; exit 2; }

ARM_DIR="$TRIAL_ROOT/$TASK/${LABEL:-$ARM}"
REPO="$ARM_DIR/repo"
for d in state loops runs memory feedback artifacts auto-memory shim logs; do mkdir -p "$ARM_DIR/$d"; done
chmod 700 "$ARM_DIR"

# ── fixture repository: fresh, committed, with a bare origin ───────────────
if [[ ! -d "$REPO/.git" ]]; then
  mkdir -p "$REPO"
  if [[ -d "$SCENARIO_DIR/seed" ]]; then cp -R "$SCENARIO_DIR/seed/." "$REPO/"; fi
  [[ -f "$REPO/README.md" ]] || printf '# %s\n\nFixture repository for the Dex A/B comparison.\n' "$TASK" > "$REPO/README.md"
  # A minimal .dex/ so `dx run` does not auto-initialise the repository: init's
  # tooling bootstrap installs hooks into the operator's ~/.claude/settings.json
  # for whatever DEX_DIR is current, which for an arm is the arm's worktree.
  mkdir -p "$REPO/.dex/memory/domains" "$REPO/.dex/rules" "$REPO/.dex/guards"
  printf 'worktrees/\n' > "$REPO/.dex/.gitignore"
  {
    printf '# %s\n\nFixture repository for the Dex A/B comparison. No tracker, no integrations.\n\n' "$TASK"
    printf '## Integrations\n\n| Integration | Tool | Status |\n|-------------|------|--------|\n| Ticket tracker | none | disabled |\n'
  } > "$REPO/.dex/dex.md"
  printf '@dex.md\n' > "$REPO/.dex/AGENTS.md"
  printf '@AGENTS.md\n' > "$REPO/.dex/CLAUDE.md"
  printf '# Memory\n\nNo entries yet.\n' > "$REPO/.dex/memory/index.md"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email "dex-ab@example.com"
  git -C "$REPO" config user.name "Dex A/B"
  git -C "$REPO" add .
  git -C "$REPO" -c commit.gpgsign=false commit -q -m "chore: fixture baseline"
  git init -q --bare -b main "$ARM_DIR/origin.git"
  git -C "$REPO" remote add origin "$ARM_DIR/origin.git"
  git -C "$REPO" push -q origin main
fi

# ── arm settings and the claude shim ───────────────────────────────────────
ARM_SETTINGS="$ARM_DIR/arm-settings.json"
python3 - "$ARM_DEX_DIR/settings.json" "$ARM_SETTINGS" "$ARM_DIR/auto-memory" <<'PY'
import json, sys
settings = json.load(open(sys.argv[1]))
settings["autoMemoryDirectory"] = sys.argv[3]
json.dump(settings, open(sys.argv[2], "w"), indent=2)
PY
REAL_CLAUDE=$(command -v claude)
SHIM="$ARM_DIR/shim/claude"
cat > "$SHIM" <<SHIM
#!/usr/bin/env bash
# A/B arm shim: the arm's settings, with the operator's user settings and
# global hooks excluded. dx passes its own --settings (status line, messaging);
# a second --settings would override the first, so the two are merged into one
# file and that file is passed once. Arguments are filtered in bash so a
# multi-line prompt stays one argument.
printf '%s\\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ) \$#-args" >> "$ARM_DIR/logs/claude-argv.log"
MERGED_PATH=\$(python3 "$ARM_DIR/shim/merge-settings.py" "$ARM_SETTINGS" "$ARM_DIR/logs" "\$@")
ARGS=()
SKIP=0
for ARG in "\$@"; do
  if [[ "\$SKIP" -eq 1 ]]; then SKIP=0; continue; fi
  if [[ "\$ARG" == "--settings" ]]; then SKIP=1; continue; fi
  if [[ "\$ARG" == --settings=* ]]; then continue; fi
  ARGS+=("\$ARG")
done
exec "$REAL_CLAUDE" --setting-sources project,local --settings "\$MERGED_PATH" "\${ARGS[@]}"
SHIM
cat > "$ARM_DIR/shim/merge-settings.py" <<'PY'
import json, os, sys, tempfile
arm_settings, log_dir, args = sys.argv[1], sys.argv[2], sys.argv[3:]
merged = json.load(open(arm_settings))
i = 0
while i < len(args):
    value = None
    if args[i] == "--settings" and i + 1 < len(args):
        value = args[i + 1]; i += 2
    elif args[i].startswith("--settings="):
        value = args[i].split("=", 1)[1]; i += 1
    else:
        i += 1; continue
    try:
        other = json.load(open(value)) if os.path.isfile(value) else json.loads(value)
    except Exception:
        other = {}
    for key, val in other.items():
        if key == "hooks" and isinstance(val, dict):
            for event, groups in val.items():
                merged.setdefault("hooks", {}).setdefault(event, []).extend(groups)
        else:
            merged[key] = val
fd, path = tempfile.mkstemp(prefix="arm-settings-merged.", suffix=".json", dir=log_dir)
with os.fdopen(fd, "w") as handle:
    json.dump(merged, handle)
print(path)
PY
chmod +x "$SHIM"

# ── run spec ───────────────────────────────────────────────────────────────
RUN_ID="run_ab_${TASK//-/_}_${LABEL:-$ARM}_$(date -u +%Y%m%dT%H%M%SZ)"
SPEC="$ARM_DIR/run-spec.json"
python3 - "$SPEC" "$RUN_ID" "$REPO" "$SCENARIO_DIR/prompt.md" "$TASK" <<'PY'
import json, sys
spec = {
  "run_id": sys.argv[2],
  "company": {"slug": "dex-ab", "name": "Dex A/B"},
  "project": {"slug": sys.argv[5], "name": sys.argv[5]},
  "repository": {"provider": "local", "full_name": f"dex-ab/{sys.argv[5]}", "default_branch": "main", "working_directory": sys.argv[3]},
  "source": {"type": "task", "id": sys.argv[5], "title": f"A/B task: {sys.argv[5]}", "body": open(sys.argv[4]).read()},
  "harness": {"name": "claude-code", "model": None},
  "workflow": {"name": "ticket_to_pr", "version": "v1", "requires_plan_approval": False, "requires_ui_evidence": "never", "auto_merge": False}
}
json.dump(spec, open(sys.argv[1], "w"), indent=2)
PY

MANIFEST_SHA=$(shasum -a 256 "$MANIFEST" | cut -d' ' -f1)
# The arm's environment as KEY=VALUE words, ready for `env`. macOS bash 3.2
# has no associative arrays, so a later setting replaces an earlier one here.
ENV_ARGS=()
arm_env() { # <key> <value>
  local entry kept=()
  for entry in ${ENV_ARGS[@]+"${ENV_ARGS[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] || kept+=("$entry")
  done
  ENV_ARGS=(${kept[@]+"${kept[@]}"} "$1=$2")
}
arm_env DEX_DIR "$ARM_DEX_DIR"
arm_env DX_STATE_DIR "$ARM_DIR/state"
arm_env DX_LOOP_DIR "$ARM_DIR/loops"
arm_env DX_RUN_ROOT "$ARM_DIR/runs"
arm_env DX_MEMORY_STORE_DIR "$ARM_DIR/memory"
arm_env DX_FEEDBACK_DIR "$ARM_DIR/feedback"
arm_env DX_ARTIFACT_DIR "$ARM_DIR/artifacts"
arm_env DEX_MAX_ACTIVE_HEAVY 1
arm_env DEX_MISSION_MAX_HELPERS 2
arm_env DEX_HEADLESS_DEFAULT_BRANCH main
arm_env DEX_FACTORY_SYNC 0
arm_env DX_AB_ARM "$ARM"
arm_env DX_AB_TASK "$TASK"
# The memory curator is a learning-loop cost, reported separately; an arm
# must not spend a model session on it at completion.
arm_env DEX_MEMORY_CURATE 0
# Mission is the default; a legacy arm has to say so.
arm_env DEX_ORCHESTRATION_MODE "$MODE"
# The memory on/off comparison shares one store between runs and switches
# retrieval; a plain arm keeps its own empty store.
[[ -z "$MEMORY_STORE" ]] || arm_env DX_MEMORY_STORE_DIR "$MEMORY_STORE"
[[ "$RETRIEVAL" != off ]] || arm_env DEX_MEMORY_RETRIEVAL 0
[[ "$RETRIEVAL" != on ]] || arm_env DEX_MEMORY_RETRIEVAL 1
ENV_JSON=$(python3 -c 'import json, sys
print(json.dumps(dict(arg.split("=", 1) for arg in sys.argv[1:]), sort_keys=True))' "${ENV_ARGS[@]}")
PLAN=$(python3 -c 'import json,sys; print(json.dumps({"arm": sys.argv[1], "task": sys.argv[2], "mode": sys.argv[3], "dex_dir": sys.argv[4], "arm_dir": sys.argv[5], "repo": sys.argv[6], "spec": sys.argv[7], "shim": sys.argv[8], "arm_settings": sys.argv[9], "max_minutes": int(sys.argv[10]), "manifest_sha256": sys.argv[11], "dry_run": sys.argv[12] == "1", "env": json.loads(sys.argv[13]), "run_id": sys.argv[14]}, sort_keys=True))' \
  "$ARM" "$TASK" "$MODE" "$ARM_DEX_DIR" "$ARM_DIR" "$REPO" "$SPEC" "$SHIM" "$ARM_SETTINGS" "$MAX_MINUTES" "$MANIFEST_SHA" "$DRY_RUN" "$ENV_JSON" "$RUN_ID")
printf '%s\n' "$PLAN" > "$ARM_DIR/plan.json"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' "$PLAN"
  exit 0
fi

# ── launch, with the endpoint watcher ──────────────────────────────────────
START_EPOCH=$(date +%s)
{
  printf '%s\n' "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "start_epoch=$START_EPOCH" "load1=$(uptime | sed 's/.*load averages*: //' | cut -d' ' -f1 | tr -d ',')" "arm=$ARM" "task=$TASK" "mode=$MODE" "dex_dir=$ARM_DEX_DIR" "manifest_sha256=$MANIFEST_SHA"
} > "$ARM_DIR/logs/run-meta.txt"

(
  # The watcher: once the lifecycle's phase passes the endpoint, ask Dex to
  # stop through its own control, and record that the endpoint was reached.
  while true; do
    sleep 20
    for phase_file in "$ARM_DIR"/state/*.phase; do
      [[ -f "$phase_file" ]] || continue
      phase=$(tr -dc '0-9' < "$phase_file" | head -c 1)
      sid=$(basename "$phase_file" .phase)
      if [[ "$phase" =~ ^[0-9]$ && "$phase" -ge 5 ]]; then
        printf '%s endpoint reached: phase %s for %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$sid" >> "$ARM_DIR/logs/watcher.log"
        # dx control checks that the session belongs to the repository it is
        # run from, so run it from the fixture.
        (cd "$REPO" && env "${ENV_ARGS[@]}" PATH="$ARM_DIR/shim:$PATH" bash "$ARM_DEX_DIR/bin/control.sh" --session "$sid" stop --source agent \
          --reason "A/B endpoint reached: Phase 4 verified; Phases 5-6 are outside the measurement") >> "$ARM_DIR/logs/watcher.log" 2>&1 || true
        exit 0
      fi
    done
  done
) &
WATCHER_PID=$!
echo "$WATCHER_PID" > "$ARM_DIR/logs/watcher.pid"

set +e
env "${ENV_ARGS[@]}" PATH="$ARM_DIR/shim:$PATH" \
  timeout "$((MAX_MINUTES * 60))" zsh -c 'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; cd "$1" && dx run --spec "$2"' zsh "$REPO" "$SPEC" \
  < /dev/null > "$ARM_DIR/logs/run.out" 2> "$ARM_DIR/logs/run.err"
RUN_EXIT=$?
set -e
kill "$WATCHER_PID" 2>/dev/null || true
END_EPOCH=$(date +%s)
{
  printf '%s\n' "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "end_epoch=$END_EPOCH" "wall_seconds=$((END_EPOCH - START_EPOCH))" "run_exit=$RUN_EXIT" "timed_out=$([[ $RUN_EXIT -eq 124 ]] && printf 1 || printf 0)"
} >> "$ARM_DIR/logs/run-meta.txt"
bash "$HERE/collect.sh" "$ARM_DIR" > "$ARM_DIR/metrics.json" || true
printf '%s\n' "$ARM_DIR/metrics.json"
