#!/usr/bin/env zsh
set -euo pipefail

if [[ $# -ne 8 ]]; then
  print -u2 -- "usage: launch.zsh <runtime> <workspace> <result-dir> <claude|codex> <model> <effort> <tier> <observer-token>"
  exit 2
fi

typeset controller_runtime="$1"
typeset controller_workspace="$2"
typeset controller_result="$3"
typeset controller_runner="$4"
typeset controller_model="$5"
typeset controller_effort="$6"
typeset controller_tier="$7"
typeset controller_observer_token="$8"
typeset controller_test_stub="${REVIEW_EVAL_TEST_STUB:-0}"
typeset controller_test_stub_mode="${REVIEW_EVAL_TEST_STUB_MODE:-normal}"
typeset controller_name=""
typeset controller_capture=""
typeset controller_capture_ready=""
typeset controller_capture_handed_off=0

[[ -f "$controller_runtime/dx.sh" ]] || {
  print -u2 -- "review-loop evaluation: sanitized Dex runtime is missing dx.sh"
  exit 2
}
[[ -f "$controller_runtime/research/review-loop/agent-observer.sh" ]] || {
  print -u2 -- "review-loop evaluation: sanitized wave observer is missing"
  exit 2
}
[[ -d "$controller_workspace/.git" ]] || {
  print -u2 -- "review-loop evaluation: trial workspace is not a Git checkout"
  exit 2
}
mkdir -p "$controller_result"
[[ -n "$controller_observer_token" && "$controller_observer_token" != *[!a-f0-9]* && \
   ${#controller_observer_token} -eq 32 ]] || {
    print -u2 -- "review-loop evaluation: observer token is invalid"
    exit 2
  }
case "$controller_runner" in
  claude|codex) ;;
  *)
    print -u2 -- "review-loop evaluation: runner must be claude or codex"
    exit 2
    ;;
esac

umask 077
controller_capture=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-observer-${controller_observer_token}.XXXXXX") || {
  print -u2 -- "review-loop evaluation: could not create the private observer directory"
  exit 2
}
__review_eval_cleanup_capture() {
  [[ -z "$controller_capture" || ! -e "$controller_capture" ]] || \
    command rm -rf -- "$controller_capture"
  if (( controller_capture_handed_off == 0 )); then
    [[ -z "$controller_capture_ready" || ! -e "$controller_capture_ready" ]] || \
      command rm -rf -- "$controller_capture_ready"
  fi
}
trap __review_eval_cleanup_capture EXIT
case "$controller_tier" in
  ""|small|normal|complex) ;;
  *)
    print -u2 -- "review-loop evaluation: tier must be small, normal, complex, or empty"
    exit 2
    ;;
esac

# The controller switch is captured above. No evaluation-only variable crosses
# the provider boundary.
for controller_name in ${(k)parameters}; do
  [[ "$controller_name" == REVIEW_EVAL_* ]] && unset "$controller_name"
done
unset \
  DEX_SESSION_ID DEX_RUN_ID DEX_HEADLESS_RUN DEX_HEADLESS_RUN_SPEC_FILE \
  DEX_HEADLESS_REQUIRES_PLAN_APPROVAL DEX_LOOP_ACTIVE DEX_LOOP_PHASE \
  DEX_LOOP_PROMISE DEX_LOOP_PROMPT DEX_PHASE_HANDOFF \
  DEX_REVIEW_ASSESSMENT_ACTIVE DEX_REVIEW_PASS_ACTIVE DEX_REVIEW_TIER \
  DEX_REVIEW_PROFILE DEX_REVIEW_CLEAN_PASSES DX_REVIEW_PROFILE \
  DX_AGENT DX_AGENT_OVERRIDE DX_MODEL DX_MODEL_OVERRIDE DX_PROVIDER_PROFILE \
  DX_CLAUDE_MODEL DX_CLAUDE_EFFORT DX_PLAN_MODEL DX_PLAN_EFFORT DX_CODEX_MODEL
unset OLDPWD CDPATH

export DEX_DIR="$controller_runtime"
export DX_STATE_DIR="$controller_result/state"
export DX_LOOP_DIR="$controller_result/loops"
export DX_ARTIFACT_DIR="$controller_result/artifacts"
export DX_TOOL_DIR="$controller_result/tools"
export DX_RUN_ROOT="$controller_result/dex-runs"
export DX_RTK_ENABLED=0
export DEX_FACTORY_SYNC=0
export DEX_REVIEW_DISABLE_MCP=1
export DX_AGENT_OVERRIDE="$controller_runner"
[[ -n "$controller_model" ]] && export DX_MODEL_OVERRIDE="$controller_model"
if [[ "$controller_runner" == "claude" && -n "$controller_effort" ]]; then
  export DX_CLAUDE_EFFORT="$controller_effort"
