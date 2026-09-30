#!/usr/bin/env bash
# Arm launchers for the Dex vs bare-Claude comparison. Sourced by run.sh and
# trial.sh after research/lib/capture.sh, whose context and prompt builders
# the dex arms reuse so they stay the arms improve.sh tunes.
#
# Every arm runs the same model at the same effort with the same isolation:
# no user settings, plugins, hooks, MCP servers or global CLAUDE.md, so
# whatever the operator has installed does not reach any arm. What differs
# is only what Dex adds:
#
#   bare      the scenario prompt, plus one line saying nobody will answer
#             questions (a `claude -p` run ends at the first question)
#   dex       Dex's guardrails and non-interactive guidance as the workspace
#             CLAUDE.md, Dex's plan/implement/verify/self-review prompt, and
#             Dex's guard hooks
#   dex-loop  the dex arm plus Dex's Stop-hook audit loop, activated the way
#             dxloop's implementation phase activates it: a generation-bound
#             prompt-loop that audits the work before it may stop
#
# `dex@<git-ref>` and `dex-loop@<git-ref>` take the guardrails and the
# non-interactive guidance from that revision instead of the working tree, so
# two versions of Dex's prompts can run side by side. run.sh snapshots each
# arm's prompts into the run directory when the run starts, and every trial
# reads that snapshot, so editing the prompts mid-run changes nothing.

# shellcheck disable=SC2034  # read by run.sh, which sources this file
COMPARE_ARMS="bare dex dex-loop dex@<ref> dex-loop@<ref>"

# The isolation every arm shares. --setting-sources without "user" drops the
# operator's settings.json (hooks, enabled plugins) and ~/.claude/CLAUDE.md;
# --strict-mcp-config with no --mcp-config drops every MCP server.
COMPARE_CLAUDE_ISOLATION=(--setting-sources "project,local" --strict-mcp-config)

COMPARE_NONINTERACTIVE_NOTE="You are running non-interactively: nobody will answer questions, so make reasonable assumptions and complete the task."

FOLLOWUP_MODEL="${FOLLOWUP_MODEL:-sonnet}"
FOLLOWUP_EFFORT="${FOLLOWUP_EFFORT:-high}"

compare_arm_valid() {
  [[ "$1" =~ ^(bare|dex|dex-loop)(@[A-Za-z0-9._/~^-]+)?$ && "$1" != bare@* ]]
}

# bare, dex or dex-loop
compare_arm_family() {
  printf '%s\n' "${1%%@*}"
}

# The git ref after @, or nothing.
compare_arm_ref() {
  if [[ "$1" == *@* ]]; then
    printf '%s\n' "${1#*@}"
  fi
}

# A name safe in a path and a trial id: dex@HEAD~1 -> dex-at-HEAD~1.
compare_arm_slug() {
  local slug="${1//@/-at-}"
  printf '%s\n' "${slug//\//_}"
}

# compare_arm_prompts <arm> <out_dir>
# Snapshot the prompts a dex arm injects: guardrails.md and dximplement.md,
# from the working tree or from the arm's git ref.
compare_arm_prompts() {
  local arm="$1" out="$2" ref
  ref=$(compare_arm_ref "$arm")
  mkdir -p "$out"
  if [[ -z "$ref" ]]; then
    cp "$DEX_DIR/prompts/guardrails.md" "$out/guardrails.md"
    cp "$DEX_DIR/prompts/workflows/dximplement.md" "$out/dximplement.md"
    printf 'working tree\n' > "$out/source"
    return 0
  fi
  git -C "$DEX_DIR" show "$ref:prompts/guardrails.md" > "$out/guardrails.md"
  # Older revisions kept the non-interactive guidance in the skill itself.
  git -C "$DEX_DIR" show "$ref:prompts/workflows/dximplement.md" > "$out/dximplement.md" 2>/dev/null \
    || git -C "$DEX_DIR" show "$ref:skills/dximplement/SKILL.md" > "$out/dximplement.md"
  git -C "$DEX_DIR" rev-parse "$ref^{commit}" > "$out/source"
}

# compare_dex_settings <out_file> [with_stop]
# Dex's hooks from the repo's settings.json template: the guards (PreToolUse,
# PostToolUse) and, with with_stop=1, the phase-loop Stop hook. The RTK
# rewrite (a separate tool) and the stop sound are left out of every arm.
compare_dex_settings() {
  python3 - "$DEX_DIR/settings.json" "$1" "${2:-0}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    template = json.load(fh)
events = ["PreToolUse", "PostToolUse"] + (["Stop"] if sys.argv[3] == "1" else [])
hooks = {}
for event in events:
    groups = []
    for group in template.get("hooks", {}).get(event, []):
        kept = [
            h for h in group.get("hooks", [])
            if "rtk" not in h.get("command", "") and "stop-sound" not in h.get("command", "")
        ]
        if kept:
            groups.append({**group, "hooks": kept})
    if groups:
        hooks[event] = groups
with open(sys.argv[2], "w") as fh:
    json.dump({"hooks": hooks}, fh, indent=2)
PY
}