fi
[[ -n "$controller_tier" ]] && export DEX_REVIEW_TIER="$controller_tier"

mkdir -p "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_ARTIFACT_DIR" "$DX_TOOL_DIR" "$DX_RUN_ROOT"

set +e
source "$controller_runtime/dx.sh"
typeset controller_source_status=$?
source "$controller_runtime/research/review-loop/agent-observer.sh"
typeset controller_observer_status=$?
(( controller_source_status == 0 && controller_observer_status == 0 )) || {
  print -u2 -- "review-loop evaluation: could not load the pinned Dex runtime"
  exit 2
}
set -e
for controller_name in \
    __dx_review_emit_event dx_review_parse_assessment_file \
    review_eval_agent_capture_wave review_eval_agent_record_assessment; do
  (( $+functions[$controller_name] )) || {
    print -u2 -- "review-loop evaluation: pinned runtime is missing ${controller_name}"
    exit 2
  }
done

functions[__review_eval_product_emit_event]=$functions[__dx_review_emit_event]
functions[__review_eval_product_parse_assessment]=$functions[dx_review_parse_assessment_file]
__dx_review_emit_event() {
  local event_type="${2:-}" product_status=0
  __review_eval_product_emit_event "$@" || product_status=$?
  if [[ "$event_type" == "review.pass.finished" ]]; then
    shift 5
    if ! review_eval_agent_capture_wave "$controller_workspace" "$controller_capture" "$@"; then
      : >| "$controller_capture/capture-error"
    fi
  fi
  return "$product_status"
}
dx_review_parse_assessment_file() {
  local assessment_record
  assessment_record=$(__review_eval_product_parse_assessment "$@") || return 1
  review_eval_agent_record_assessment "$controller_capture" "$assessment_record" || return 1
  print -r -- "$assessment_record"
}