# _compare_claude <ws> <stream> <stderr> <timeout> <model> <effort> <prompt> [extra claude args...]
_compare_claude() {
  local ws="$1" stream="$2" stderr_file="$3" timeout_s="$4" model="$5" effort="$6" prompt="$7"
  shift 7
  # stdin from /dev/null: `claude -p` otherwise waits three seconds for piped input.
  (cd "$ws" && \
    timeout "${timeout_s}s" \
    claude -p \
      --model "$model" \
      --effort "$effort" \
      "$CLAUDE_BYPASS_FLAG" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" \
      "${COMPARE_CLAUDE_ISOLATION[@]}" \
      --output-format stream-json \
      --verbose \
      "$@" \
      "$prompt" \
    <"/dev/null" >"$stream" 2>"$stderr_file")
}

# compare_arm_run <arm> <ws> <trial_dir> <prompt> <timeout> <seeded> <scratch> <prompts_dir>
# Writes stream.jsonl and stderr.log into trial_dir. Returns claude's exit
# status (124 on timeout).
compare_arm_run() {
  local arm="$1" ws="$2" trial_dir="$3" prompt="$4" timeout_s="$5" seeded="$6" scratch="$7" prompts="$8"
  local stream="$trial_dir/stream.jsonl" stderr_file="$trial_dir/stderr.log"
  local family
  family=$(compare_arm_family "$arm")

  if [[ "$family" == bare ]]; then
    _compare_claude "$ws" "$stream" "$stderr_file" "$timeout_s" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" \
      "${prompt}

${COMPARE_NONINTERACTIVE_NOTE}"
    return
  fi

  _inject_workspace_context "$ws" "claude" "$prompts/guardrails.md" "$prompts/dximplement.md" 2>>"$trial_dir/trial.log"
  local full_prompt settings session
  full_prompt=$(_build_dxloop_prompt "$prompt" "$(_context_file_for_runner claude)" "$seeded")
  settings="$scratch/dex-settings.json"
  session="research-compare-$(basename "$trial_dir")"
  # Every Dex state root points into this trial's scratch directory, so an
  # arm cannot read or write the operator's real lifecycle state.
  mkdir -p "$scratch/state" "$scratch/loops" "$scratch/runs" "$scratch/artifacts" "$scratch/maintenance"
  local -a env_vars=(
    "DEX_DIR=$DEX_DIR"
    "DEX_SESSION_ID=$session"
    "DX_STATE_DIR=$scratch/state"
    "DX_LOOP_DIR=$scratch/loops"
    "DX_RUN_ROOT=$scratch/runs"
    "DX_ARTIFACT_DIR=$scratch/artifacts"
    "DX_MAINTENANCE_DIR=$scratch/maintenance"
  )

  if [[ "$family" == dex ]]; then
    compare_dex_settings "$settings" 0
    printf '%s\n' "$full_prompt" > "$trial_dir/prompt.txt"
    (
      export "${env_vars[@]}"
      _compare_claude "$ws" "$stream" "$stderr_file" "$timeout_s" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" \
        "$full_prompt" --settings "$settings"
    )
    return
  fi

  # dex-loop: activate the prompt-loop audit the way dxloop's implementation
  # phase does, then launch with the Stop hook and the receipt instruction.
  compare_dex_settings "$settings" 1
  local generation receipt
  if ! generation=$(export "${env_vars[@]}"; bash "$DEX_DIR/bin/activate-loop.sh" "$session" standalone dxloop-prompt prompt-loop 2>>"$trial_dir/trial.log"); then
    log_error "Could not activate the audit loop for $session"
    return 2
  fi
  printf '%s' "$prompt" > "$scratch/loops/$session.prompt"
  receipt="bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"$session\" \"$generation\""
  full_prompt="${full_prompt}

The stop hook audit will guide you through quality verification and final review when you are done."
  printf '%s\n' "$full_prompt" > "$trial_dir/prompt.txt"
  local loop_exit=0
  (
    export "${env_vars[@]}" DEX_LOOP_ACTIVE=1 DEX_LOOP_PROMISE=PROMPT_COMPLETE DEX_LOOP_PHASE=prompt-loop
    _compare_claude "$ws" "$stream" "$stderr_file" "$timeout_s" "$CLAUDE_MODEL" "$CLAUDE_EFFORT" "$full_prompt" \
      --settings "$settings" --include-hook-events \
      --append-system-prompt "You are in a dxloop session. Your original task prompt is saved at $scratch/loops/$session.prompt. Re-read it with the Read tool before any audit step, or when you lose track of what you are working on. When the Stop hook prints the exact command after the audit threshold, run this literal command only if every implementation and verification requirement is met, then stop again: $receipt"
  ) || loop_exit=$?
  # Whether the audit loop finished: completion removes its .active marker.
  if [[ -e "$scratch/loops/$session.active" ]]; then
    printf '{"activated": true, "completed": false}\n' > "$trial_dir/loop.json"
  else
    printf '{"activated": true, "completed": true}\n' > "$trial_dir/loop.json"
  fi
  return "$loop_exit"
}

# compare_followup_run <ws> <out_dir> <prompt> <timeout>
# The follow-up agent is the same for every arm — bare, isolated, and on its
# own model — so a difference in what it costs to change the code comes from
# the code, not from the agent changing it.
compare_followup_run() {
  local ws="$1" out_dir="$2" prompt="$3" timeout_s="$4"
  mkdir -p "$out_dir"
  _compare_claude "$ws" "$out_dir/stream.jsonl" "$out_dir/stderr.log" "$timeout_s" \
    "$FOLLOWUP_MODEL" "$FOLLOWUP_EFFORT" "${prompt}

${COMPARE_NONINTERACTIVE_NOTE}"
}