if [[ "$controller_test_stub" == "1" ]]; then
  __review_eval_stub_generation() {
    local record_kind="$1"
    shift
    python3 - "$record_kind" "$@" <<'PY'
import re
import sys

kind = sys.argv[1]
values = sys.argv[2:]
if kind == "assessment":
    pattern = re.compile(r'"completion_generation":"([0-9a-f]{32})"')
elif kind == "pass":
    pattern = re.compile(
        r'bash "\$DEX_DIR/bin/complete-receipt\.sh" '
        r'"([A-Za-z0-9][A-Za-z0-9._-]{0,179})" "([0-9a-f]{32})"'
    )
else:
    raise SystemExit(2)

matches = []
for value in values:
    matches.extend(pattern.findall(value))
if len(matches) != 1:
    raise SystemExit(1)
match = matches[0]
if isinstance(match, tuple):
    print("\t".join(match))
else:
    print(match)
PY
  }
  claude() { return 0 }
  __dx_refresh_provider() {
    DX_PROVIDER_ENGINE=claude
    DX_CLAUDE_FLAGS=(--dangerously-skip-permissions --permission-mode bypassPermissions)
  }
  __dx_claude() {
    local stub_context stub_result stub_evidence stub_findings stub_hash
    local stub_completion_record stub_completion_session stub_generation
    local stub_branch stub_child_pid stub_remote stub_generic_branch=false
    local stub_generic_layout=false stub_prior_capture=false stub_assessment_active=false
    local stub_policy_binding_valid=false stub_pass_binding_valid=false stub_evidence_version=0
    stub_branch=$(git branch --show-current 2>/dev/null || true)
    stub_remote=$(git remote get-url origin 2>/dev/null || true)
    [[ "$stub_branch" == "review-eval/candidate" ]] && stub_generic_branch=true
    if [[ "$PWD" == */fixture/workspace && "$stub_remote" == */fixture/origin.git && \
          "$controller_runtime" == */runtime && "$controller_result" == */result ]]; then
      stub_generic_layout=true
    fi
    if [[ -e "$controller_result/waves.jsonl" || -e "$controller_result/assessment.jsonl" || \
          -e "$controller_result/snapshots" ]]; then
      stub_prior_capture=true
    fi
    if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
      stub_assessment_active=true
    else
      stub_evidence_version=3
      if dx_review_policy_binding_valid "${DEX_REVIEW_POLICY_BINDING:-}"; then
        stub_policy_binding_valid=true
      fi
      if [[ -n "${DEX_REVIEW_PASS_ID:-}" && -n "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" ]] &&
         [[ "$(dx_review_pass_binding "$DEX_REVIEW_PASS_ID" "$DEX_REVIEW_SCOPE_FINGERPRINT" \
              "${DEX_REVIEW_CRITERIA_BINDING:-}" "${DEX_REVIEW_POLICY_BINDING:-}" 2>/dev/null || true)" == \
            "${DEX_REVIEW_PASS_BINDING:-}" ]]; then
        stub_pass_binding_valid=true
      fi
    fi
    print -r -- "{\"assessment_active\":${stub_assessment_active},\"evidence_version\":${stub_evidence_version},\"generic_branch\":${stub_generic_branch},\"generic_layout\":${stub_generic_layout},\"pass_binding_valid\":${stub_pass_binding_valid},\"policy_binding_valid\":${stub_policy_binding_valid},\"prior_capture_visible\":${stub_prior_capture}}" \
      >> "$controller_capture/provider-observations.jsonl"
    if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-0}" == "1" ]]; then
      stub_generation=$(__review_eval_stub_generation assessment "$@") || return 2
      case "$controller_test_stub_mode" in
        fail-assessment) return 2 ;;
        timeout-assessment) return 124 ;;
        tier-normal)
          print -r -- "{\"tier\":\"normal\",\"reason_codes\":\"bounded-production-change\",\"completion_generation\":\"${stub_generation}\"}"
          ;;
        tier-complex)
          print -r -- "{\"tier\":\"complex\",\"reason_codes\":\"cross-module,public-contract\",\"completion_generation\":\"${stub_generation}\"}"
          ;;
        mutate-runtime)
          chmod u+w "$controller_runtime/prompts/review-risk-assessment.md"
          print -r -- '# evaluation mutation' >> "$controller_runtime/prompts/review-risk-assessment.md"
          print -r -- "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\",\"completion_generation\":\"${stub_generation}\"}"
          ;;
        *)
          print -r -- "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\",\"completion_generation\":\"${stub_generation}\"}"
          ;;
      esac
      return 0
    fi
    if [[ "$controller_test_stub_mode" == "hang" ]]; then
      (trap '' INT TERM HUP; sleep 30) &
      stub_child_pid=$!
      print -r -- "$stub_child_pid" >| "$controller_result/stub-grandchild.pid"
      wait "$stub_child_pid"
      return 0
    fi
    stub_context=$(dx_review_context_file "$DEX_SESSION_ID")
    stub_result=$(dx_review_result_file "$DEX_SESSION_ID")
    stub_evidence=$(dx_review_evidence_file "$DEX_SESSION_ID")
    stub_findings=$(dx_findings_file "$DEX_SESSION_ID")
    stub_completion_record=$(__review_eval_stub_generation pass "$@") || return 2
    IFS=$'\t' read -r stub_completion_session stub_generation <<< \
      "$stub_completion_record"
    [[ "$stub_completion_session" == "$DEX_SESSION_ID" ]] || return 2
    stub_hash=$(dx_review_empty_findings_hash)
    __dx_write_state "$stub_context" $'# Stub review context\n\n## Scope\nThe current candidate diff was inspected in full.\n\n## Acceptance Criteria\nCriteria binding: standalone\nNo external criteria were supplied.\n\n## Deterministic Checks\nThe fixture check passed.\n\n## Review Coverage\nCorrectness, security, contracts, tests, and architecture were covered.\n\n## Verification\nThe candidate remained unchanged and verification passed.'
    __dx_write_state "$stub_result" "CLEAN"
    __dx_write_state "$stub_findings" "$stub_hash"
    __dx_write_state "$stub_evidence" "{\"version\":3,\"scope_fingerprint\":\"${DEX_REVIEW_SCOPE_FINGERPRINT}\",\"criteria_binding\":\"standalone\",\"policy_binding\":\"${DEX_REVIEW_POLICY_BINDING}\",\"pass_binding\":\"${DEX_REVIEW_PASS_BINDING}\",\"criteria_evidence\":{\"objectives\":[],\"acceptance_criteria\":[],\"verification_requirements\":[]},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\",\"frontend\",\"devops\",\"performance\",\"observability\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}"
    bash "$DEX_DIR/bin/complete-receipt.sh" "$stub_completion_session" \
      "$stub_generation"
    print -r -- "${DEX_LOOP_PROMISE:-PHASE_3_COMPLETE}"
  }
fi

builtin cd "$controller_workspace"
typeset controller_status=0
dxreviewloop || controller_status=$?
[[ ! -e "$controller_capture/capture-error" ]] || controller_status=1
controller_capture_ready="${controller_capture}.ready"
if ! mv "$controller_capture" "$controller_capture_ready"; then
  print -u2 -- "review-loop evaluation: could not seal observer artifacts"
  controller_status=1
else
  controller_capture=""
  typeset controller_pointer_tmp=""
  controller_pointer_tmp=$(mktemp "$controller_result/.observer-pointer.XXXXXX") || controller_status=1
  if [[ -n "$controller_pointer_tmp" ]]; then
    print -r -- "$controller_capture_ready" >| "$controller_pointer_tmp"
    if mv -f "$controller_pointer_tmp" "$controller_result/.observer-pointer"; then
      controller_capture_handed_off=1
    else
      controller_status=1
    fi
  fi
fi
exit "$controller_status"
