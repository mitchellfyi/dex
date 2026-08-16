#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-loop-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT


assert_success() {
  local label="$1"
  if [[ "$CASE_RC" -ne 0 ]]; then
    printf '%s: expected success, got exit code %s\n' "$label" "$CASE_RC" >&2
    show_case_output
    exit 1
  fi
}

assert_failure() {
  local label="$1"
  if [[ "$CASE_RC" -eq 0 ]]; then
    printf '%s: expected a non-zero exit code\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

show_case_output() {
  if [[ -n "${CASE_OUTPUT:-}" && -f "$CASE_OUTPUT" ]]; then
    printf 'output for %s:\n' "${CASE_NAME:-unknown}" >&2
    sed -n '1,240p' "$CASE_OUTPUT" >&2
  fi
}

call_count() {
  local kind="$1"
  [[ -f "$CASE_CALLS" ]] || {
    printf '%s\n' "0"
    return
  }
  awk -F '\t' -v kind="$kind" '$1 == kind { count++ } END { print count + 0 }' "$CASE_CALLS"
}

assert_no_assessor() {
  assert_eq "0" "$(call_count assessor)" "$1 assessor calls"
}

assert_no_receipt() {
  local label="$1" receipt="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-receipt"
  if [[ -e "$receipt" ]]; then
    printf '%s: unexpected review receipt at %s\n' "$label" "$receipt" >&2
    show_case_output
    exit 1
  fi
}

assert_receipt() {
  local expected_tier="$1" expected_required="$2" label="$3"
  local receipt="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-receipt"
  local version tier profile required clean_count fingerprint ledger_hash criteria_binding policy_binding extra
  local expected_binding="standalone" expected_policy_binding expected_profile

  if [[ ! -f "$receipt" ]]; then
    printf '%s: missing review receipt at %s\n' "$label" "$receipt" >&2
    show_case_output
    exit 1
  fi

  IFS=$'\t' read -r version tier profile required clean_count fingerprint ledger_hash criteria_binding policy_binding extra < "$receipt"
  case "$expected_tier" in
    small) expected_profile="light" ;;
    normal) expected_profile="standard" ;;
    complex) expected_profile="thorough" ;;
  esac
  assert_eq "5" "$version" "$label receipt version"
  assert_eq "$expected_tier" "$tier" "$label receipt tier"
  assert_eq "$expected_profile" "$profile" "$label receipt profile"
  assert_eq "$expected_required" "$required" "$label receipt requirement"
  assert_eq "$expected_required" "$clean_count" "$label receipt clean count"
  assert_eq "" "${extra:-}" "$label receipt fields"
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || {
    printf '%s: invalid receipt fingerprint %s\n' "$label" "$fingerprint" >&2
    exit 1
  }
  [[ "$ledger_hash" =~ ^[a-f0-9]{64}$ ]] || {
    printf '%s: invalid receipt ledger hash %s\n' "$label" "$ledger_hash" >&2
    exit 1
  }
  if [[ -f "$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-criteria.json" ]]; then
    expected_binding=$(DEX_DIR="$ROOT" DX_LOOP_DIR="$CASE_LOOP_DIR" bash -c 'source "$DEX_DIR/lib/common.sh"; dx_review_criteria_hash "$1"' _ "$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-criteria.json")
  fi
  assert_eq "$expected_binding" "$criteria_binding" "$label receipt criteria binding"
  expected_policy_binding=$(DEX_DIR="$ROOT" bash -c 'source "$DEX_DIR/lib/common.sh"; dx_review_policy_resolve "$1" | cut -f4' _ "$CASE_REPO")
  assert_eq "$expected_policy_binding" "$policy_binding" "$label receipt policy binding"

  if ! DEX_DIR="$ROOT" \
    HOME="$CASE_HOME" \
    DX_STATE_DIR="$CASE_STATE_DIR" \
    DX_LOOP_DIR="$CASE_LOOP_DIR" \
    DX_ARTIFACT_DIR="$CASE_DIR/artifacts" \
    DX_TOOL_DIR="$CASE_DIR/tools" \
    DX_RUN_ROOT="$CASE_DIR/runs" \
      bash -c 'source "$DEX_DIR/lib/common.sh"; dx_review_receipt_valid "$1" "$2" "$3" "$4"' \
        _ "$CASE_SESSION_ID" "$CASE_REPO" "$expected_binding" "$expected_policy_binding"; then
    printf '%s: receipt helper rejected the successful review\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

assert_retained_credit() {
  local expected_clean="$1" label="$2"
  local state_file="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-state"
  local proof_dir="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-proofs"
  if [[ ! -f "$state_file" ]]; then
    printf '%s: missing resumable review state\n' "$label" >&2
    show_case_output
    exit 1
  fi
  assert_eq "$expected_clean" "$(cut -f5 "$state_file")" "$label retained clean count"
  if [[ ! -f "$proof_dir/1/evidence.json" || ! -f "$proof_dir/1/context.md" ]]; then
    printf '%s: retained proof bundle is incomplete\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

assert_standalone_telemetry() { # <status> <pass-count> <label>
  local expected_status="$1" expected_passes="$2" label="$3"
  if ! python3 - "$CASE_DIR/runs" "$expected_status" "$expected_passes" <<'PY'
import json
import re
import sys
from pathlib import Path

run_root = Path(sys.argv[1])
expected_status = sys.argv[2]
expected_passes = int(sys.argv[3])
run_dirs = [path for path in run_root.glob("run_*") if path.is_dir()]
assert len(run_dirs) == 1, run_dirs
run_dir = run_dirs[0]
events = [
    json.loads(line)
    for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines()
    if line.strip()
]
event_types = [event["type"] for event in events]
assert event_types.count("run.started") == 1, event_types
assert event_types.count("review.pass.started") == expected_passes, event_types
assert event_types.count("review.pass.finished") == expected_passes, event_types
finished = [event for event in events if event["type"] == "review.pass.finished"]
required_fields = {
    "pass_id",
    "tier",
    "profile",
    "iteration",
    "result_kind",
    "result_reason",
    "provider_exit",
    "terminal_reason",
    "evidence_hash",
    "deterministic_checks",
    "verifier",
    "coverage",
    "evidence_valid",
}
for event in finished:
    data = event["data"]
    assert required_fields.issubset(data), data
    assert isinstance(data["evidence_valid"], bool), data
    if data["evidence_valid"]:
        assert re.fullmatch(r"[a-f0-9]{64}", data["evidence_hash"]), data
        assert data["deterministic_checks"] in {"pass", "partial", "fail", "unavailable"}, data
        assert data["verifier"] in {"pass", "fail", "not-run"}, data
        assert data["coverage"] != "none", data
    else:
        assert data["evidence_hash"] in {"none"} or re.fullmatch(r"[a-f0-9]{64}", data["evidence_hash"]), data
terminal_type = "run.completed" if expected_status == "completed" else "run.blocked"
assert event_types.count(terminal_type) == 1, event_types
summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
assert summary["status"] == expected_status, summary
PY
  then
    printf '%s: standalone telemetry contract failed\n' "$label" >&2
    show_case_output
    exit 1
  fi

  if find "$CASE_STATE_DIR" -maxdepth 1 -name '*.run-id' -print -quit | grep -q .; then
    printf '%s: standalone telemetry left a session mapping behind\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

assert_fresh_passes() {
  local expected="$1" label="$2"
  local unique_sessions unique_contexts unique_criteria contaminated missing_context_path invalid_criteria

  unique_sessions=$(awk -F '\t' '$1 == "pass" { print $2 }' "$CASE_CALLS" | sort -u | wc -l | tr -d ' ')
  unique_contexts=$(awk -F '\t' '$1 == "pass" { print $3 }' "$CASE_CALLS" | sort -u | wc -l | tr -d ' ')
  contaminated=$(awk -F '\t' '$1 == "pass" && $4 != "0" { count++ } END { print count + 0 }' "$CASE_CALLS")
  missing_context_path=$(awk -F '\t' '$1 == "pass" && $5 != "1" { count++ } END { print count + 0 }' "$CASE_CALLS")
  unique_criteria=$(awk -F '\t' '$1 == "pass" { print $9 }' "$CASE_CALLS" | sort -u | wc -l | tr -d ' ')
  invalid_criteria=$(awk -F '\t' '$1 == "pass" && $10 != "1" { count++ } END { print count + 0 }' "$CASE_CALLS")

  assert_eq "$expected" "$unique_sessions" "$label unique pass sessions"
  assert_eq "$expected" "$unique_contexts" "$label unique context paths"
  assert_eq "0" "$contaminated" "$label context contamination"
  assert_eq "0" "$missing_context_path" "$label supplied context paths"
  assert_eq "$expected" "$unique_criteria" "$label unique criteria paths"
  assert_eq "0" "$invalid_criteria" "$label criteria propagation"

  if awk -F '\t' -v parent="$CASE_SESSION_ID" '
    $1 == "pass" && $2 == parent { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$CASE_CALLS"; then
    printf '%s: pass session reused the parent session id\n' "$label" >&2
    show_case_output
    exit 1
  fi

  if find "$CASE_LOOP_DIR" -maxdepth 1 -type f -name "${CASE_SESSION_ID}-pass-*.review-criteria.json" -print -quit | grep -q .; then
    printf '%s: pass-scoped criteria artifact was not cleaned up\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

run_case() {
  local name="$1" tier="$2" results="$3" assessor_tier="${4:-}"
  local lifecycle_mode="${5:-standalone}" setup_mode="${6:-}" profile="${7:-}"
  local pass_mode="${8:-}" invocation_mode="${9:-single}" session_mode="${10:-derived}"
  local pass_timeout="${11:-}" clean_override="${12:-}" started_epoch

  CASE_NAME="$name"
  CASE_DIR="$TMP_DIR/$name"
  CASE_REPO="$CASE_DIR/repo"
  CASE_HOME="$CASE_DIR/home"
  CASE_STATE_DIR="$CASE_DIR/state"
  CASE_LOOP_DIR="$CASE_DIR/loops"
  CASE_SESSION_ID="review-loop-${name}"
  CASE_DERIVED_SESSION_ID="${CASE_SESSION_ID}-base"
  if [[ "$lifecycle_mode" == "lifecycle" ]]; then
    CASE_DERIVED_SESSION_ID="$CASE_SESSION_ID"
  fi
  if [[ "$session_mode" == "explicit" ]]; then
    CASE_DERIVED_SESSION_ID="${CASE_SESSION_ID}-derived"
  fi
  CASE_RESULTS="$CASE_DIR/results"
  CASE_CALLS="$CASE_DIR/calls"
  CASE_SENTINELS="$CASE_DIR/sentinels"
  CASE_OUTPUT="$CASE_DIR/output"
  CASE_ASSESSOR_TIER="$assessor_tier"

  mkdir -p "$CASE_REPO" "$CASE_HOME" "$CASE_STATE_DIR" "$CASE_LOOP_DIR"
  git init -q -b main "$CASE_REPO"
  git -C "$CASE_REPO" config user.name "Dex Test"
  git -C "$CASE_REPO" config user.email "dex-test@example.com"
  if [[ "$setup_mode" == "one-pass-policy" ]]; then
    mkdir -p "$CASE_REPO/.dex"
    {
      printf '%s\n' '## Review Policy'
      printf '%s\n' '| Setting | Value |'
      printf '%s\n' '|---------|-------|'
      printf '%s\n' '| small_clean_passes | 1 |'
      printf '%s\n' '| normal_clean_passes | 2 |'
      printf '%s\n' '| complex_clean_passes | 3 |'
    } > "$CASE_REPO/.dex/dex.md"
  fi
  printf 'base\n' > "$CASE_REPO/app.txt"
  if [[ "$setup_mode" != "unborn" ]]; then
    git -C "$CASE_REPO" add app.txt
    if [[ "$setup_mode" == "one-pass-policy" ]]; then
      git -C "$CASE_REPO" add .dex/dex.md
    fi
    git -C "$CASE_REPO" commit -qm "test: initialize review fixture"
  fi
  printf 'candidate change\n' >> "$CASE_REPO/app.txt"
  printf '%s\n' "$results" > "$CASE_RESULTS"
  : > "$CASE_CALLS"
  : > "$CASE_SENTINELS"

  started_epoch=$(date +%s)
  set +e
  DEX_DIR="$ROOT" \
  HOME="$CASE_HOME" \
  DX_STATE_DIR="$CASE_STATE_DIR" \
  DX_LOOP_DIR="$CASE_LOOP_DIR" \
  DX_ARTIFACT_DIR="$CASE_DIR/artifacts" \
  DX_TOOL_DIR="$CASE_DIR/tools" \
  DX_RUN_ROOT="$CASE_DIR/runs" \
  CASE_REPO="$CASE_REPO" \
  CASE_PROOF_DIR="$CASE_DIR" \
  CASE_SESSION_ID="$CASE_SESSION_ID" \
  CASE_DERIVED_SESSION_ID="$CASE_DERIVED_SESSION_ID" \
  CASE_RESULTS="$CASE_RESULTS" \
  CASE_CALLS="$CASE_CALLS" \
  CASE_SENTINELS="$CASE_SENTINELS" \
  CASE_ASSESSOR_TIER="$CASE_ASSESSOR_TIER" \
  CASE_TIER="$tier" \
  CASE_PROFILE="$profile" \
  CASE_LIFECYCLE_MODE="$lifecycle_mode" \
  CASE_SETUP_MODE="$setup_mode" \
  CASE_PASS_MODE="$pass_mode" \
  CASE_INVOCATION_MODE="$invocation_mode" \
  CASE_SESSION_MODE="$session_mode" \
  CASE_PASS_TIMEOUT="$pass_timeout" \
  CASE_CLEAN_OVERRIDE="$clean_override" \
  DEX_FACTORY_SYNC=0 \
    zsh -fc '
      source "$DEX_DIR/dx.sh"
      source "$DEX_DIR/tests/review-proof-fixture.sh"
      cd "$CASE_REPO"

      unset DEX_LOOP_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE DEX_LOOP_PROMISE \
        DEX_SESSION_ID \
        DEX_REVIEW_ASSESSMENT_ACTIVE DEX_REVIEW_PROFILE DEX_REVIEW_CLEAN_PASSES \
        DEX_REVIEW_PASS_TIMEOUT DEX_RUN_ID DX_REVIEW_PROFILE

      case "$CASE_LIFECYCLE_MODE" in
        lifecycle)
          export DEX_LOOP_ACTIVE=1
          export DEX_LOOP_PHASE=3
          ;;
        stale-env)
          export DEX_LOOP_ACTIVE=1
          export DEX_LOOP_PHASE=2
          ;;
      esac
      if [[ "$CASE_SESSION_MODE" == "explicit" ]]; then
        export DEX_SESSION_ID="$CASE_SESSION_ID"
      fi
      if [[ -n "$CASE_TIER" ]]; then
        export DEX_REVIEW_TIER="$CASE_TIER"
      else
        unset DEX_REVIEW_TIER
      fi
      if [[ -n "$CASE_PROFILE" ]]; then
        export DEX_REVIEW_PROFILE="$CASE_PROFILE"
      fi
      export DEX_REVIEW_DISABLE_MCP=1
      if [[ -n "$CASE_PASS_TIMEOUT" ]]; then
        export DEX_REVIEW_PASS_TIMEOUT="$CASE_PASS_TIMEOUT"
      fi
      if [[ -n "$CASE_CLEAN_OVERRIDE" ]]; then
        export DEX_REVIEW_CLEAN_PASSES="$CASE_CLEAN_OVERRIDE"
      fi

      __dx_refresh_provider() {
        DX_PROVIDER_ENGINE=claude
        DX_PROVIDER_AGENT=claude
        DX_CLAUDE_FLAGS=()
        return 0
      }
      dx_session_id() { print -r -- "$CASE_DERIVED_SESSION_ID"; }
      dx_provider_write_session_state() { return 0; }
      dx_provider_cleanup_session_state() { return 0; }
      __dx_provider_prompt() { return 0; }
      claude() { return 0; }
      __dx_review_standalone_session_id() { print -r -- "$CASE_SESSION_ID"; }

      if [[ "$CASE_LIFECYCLE_MODE" == "lifecycle" ]]; then
        lifecycle_phase=3
        [[ "$CASE_SETUP_MODE" == "phase-2" ]] && lifecycle_phase=2
        lifecycle_session_id="${DEX_SESSION_ID:-$(dx_session_id)}"
        printf "%s\n" "$lifecycle_phase" >| "$(dx_state_file "$lifecycle_session_id")"
        if [[ "$CASE_SETUP_MODE" != "missing-criteria" ]]; then
          printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Exercise the adaptive review loop.\"],\"acceptance_criteria\":[\"Independent clean waves satisfy the selected gate.\"],\"verification_requirements\":[\"Run tests/review-loop-test.sh.\"]}" >| "$(dx_review_criteria_file "$lifecycle_session_id")"
          if [[ "$CASE_SETUP_MODE" != "missing-seal" ]]; then
            dx_review_approve_criteria "$lifecycle_session_id" initial "$(dx_review_criteria_hash "$(dx_review_criteria_file "$lifecycle_session_id")")" >/dev/null
          fi
        fi
      fi

      __test_review_criteria_evidence() {
        local binding="$1" criteria_path="$2" result="$3" context_path="$4" omit_evidence="$5"
        local criteria_hashes objective_hash acceptance_hash verification_hash
        local objective_outcome=met acceptance_outcome=met verification_outcome=met
        local objective_ref="criteria:objectives:1:fixture-objective"
        local acceptance_ref="criteria:acceptance_criteria:1:fixture-acceptance"
        local verification_ref="criteria:verification_requirements:1:fixture-verification"

        if [[ "$binding" == "standalone" ]]; then
          printf "%s\n" "{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]}"
          return 0
        fi

        criteria_hashes=$(dx_review_criteria_coverage_json "$binding" "$criteria_path") || return 1
        objective_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"objectives\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
        acceptance_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"acceptance_criteria\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
        verification_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"verification_requirements\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
        [[ "$objective_hash" =~ ^[a-f0-9]{64}$ && "$acceptance_hash" =~ ^[a-f0-9]{64}$ && \
          "$verification_hash" =~ ^[a-f0-9]{64}$ ]] || return 1

        if [[ "$omit_evidence" == "1" ]]; then
          printf "%s\n" "{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]}"
          return 0
        fi

        case "$result" in
          FINDINGS:*) acceptance_outcome=not_met ;;
          BLOCKED:*) verification_outcome=blocked ;;
        esac
        {
          printf "Evidence-Ref: %s | analysis | Reviewed the lifecycle objective against the complete supplied scope.\n" "$objective_ref"
          printf "Evidence-Ref: %s | test | Exercised the selected clean-pass gate in this focused fixture.\n" "$acceptance_ref"
          printf "Evidence-Ref: %s | command | Ran the review-loop fixture verification required by this criterion.\n" "$verification_ref"
        } >> "$context_path"
        printf "{\"acceptance_criteria\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"%s\"]}],\"objectives\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"%s\"]}],\"verification_requirements\":[{\"item_hash\":\"%s\",\"outcome\":\"%s\",\"evidence_refs\":[\"%s\"]}]}\n" \
          "$acceptance_hash" "$acceptance_outcome" "$acceptance_ref" \
          "$objective_hash" "$objective_outcome" "$objective_ref" \
          "$verification_hash" "$verification_outcome" "$verification_ref"
      }

      __dx_claude() {
        local invocation_args="$*"
        if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-}" == "1" ]]; then
          local assessment_index assessment_criteria_path assessment_binding assessment_policy_record
          local assessment_small assessment_normal assessment_complex assessment_policy_binding
          assessment_index=$(awk -F "\t" '\''$1 == "assessor" { count++ } END { print count + 1 }'\'' "$CASE_CALLS")
          printf "assessor\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
          assessment_policy_record=$(dx_review_policy_resolve "$CASE_REPO") || return 96
          IFS=$'\''\t'\'' read -r assessment_small assessment_normal assessment_complex \
            assessment_policy_binding _ _ <<< "$assessment_policy_record"
          if [[ "$invocation_args" != *"small: ${assessment_small} consecutive CLEAN waves"* || \
                "$invocation_args" != *"normal: ${assessment_normal} consecutive CLEAN waves"* || \
                "$invocation_args" != *"complex: ${assessment_complex} consecutive CLEAN waves"* || \
                "$invocation_args" != *"Policy binding: ${assessment_policy_binding}"* ]]; then
            return 96
          fi
          assessment_criteria_path=$(dx_review_criteria_file "$DEX_SESSION_ID")
          if [[ -e "$assessment_criteria_path" ]]; then
            assessment_binding=$(dx_review_criteria_hash "$assessment_criteria_path" 2>/dev/null || true)
            if [[ ! "$assessment_binding" =~ ^[a-f0-9]{64}$ ||
                  "${DEX_REVIEW_CRITERIA_BINDING:-}" != "$assessment_binding" ||
                  "${DEX_REVIEW_CRITERIA_FILE:-}" != "$assessment_criteria_path" ||
                  "$invocation_args" != *"$assessment_criteria_path"* ||
                  "$invocation_args" != *"$assessment_binding"* ||
                  "$invocation_args" == *"$(dx_review_criteria_file "$CASE_SESSION_ID")"* ]]; then
              return 96
            fi
          elif [[ "${DEX_REVIEW_CRITERIA_BINDING:-}" != "standalone" ||
                  "${DEX_REVIEW_CRITERIA_FILE:-}" != "$assessment_criteria_path" ||
                  "$invocation_args" != *"Approved requirements: N/A — standalone review"* ||
                  "$invocation_args" == *"$assessment_criteria_path"* ]]; then
            return 96
          fi
          printf "%s\n" "$assessment_criteria_path" >> "$CASE_SENTINELS"
          if [[ -n "$CASE_ASSESSOR_TIER" ]]; then
            if [[ "$CASE_ASSESSOR_TIER" == "mutate" || \
                  "$CASE_ASSESSOR_TIER" == "mutate-once" && "$assessment_index" -eq 1 ]]; then
              printf "assessor-mutation-%s\n" "$assessment_index" >> "$CASE_REPO/app.txt"
              printf "%s\n" "{\"tier\":\"small\",\"reason_codes\":\"localized-change,focused-verification\"}"
            else
              local selected_tier="$CASE_ASSESSOR_TIER"
              [[ "$selected_tier" == "mutate-once" ]] && selected_tier="small"
              printf "{\"tier\":\"%s\",\"reason_codes\":\"localized-change,focused-verification\"}\n" "$selected_tier"
            fi
            return 0
          fi
          return 98
        fi

        local pass_index result context_path criteria_path criteria_evidence evidence_path sentinel contamination=0 context_supplied=0 criteria_ok=0 hash apply_fix=0 should_timeout=0
        local expected_pass_binding omit_criteria_evidence=0
        local evidence_checks=pass evidence_verifier=pass evidence_findings=0 evidence_fixes=0 coverage
        case "$CASE_PASS_MODE" in
          timeout) should_timeout=1 ;;
          timeout-once)
            grep -q "^timeout-once[[:space:]]" "$CASE_CALLS" || should_timeout=1
            ;;
        esac
        if [[ $should_timeout -eq 1 ]]; then
          printf "pass-start\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
          if [[ "$CASE_PASS_MODE" == "timeout-once" ]]; then
            printf "timeout-once\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
          fi
          sleep 10
          return 97
        fi
        pass_index=$(awk -F "\t" '\''$1 == "pass" { count++ } END { print count + 1 }'\'' "$CASE_CALLS")
        result=$(sed -n "${pass_index}p" "$CASE_RESULTS")
        if [[ -z "$result" ]]; then
          printf "pass\t%s\t%s\t0\t0\t%s\t%s\tMISSING\n" \
            "${DEX_SESSION_ID:-missing}" \
            "$(dx_review_context_file "${DEX_SESSION_ID:-missing}")" \
            "${DEX_REVIEW_TIER:-}" "${DEX_REVIEW_PROFILE:-}" >> "$CASE_CALLS"
          return 97
        fi
        expected_pass_binding=$(dx_review_pass_binding "${DEX_REVIEW_PASS_ID:-}" \
          "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "${DEX_REVIEW_CRITERIA_BINDING:-}" \
          "${DEX_REVIEW_POLICY_BINDING:-}" 2>/dev/null || true)
        if ! dx_review_policy_binding_valid "${DEX_REVIEW_POLICY_BINDING:-}" || \
           ! dx_review_pass_id_valid "${DEX_REVIEW_PASS_ID:-}" || \
           [[ -z "$expected_pass_binding" || "$expected_pass_binding" != "${DEX_REVIEW_PASS_BINDING:-}" ]] || \
           [[ "$invocation_args" != *"${DEX_REVIEW_PASS_ID}"* || \
              "$invocation_args" != *"${DEX_REVIEW_POLICY_BINDING}"* || \
              "$invocation_args" != *"${DEX_REVIEW_PASS_BINDING}"* ]]; then
          return 96
        fi

        if [[ "$CASE_PASS_MODE" == "expect-codebase" && "$pass_index" -ge 2 ]]; then
          if [[ "$invocation_args" != *"No current change set was found"* || "$invocation_args" != *"git ls-files | sort"* ]]; then
            printf "scope-refresh-failed\t%s\n" "$pass_index" >> "$CASE_CALLS"
            return 95
          fi
          printf "scope-refresh-codebase\t%s\n" "$pass_index" >> "$CASE_CALLS"
        elif [[ "$CASE_PASS_MODE" == "expect-changes" && "$pass_index" -ge 2 ]]; then
          if [[ "$invocation_args" != *"full current change set"* || "$invocation_args" != *"git ls-files --others --exclude-standard"* ]]; then
            printf "scope-refresh-failed\t%s\n" "$pass_index" >> "$CASE_CALLS"
            return 95
          fi
          printf "scope-refresh-changes\t%s\n" "$pass_index" >> "$CASE_CALLS"
        fi

        context_path=$(dx_review_context_file "$DEX_SESSION_ID")
        criteria_path=$(dx_review_criteria_file "$DEX_SESSION_ID")
        [[ "$invocation_args" == *"$context_path"* ]] && context_supplied=1
        if [[ "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" == "standalone" ]]; then
          if [[ ! -e "$criteria_path" && "$invocation_args" == *"Approved requirements: N/A — standalone review"* && "$invocation_args" != *"$criteria_path"* ]]; then
            criteria_ok=1
          fi
        elif [[ "$(dx_review_criteria_hash "$criteria_path" 2>/dev/null)" == "${DEX_REVIEW_CRITERIA_BINDING:-}" &&
                "$invocation_args" == *"$criteria_path"* &&
                "$invocation_args" == *"${DEX_REVIEW_CRITERIA_BINDING}"* &&
                "$invocation_args" != *"$(dx_review_criteria_file "$CASE_SESSION_ID")"* ]]; then
          criteria_ok=1
        fi
        if [[ "$CASE_PASS_MODE" == "omit-criteria-coverage" ]]; then
          omit_criteria_evidence=1
        fi
        while IFS= read -r sentinel; do
          [[ -n "$sentinel" && "$invocation_args" == *"$sentinel"* ]] && contamination=1
        done < "$CASE_SENTINELS"

        sentinel="private-context-${pass_index}"
        {
          printf "## Scope\n\n%s for the complete supplied change set and pass %s.\n\n" "$sentinel" "$pass_index"
          printf "## Acceptance Criteria\n\nCriteria binding: %s\n\n" "${DEX_REVIEW_CRITERIA_BINDING:-standalone}"
          printf "## Deterministic Checks\n\nAll applicable fixture checks passed.\n\n"
          printf "## Review Coverage\n\nCore review domains were independently inspected.\n\n"
          printf "## Verification\n\nThe fixture verifier rechecked the final result and evidence.\n"
        } >| "$context_path"
        printf "%s\n%s\n%s\n" "$sentinel" "$context_path" "$criteria_path" >> "$CASE_SENTINELS"
        case "$result" in
          CLEAN_MUTATED)
            printf "invalid-clean-mutation\n" >> "$CASE_REPO/app.txt"
            result="CLEAN"
            ;;
          FINDINGS_FIXED_NO_CHANGE:*)
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_CLEAR_SCOPE:*)
            git -C "$CASE_REPO" restore --source=HEAD --staged --worktree -- app.txt
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_ADD_UNTRACKED:*)
            printf "added-by-review\n" > "$CASE_REPO/review-added.txt"
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_COMMIT:*)
            printf "committed-fix-%s\n" "$pass_index" >> "$CASE_REPO/app.txt"
            git -C "$CASE_REPO" add app.txt
            git -C "$CASE_REPO" commit -qm "test: commit review fix"
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_COMMIT_BOUNDARY:*)
            printf "committed-boundary-fix-%s\n" "$pass_index" >> "$CASE_REPO/app.txt"
            git -C "$CASE_REPO" add app.txt
            git -C "$CASE_REPO" commit -qm "test: commit review fix and move boundary"
            git -C "$CASE_REPO" update-ref refs/remotes/origin/main HEAD^
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_EMPTY_COMMIT:*)
            git -C "$CASE_REPO" commit -qm --allow-empty "test: empty review commit"
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_SWITCH_BRANCH:*)
            git -C "$CASE_REPO" switch -qc review-switched-branch
            printf "branch-fix-%s\n" "$pass_index" >> "$CASE_REPO/app.txt"
            result="FINDINGS_FIXED:${result##*:}"
            ;;
          FINDINGS_FIXED_SAME:*)
            result="FINDINGS_FIXED:${result##*:}"
            apply_fix=1
            hash="1111111111111111"
            ;;
          FINDINGS_FIXED:*)
            apply_fix=1
            ;;
        esac
        [[ "$result" == "CLEAN" ]] && hash=$(dx_review_empty_findings_hash)
        [[ -n "$hash" ]] || hash=$(printf "%016x" "$pass_index")
        printf "%s\n" "$hash" >| "$(dx_findings_file "$DEX_SESSION_ID")"

        if [[ $apply_fix -eq 1 ]]; then
          printf "fixed-%s\n" "$pass_index" >> "$CASE_REPO/app.txt"
        fi

        case "$result" in
          FINDINGS_FIXED:*)
            evidence_findings="${result##*:}"
            evidence_fixes="$evidence_findings"
            ;;
          FINDINGS:*)
            evidence_findings="${result##*:}"
            ;;
          BLOCKED:*|CHURN:*)
            evidence_checks=partial
            evidence_verifier=not-run
            ;;
        esac
        if [[ "${DEX_REVIEW_PROFILE:-}" == "thorough" ]]; then
          coverage="[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\",\"frontend\",\"devops\",\"performance\",\"observability\"]"
        else
          coverage="[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"]"
        fi
        criteria_evidence=$(__test_review_criteria_evidence \
          "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" "$criteria_path" "$result" "$context_path" \
          "$omit_criteria_evidence") || return 96
        evidence_path=$(dx_review_evidence_file "$DEX_SESSION_ID")
        printf "{\"version\":3,\"scope_fingerprint\":\"%s\",\"criteria_binding\":\"%s\",\"policy_binding\":\"%s\",\"pass_binding\":\"%s\",\"criteria_evidence\":%s,\"deterministic_checks\":\"%s\",\"coverage\":%s,\"verifier\":\"%s\",\"verified_findings\":%s,\"fixes_applied\":%s}\n" \
          "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" \
          "${DEX_REVIEW_POLICY_BINDING:-}" "${DEX_REVIEW_PASS_BINDING:-}" "$criteria_evidence" \
          "$evidence_checks" "$coverage" "$evidence_verifier" "$evidence_findings" "$evidence_fixes" >| "$evidence_path"

        printf "%s\n" "$result" >| "$(dx_review_result_file "$DEX_SESSION_ID")"
        touch "$(dx_complete_file "$DEX_SESSION_ID")"
        case "$CASE_PASS_MODE" in
          parent-criteria-tamper)
            printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Tampered parent requirements.\"],\"acceptance_criteria\":[\"The parent hash changes.\"],\"verification_requirements\":[\"Pause review.\"]}" >| "$(dx_review_criteria_file "$CASE_SESSION_ID")"
            ;;
          pass-criteria-tamper)
            printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Tampered pass requirements.\"],\"acceptance_criteria\":[\"The pass hash changes.\"],\"verification_requirements\":[\"Pause review.\"]}" >| "$criteria_path"
            ;;
        esac
        printf "pass\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$DEX_SESSION_ID" "$context_path" "$contamination" "$context_supplied" \
          "${DEX_REVIEW_TIER:-}" "${DEX_REVIEW_PROFILE:-}" "$result" "$criteria_path" "$criteria_ok" >> "$CASE_CALLS"
        return 0
      }

      case "$CASE_SETUP_MODE" in
        committed-change)
          git -C "$CASE_REPO" update-ref refs/remotes/origin/main HEAD
          git -C "$CASE_REPO" add app.txt
          git -C "$CASE_REPO" commit -qm "test: commit candidate change"
          ;;
        clean-codebase)
          git -C "$CASE_REPO" restore --source=HEAD --staged --worktree -- app.txt
          ;;
        corrupt-state)
          fingerprint=$(dx_review_scope_fingerprint "$CASE_REPO")
          criteria_binding=$(dx_review_resolve_criteria_binding "$CASE_SESSION_ID")
          policy_record=$(dx_review_policy_resolve "$CASE_REPO")
          policy_binding=$(printf "%s\n" "$policy_record" | cut -f4)
          dx_review_write_selection "$CASE_SESSION_ID" small environment operator-override \
            "$CASE_REPO" "" "$criteria_binding" "$policy_binding"
          printf "3\tsmall\t3\t0\t3\t%s\t%s\t%s\n" \
            "$fingerprint" "$criteria_binding" "$policy_binding" >| "$(dx_review_state_file "$CASE_SESSION_ID")"
          ;;
        resume-state|resume-criteria-change)
          fingerprint=$(dx_review_scope_fingerprint "$CASE_REPO")
          criteria_binding=$(dx_review_resolve_criteria_binding "$CASE_SESSION_ID")
          policy_record=$(dx_review_policy_resolve "$CASE_REPO")
          policy_binding=$(printf "%s\n" "$policy_record" | cut -f4)
          dx_review_write_selection "$CASE_SESSION_ID" small environment operator-override \
            "$CASE_REPO" "" "$criteria_binding" "$policy_binding"
          prior_evidence="$CASE_PROOF_DIR/prior-clean.evidence.json"
          prior_context="$CASE_PROOF_DIR/prior-clean.context.md"
          dx_test_write_clean_review_proof "$CASE_SESSION_ID" prior-clean-pass light \
            "$fingerprint" "$criteria_binding" "$policy_binding" "$prior_evidence" "$prior_context"
          dx_review_ledger_append "$CASE_SESSION_ID" 1 prior-clean-pass light "$fingerprint" \
            "$criteria_binding" "$policy_binding" "$prior_evidence" "$prior_context"
          dx_review_write_state "$CASE_SESSION_ID" small 3 1 1 "$CASE_REPO" \
            "$criteria_binding" "$policy_binding"
          if [[ "$CASE_SETUP_MODE" == "resume-criteria-change" ]]; then
            previous_criteria_hash=$(dx_review_read_criteria_approval "$CASE_SESSION_ID")
            printf "%s\n" "{\"version\":1,\"source\":\"approved-plan\",\"objectives\":[\"Use the changed approved requirements.\"],\"acceptance_criteria\":[\"Old clean credit is discarded.\"],\"verification_requirements\":[\"Run three fresh waves.\"]}" >| "$(dx_review_criteria_file "$CASE_SESSION_ID")"
            changed_criteria_hash=$(dx_review_criteria_hash "$(dx_review_criteria_file "$CASE_SESSION_ID")")
            dx_review_approve_criteria "$CASE_SESSION_ID" reapproved "$previous_criteria_hash" "$changed_criteria_hash" >/dev/null
            dx_review_write_selection "$CASE_SESSION_ID" small environment operator-override \
              "$CASE_REPO" "" "$changed_criteria_hash" "$policy_binding"
          fi
          ;;
      esac

      if [[ "$CASE_INVOCATION_MODE" == "twice" ]]; then
        dxreviewloop
        first_status=$?
        printf "invocation\tfirst\t%s\n" "$first_status" >> "$CASE_CALLS"
        if [[ "$CASE_LIFECYCLE_MODE" == "lifecycle" && "$CASE_ASSESSOR_TIER" == "mutate-once" ]]; then
          criteria_file=$(dx_review_criteria_file "$CASE_SESSION_ID")
          [[ -f "$criteria_file" ]] || {
            printf "lifecycle criteria were removed after the first review invocation\n" >&2
            return 99
          }
          dx_review_criteria_valid "$criteria_file" || {
            printf "lifecycle criteria became invalid after the first review invocation\n" >&2
            return 99
          }
        fi
        dxreviewloop
      else
        dxreviewloop
      fi
    ' > "$CASE_OUTPUT" 2>&1
  CASE_RC=$?
  set -e
  CASE_ELAPSED_SECONDS=$(( $(date +%s) - started_epoch ))
}

run_concurrent_case() {
  CASE_NAME="concurrent-same-session"
  CASE_DIR="$TMP_DIR/$CASE_NAME"
  CASE_REPO="$CASE_DIR/repo"
  CASE_HOME="$CASE_DIR/home"
  CASE_STATE_DIR="$CASE_DIR/state"
  CASE_LOOP_DIR="$CASE_DIR/loops"
  CASE_SESSION_ID="review-loop-$CASE_NAME"
  CASE_DERIVED_SESSION_ID="$CASE_SESSION_ID"
  CASE_CALLS="$CASE_DIR/calls"
  CASE_OUTPUT="$CASE_DIR/owner-output"
  local contender_output="$CASE_DIR/contender-output"
  local owner_ready="$CASE_DIR/owner-ready" owner_release="$CASE_DIR/owner-release"
  local owner_pid owner_rc contender_rc
  local state_file="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-state"
  local selection_file="$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-selection"
  local busy_file="$CASE_LOOP_DIR/${CASE_SESSION_ID}.phase-3.busy"
  local state_before state_after selection_before selection_after
  local owner_alive_after_contender=0 busy_present_after_contender=0

  mkdir -p "$CASE_REPO" "$CASE_HOME" "$CASE_STATE_DIR" "$CASE_LOOP_DIR"
  git init -q -b main "$CASE_REPO"
  git -C "$CASE_REPO" config user.name "Dex Test"
  git -C "$CASE_REPO" config user.email "dex-test@example.com"
  printf 'base\n' > "$CASE_REPO/app.txt"
  git -C "$CASE_REPO" add app.txt
  git -C "$CASE_REPO" commit -qm "test: initialize concurrent review fixture"
  : > "$CASE_CALLS"
  printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Serialize review ownership."],"acceptance_criteria":["Only one loop owns the checkout."],"verification_requirements":["Run the concurrency fixture."]}' > "$CASE_LOOP_DIR/${CASE_SESSION_ID}.review-criteria.json"
  DEX_DIR="$ROOT" DX_LOOP_DIR="$CASE_LOOP_DIR" bash -c 'source "$DEX_DIR/lib/common.sh"; criteria_file=$(dx_review_criteria_file "$1"); dx_review_approve_criteria "$1" initial "$(dx_review_criteria_hash "$criteria_file")" >/dev/null' _ "$CASE_SESSION_ID"

  launch_concurrent_review() {
    local role="$1" output_file="$2"
    DEX_DIR="$ROOT" \
    HOME="$CASE_HOME" \
    DX_STATE_DIR="$CASE_STATE_DIR" \
    DX_LOOP_DIR="$CASE_LOOP_DIR" \
    DX_ARTIFACT_DIR="$CASE_DIR/artifacts" \
    DX_TOOL_DIR="$CASE_DIR/tools" \
    DX_RUN_ROOT="$CASE_DIR/runs" \
    CASE_REPO="$CASE_REPO" \
    CASE_SESSION_ID="$CASE_SESSION_ID" \
    CASE_CALLS="$CASE_CALLS" \
    CASE_ROLE="$role" \
    CASE_OWNER_READY="$owner_ready" \
    CASE_OWNER_RELEASE="$owner_release" \
    DEX_FACTORY_SYNC=0 \
      zsh -fc '
        source "$DEX_DIR/dx.sh"
        cd "$CASE_REPO"

        export DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 DEX_REVIEW_TIER=small
        export DEX_REVIEW_DISABLE_MCP=1 DEX_REVIEW_PASS_TIMEOUT=0
        unset DEX_SESSION_ID DEX_REVIEW_PROFILE DEX_REVIEW_CLEAN_PASSES \
          DEX_RUN_ID DX_REVIEW_PROFILE

        __dx_refresh_provider() {
          DX_PROVIDER_ENGINE=claude
          DX_PROVIDER_AGENT=claude
          DX_CLAUDE_FLAGS=()
          return 0
        }
        dx_session_id() { print -r -- "$CASE_SESSION_ID"; }
        dx_provider_write_session_state() { return 0; }
        dx_provider_cleanup_session_state() { return 0; }
        __dx_provider_prompt() { return 0; }
        claude() { return 0; }

        printf "3\n" >| "$(dx_state_file "$CASE_SESSION_ID")"

        __test_concurrent_criteria_evidence() {
          local criteria_path="$1" context_path="$2" criteria_hashes
          local objective_hash acceptance_hash verification_hash
          criteria_hashes=$(dx_review_criteria_coverage_json \
            "$DEX_REVIEW_CRITERIA_BINDING" "$criteria_path") || return 1
          objective_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"objectives\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
          acceptance_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"acceptance_criteria\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
          verification_hash=$(printf "%s\n" "$criteria_hashes" | sed -E "s/.*\"verification_requirements\":\\[\"([a-f0-9]{64})\"\\].*/\\1/")
          [[ "$objective_hash" =~ ^[a-f0-9]{64}$ && "$acceptance_hash" =~ ^[a-f0-9]{64}$ && \
            "$verification_hash" =~ ^[a-f0-9]{64}$ ]] || return 1
          {
            printf "Evidence-Ref: criteria:objectives:1:fixture-objective | analysis | Reviewed the lifecycle objective against the complete supplied scope.\n"
            printf "Evidence-Ref: criteria:acceptance_criteria:1:fixture-acceptance | test | Exercised exclusive review-loop ownership in the concurrent fixture.\n"
            printf "Evidence-Ref: criteria:verification_requirements:1:fixture-verification | command | Ran the concurrent review-loop fixture required by this criterion.\n"
          } >> "$context_path"
          printf "{\"acceptance_criteria\":[{\"item_hash\":\"%s\",\"outcome\":\"met\",\"evidence_refs\":[\"criteria:acceptance_criteria:1:fixture-acceptance\"]}],\"objectives\":[{\"item_hash\":\"%s\",\"outcome\":\"met\",\"evidence_refs\":[\"criteria:objectives:1:fixture-objective\"]}],\"verification_requirements\":[{\"item_hash\":\"%s\",\"outcome\":\"met\",\"evidence_refs\":[\"criteria:verification_requirements:1:fixture-verification\"]}]}\n" \
            "$acceptance_hash" "$objective_hash" "$verification_hash"
        }

        __dx_claude() {
          if [[ "$CASE_ROLE" == "contender" ]]; then
            printf "contender-pass\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
            return 97
          fi

          local pass_index context_path criteria_path criteria_evidence evidence_path expected_pass_binding
          pass_index=$(awk -F "\t" '\''$1 == "owner-pass" { count++ } END { print count + 1 }'\'' "$CASE_CALLS")
          if [[ "$pass_index" -eq 1 ]]; then
            touch "$CASE_OWNER_READY"
            for _ in {1..200}; do
              [[ -f "$CASE_OWNER_RELEASE" ]] && break
              sleep 0.05
            done
            [[ -f "$CASE_OWNER_RELEASE" ]] || return 96
          fi

          expected_pass_binding=$(dx_review_pass_binding "${DEX_REVIEW_PASS_ID:-}" \
            "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "${DEX_REVIEW_CRITERIA_BINDING:-}" \
            "${DEX_REVIEW_POLICY_BINDING:-}" 2>/dev/null || true)
          if ! dx_review_policy_binding_valid "${DEX_REVIEW_POLICY_BINDING:-}" || \
             ! dx_review_pass_id_valid "${DEX_REVIEW_PASS_ID:-}" || \
             [[ -z "$expected_pass_binding" || "$expected_pass_binding" != "${DEX_REVIEW_PASS_BINDING:-}" ]]; then
            return 96
          fi

          context_path=$(dx_review_context_file "$DEX_SESSION_ID")
          {
            printf "## Scope\n\nConcurrent fixture pass %s reviewed the supplied scope.\n\n" "$pass_index"
            printf "## Acceptance Criteria\n\nCriteria binding: %s\n\n" "${DEX_REVIEW_CRITERIA_BINDING:-standalone}"
            printf "## Deterministic Checks\n\nAll applicable fixture checks passed.\n\n"
            printf "## Review Coverage\n\nCorrectness, security, contracts, tests, and architecture.\n\n"
            printf "## Verification\n\nThe independent fixture verifier passed.\n"
          } >| "$context_path"
          criteria_path=$(dx_review_criteria_file "$DEX_SESSION_ID")
          criteria_evidence=$(__test_concurrent_criteria_evidence "$criteria_path" "$context_path") || return 96
          evidence_path=$(dx_review_evidence_file "$DEX_SESSION_ID")
          printf "{\"version\":3,\"scope_fingerprint\":\"%s\",\"criteria_binding\":\"%s\",\"policy_binding\":\"%s\",\"pass_binding\":\"%s\",\"criteria_evidence\":%s,\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}\n" \
            "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "$DEX_REVIEW_CRITERIA_BINDING" \
            "$DEX_REVIEW_POLICY_BINDING" "$DEX_REVIEW_PASS_BINDING" "$criteria_evidence" >| "$evidence_path"
          dx_review_empty_findings_hash >| "$(dx_findings_file "$DEX_SESSION_ID")"
          printf "CLEAN\n" >| "$(dx_review_result_file "$DEX_SESSION_ID")"
          touch "$(dx_complete_file "$DEX_SESSION_ID")"
          printf "owner-pass\t%s\n" "$DEX_SESSION_ID" >> "$CASE_CALLS"
          return 0
        }

        dxreviewloop
      ' > "$output_file" 2>&1
  }

  launch_concurrent_review owner "$CASE_OUTPUT" &
  owner_pid=$!
  for _ in {1..100}; do
    [[ -f "$owner_ready" ]] && break
    kill -0 "$owner_pid" 2>/dev/null || break
    sleep 0.05
  done
  if [[ ! -f "$owner_ready" ]]; then
    touch "$owner_release"
    kill "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    printf 'concurrent same-session review: owner did not reach the first pass\n' >&2
    show_case_output
    exit 1
  fi

  state_before=$(cat "$state_file" 2>/dev/null || printf 'MISSING')
  selection_before=$(cat "$selection_file" 2>/dev/null || printf 'MISSING')
  set +e
  launch_concurrent_review contender "$contender_output"
  contender_rc=$?
  set -e
  state_after=$(cat "$state_file" 2>/dev/null || printf 'MISSING')
  selection_after=$(cat "$selection_file" 2>/dev/null || printf 'MISSING')
  kill -0 "$owner_pid" 2>/dev/null && owner_alive_after_contender=1
  [[ -f "$busy_file" ]] && busy_present_after_contender=1

  touch "$owner_release"
  set +e
  wait "$owner_pid"
  owner_rc=$?
  set -e
  CASE_RC=$owner_rc

  assert_eq "1" "$([[ "$contender_rc" -ne 0 ]] && printf '1' || printf '0')" \
    "concurrent contender rejected"
  assert_eq "0" "$(awk -F '\t' '$1 == "contender-pass" { count++ } END { print count + 0 }' "$CASE_CALLS")" \
    "concurrent contender launched no pass"
  assert_eq "1" "$owner_alive_after_contender" "concurrent owner remains active"
  assert_eq "1" "$busy_present_after_contender" "concurrent owner busy marker preserved"
  assert_eq "$state_before" "$state_after" "concurrent owner review state preserved"
  assert_eq "$selection_before" "$selection_after" "concurrent owner selection preserved"
  assert_success "concurrent owner"
  assert_eq "3" "$(awk -F '\t' '$1 == "owner-pass" { count++ } END { print count + 0 }' "$CASE_CALLS")" \
    "concurrent owner pass count"
  assert_receipt "small" "3" "concurrent owner"
}

run_case "small-gate" "small" $'CLEAN\nCLEAN\nCLEAN'
assert_success "small gate"
assert_eq "3" "$(call_count pass)" "small gate pass count"
assert_no_assessor "small gate explicit tier"
assert_fresh_passes "3" "small gate"
assert_receipt "small" "3" "small gate"
assert_standalone_telemetry "completed" "3" "small gate"

run_case "trusted-one-pass-policy" "small" "CLEAN" "" \
  "standalone" "one-pass-policy"
assert_success "trusted one-pass policy"
assert_eq "1" "$(call_count pass)" "trusted one-pass policy pass count"
assert_no_assessor "trusted one-pass policy explicit tier"
assert_receipt "small" "1" "trusted one-pass policy"

run_case "unborn-default-policy" "small" $'CLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "unborn"
assert_success "unborn default policy"
assert_eq "3" "$(call_count pass)" "unborn default policy pass count"
assert_no_assessor "unborn default policy explicit tier"
assert_receipt "small" "3" "unborn default policy"

run_case "standalone-assessor" "" $'CLEAN\nCLEAN\nCLEAN' "small"
assert_success "standalone assessor"
assert_eq "1" "$(call_count assessor)" "standalone assessor call count"
assert_eq "3" "$(call_count pass)" "standalone assessor pass count"
assert_fresh_passes "3" "standalone assessor"
assert_receipt "small" "3" "standalone assessor"

run_case "explicit-lifecycle-session" "small" $'CLEAN\nCLEAN\nCLEAN' "" \
  "lifecycle" "" "" "" "single" "explicit"
assert_success "explicit lifecycle session"
assert_eq "3" "$(call_count pass)" "explicit lifecycle session pass count"
assert_no_assessor "explicit lifecycle session"
assert_fresh_passes "3" "explicit lifecycle session"
assert_receipt "small" "3" "explicit lifecycle session"
if [[ -e "$CASE_LOOP_DIR/${CASE_DERIVED_SESSION_ID}.review-receipt" ]]; then
  printf 'explicit lifecycle session: derived session unexpectedly received the receipt\n' >&2
  show_case_output
  exit 1
fi

run_case "missing-lifecycle-criteria" "small" "CLEAN" "" \
  "lifecycle" "missing-criteria"
assert_failure "missing lifecycle criteria"
assert_eq "0" "$(call_count pass)" "missing lifecycle criteria starts no waves"
assert_no_assessor "missing lifecycle criteria"
assert_no_receipt "missing lifecycle criteria"

run_case "missing-lifecycle-criteria-seal" "small" "CLEAN" "" \
  "lifecycle" "missing-seal"
assert_failure "missing lifecycle criteria seal"
assert_eq "0" "$(call_count pass)" "missing lifecycle criteria seal starts no waves"
assert_no_assessor "missing lifecycle criteria seal"
assert_no_receipt "missing lifecycle criteria seal"

run_case "parent-criteria-tamper" "small" "CLEAN" "" \
  "lifecycle" "" "" "parent-criteria-tamper"
assert_failure "parent criteria tamper"
assert_eq "1" "$(call_count pass)" "parent criteria tamper pass count"
assert_no_receipt "parent criteria tamper"

run_case "pass-criteria-tamper" "small" "CLEAN" "" \
  "lifecycle" "" "" "pass-criteria-tamper"
assert_failure "pass criteria tamper"
assert_eq "1" "$(call_count pass)" "pass criteria tamper pass count"
assert_no_receipt "pass criteria tamper"

run_case "omitted-criteria-coverage" "small" "CLEAN" "" \
  "lifecycle" "" "" "omit-criteria-coverage"
assert_failure "omitted criteria coverage"
assert_eq "1" "$(call_count pass)" "omitted criteria coverage pass count"
assert_no_receipt "omitted criteria coverage"

run_case "standalone-invented-criteria" "small" "CLEAN" "" \
  "standalone" "" "" "pass-criteria-tamper"
assert_failure "standalone invented criteria"
assert_eq "1" "$(call_count pass)" "standalone invented criteria pass count"
assert_no_receipt "standalone invented criteria"

run_case "phase-2-rejected" "small" "CLEAN" "" \
  "lifecycle" "phase-2"
assert_failure "phase 2 lifecycle rejected"
assert_eq "0" "$(call_count pass)" "phase 2 lifecycle starts no waves"
assert_no_receipt "phase 2 lifecycle rejected"

run_case "stale-lifecycle-env" "small" $'CLEAN\nCLEAN\nCLEAN' "" \
  "stale-env"
assert_success "stale lifecycle environment uses standalone isolation"
assert_eq "3" "$(call_count pass)" "stale lifecycle environment pass count"
assert_receipt "small" "3" "stale lifecycle environment"

run_case "invalid-assessor" "" "CLEAN" "invalid"
assert_failure "invalid standalone assessor"
assert_eq "2" "$(call_count assessor)" "invalid assessor retry count"
assert_eq "0" "$(call_count pass)" "invalid assessor starts no waves"
assert_no_receipt "invalid assessor"
assert_standalone_telemetry "blocked" "0" "invalid assessor"

run_case "mutating-assessor" "" "CLEAN" "mutate"
assert_failure "mutating standalone assessor"
assert_eq "1" "$(call_count assessor)" "mutating assessor call count"
assert_eq "0" "$(call_count pass)" "mutating assessor starts no waves"
assert_no_receipt "mutating assessor"

run_case "mutating-lifecycle-assessor-retry" "" "BLOCKED:verification-unavailable" \
  "mutate-once" "lifecycle" "" "" "" "twice"
assert_failure "mutating lifecycle assessor retry"
assert_eq "2" "$(call_count assessor)" "mutating lifecycle assessor retry count"
assert_eq "1" "$(call_count pass)" "mutating lifecycle assessor retry pass count"
assert_eq "1" "$(awk -F '\t' '$1 == "invocation" && $2 == "first" && $3 != "0" { count++ } END { print count + 0 }' "$CASE_CALLS")" \
  "mutating lifecycle assessor first invocation failed"
assert_no_receipt "mutating lifecycle assessor retry"

run_case "corrupt-resume-state" "" "BLOCKED:state-rejected" "" \
  "lifecycle" "corrupt-state"
assert_failure "corrupt resumable state"
assert_eq "1" "$(call_count pass)" "corrupt resumable state requires a wave"
assert_no_assessor "corrupt resumable state"
assert_no_receipt "corrupt resumable state"

run_case "resume-explicit-tier" "small" $'CLEAN\nCLEAN' "" \
  "lifecycle" "resume-state"
assert_success "matching state with explicit tier"
assert_eq "2" "$(call_count pass)" "matching state with explicit tier pass count"
assert_no_assessor "matching state with explicit tier"
assert_receipt "small" "3" "matching state with explicit tier"

run_case "resume-explicit-profile" "" $'CLEAN\nCLEAN' "" \
  "lifecycle" "resume-state" "light"
assert_success "matching state with explicit profile"
assert_eq "2" "$(call_count pass)" "matching state with explicit profile pass count"
assert_no_assessor "matching state with explicit profile"
assert_receipt "small" "3" "matching state with explicit profile"

run_case "resume-changed-criteria" "small" $'CLEAN\nCLEAN\nCLEAN' "" \
  "lifecycle" "resume-criteria-change"
assert_success "changed criteria reset resumable credit"
assert_eq "3" "$(call_count pass)" "changed criteria fresh pass count"
assert_no_assessor "changed criteria explicit tier"
assert_receipt "small" "3" "changed criteria reset resumable credit"

run_case "resume-pass-timeout" "small" "" "" \
  "lifecycle" "resume-state" "" "timeout" "single" "derived" "1"
assert_failure "resumable review pass timeout"
assert_eq "1" "$(call_count pass-start)" "resumable review pass timeout launch count"
assert_no_receipt "resumable review pass timeout"
assert_retained_credit "1" "resumable review pass timeout"

run_case "resume-after-pass-timeout" "small" $'CLEAN\nCLEAN' "" \
  "lifecycle" "resume-state" "" "timeout-once" "twice" "derived" "1"
assert_success "resume after review pass timeout"
assert_eq "1" "$(call_count pass-start)" "resume after timeout launch count"
assert_eq "2" "$(call_count pass)" "resume after timeout clean pass count"
if ! grep -q $'^invocation\tfirst\t124$' "$CASE_CALLS"; then
  printf 'resume after review pass timeout: first invocation did not time out\n' >&2
  show_case_output
  exit 1
fi
assert_receipt "small" "3" "resume after review pass timeout"

run_case "mutating-clean" "small" "CLEAN_MUTATED"
assert_failure "mutating clean"
assert_eq "1" "$(call_count pass)" "mutating clean pass count"
assert_no_receipt "mutating clean"

run_case "false-fix" "small" "FINDINGS_FIXED_NO_CHANGE:1"
assert_failure "false fix"
assert_eq "1" "$(call_count pass)" "false fix pass count"
assert_no_receipt "false fix"

run_case "committed-fix" "small" $'FINDINGS_FIXED_COMMIT:1\nCLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "committed-change"
assert_success "committed fix"
assert_eq "4" "$(call_count pass)" "committed fix pass count"
assert_receipt "small" "3" "committed fix"

run_case "committed-fix-changed-boundary" "small" "FINDINGS_FIXED_COMMIT_BOUNDARY:1" "" \
  "standalone" "committed-change"
assert_failure "committed fix with changed boundary"
assert_eq "1" "$(call_count pass)" "committed fix with changed boundary pass count"
assert_no_receipt "committed fix with changed boundary"

run_case "empty-commit-fix" "small" "FINDINGS_FIXED_EMPTY_COMMIT:1"
assert_failure "empty commit fix"
assert_eq "1" "$(call_count pass)" "empty commit fix pass count"
assert_no_receipt "empty commit fix"

run_case "branch-switch-fix" "small" "FINDINGS_FIXED_SWITCH_BRANCH:1"
assert_failure "branch switch fix"
assert_eq "1" "$(call_count pass)" "branch switch fix pass count"
assert_no_receipt "branch switch fix"

run_case "repeated-findings" "small" $'FINDINGS_FIXED_SAME:1\nFINDINGS_FIXED_SAME:1\nFINDINGS_FIXED_SAME:1\nCLEAN\nCLEAN\nCLEAN'
assert_failure "repeated findings churn"
assert_eq "3" "$(call_count pass)" "repeated findings churn pass count"
assert_no_receipt "repeated findings churn"

run_case "normal-gate" "normal" $'CLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN'
assert_success "normal gate"
assert_eq "6" "$(call_count pass)" "normal gate pass count"
assert_no_assessor "normal gate explicit tier"
assert_receipt "normal" "6" "normal gate"

run_case "complex-gate" "complex" $'CLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN'
assert_success "complex gate"
assert_eq "9" "$(call_count pass)" "complex gate pass count"
assert_no_assessor "complex gate explicit tier"
assert_receipt "complex" "9" "complex gate"

run_case "fix-reset" "small" $'CLEAN\nCLEAN\nFINDINGS_FIXED:1\nCLEAN\nCLEAN\nCLEAN'
assert_success "fix reset"
assert_eq "6" "$(call_count pass)" "fix reset pass count"
assert_no_assessor "fix reset explicit tier"
assert_receipt "small" "3" "fix reset"
assert_standalone_telemetry "completed" "6" "fix reset telemetry"

run_case "scope-refresh-codebase" "small" $'FINDINGS_FIXED_CLEAR_SCOPE:1\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "" "" "expect-codebase"
assert_success "scope refresh from changes to codebase"
assert_eq "10" "$(call_count pass)" "scope refresh to codebase pass count"
assert_eq "9" "$(call_count scope-refresh-codebase)" "scope refresh to codebase prompt count"
assert_receipt "complex" "9" "scope refresh from changes to codebase"

run_case "scope-refresh-changes" "complex" $'FINDINGS_FIXED_ADD_UNTRACKED:1\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "clean-codebase" "" "expect-changes"
assert_success "scope refresh from codebase to changes"
assert_eq "10" "$(call_count pass)" "scope refresh to changes pass count"
assert_eq "9" "$(call_count scope-refresh-changes)" "scope refresh to changes prompt count"
assert_receipt "complex" "9" "scope refresh from codebase to changes"

run_case "findings-stop" "small" "FINDINGS:1"
assert_failure "findings stop"
assert_eq "1" "$(call_count pass)" "findings stop pass count"
assert_no_assessor "findings stop explicit tier"
assert_no_receipt "findings stop"

run_case "blocked-stop" "small" "BLOCKED:missing-tool"
assert_failure "blocked stop"
assert_eq "1" "$(call_count pass)" "blocked stop pass count"
assert_no_assessor "blocked stop explicit tier"
assert_no_receipt "blocked stop"
assert_standalone_telemetry "blocked" "1" "blocked stop telemetry"

run_case "pass-timeout" "small" "" "" \
  "lifecycle" "" "" "timeout" "single" "derived" "1"
assert_failure "review pass timeout"
assert_eq "1" "$(call_count pass-start)" "review pass timeout launch count"
if ! grep -q 'pass_timeout' "$CASE_OUTPUT"; then
  printf 'review pass timeout: normalized pass_timeout reason missing\n' >&2
  show_case_output
  exit 1
fi
if ! grep -R -q '"reason":"pass_timeout"' "$CASE_DIR/runs" 2>/dev/null; then
  printf 'review pass timeout: telemetry reason missing\n' >&2
  show_case_output
  exit 1
fi
if [[ "$CASE_ELAPSED_SECONDS" -gt 8 ]]; then
  printf 'review pass timeout: expected bounded runtime, took %ss\n' "$CASE_ELAPSED_SECONDS" >&2
  show_case_output
  exit 1
fi
if [[ -e "$CASE_LOOP_DIR/${CASE_SESSION_ID}.phase-3.busy" ]]; then
  printf 'review pass timeout: Phase 3 busy marker was not cleaned up\n' >&2
  show_case_output
  exit 1
fi
assert_no_receipt "review pass timeout"
if ! python3 - "$CASE_DIR/runs" <<'PY'
import json
import sys
from pathlib import Path

events = []
for event_file in Path(sys.argv[1]).glob("run_*/events.jsonl"):
    events.extend(
        json.loads(line)
        for line in event_file.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
finished = [event for event in events if event["type"] == "review.pass.finished"]
assert len(finished) == 1, finished
data = finished[0]["data"]
assert data["result_kind"] == "pass_timeout", data
assert data["terminal_reason"] == "pass_timeout", data
assert data["evidence_valid"] is False, data
assert data["evidence_hash"] == "none", data
assert data["deterministic_checks"] == "not-recorded", data
assert data["verifier"] == "not-recorded", data
assert data["coverage"] == "none", data
assert data["pass_id"], data
PY
then
  printf 'review pass timeout: telemetry schema invalid\n' >&2
  show_case_output
  exit 1
fi

run_case "churn-stop" "small" "CHURN:repeated-fingerprint"
assert_failure "churn stop"
assert_eq "1" "$(call_count pass)" "churn stop pass count"
assert_no_assessor "churn stop explicit tier"
assert_no_receipt "churn stop"

run_case "no-outer-max" "small" $'FINDINGS_FIXED:1\nFINDINGS_FIXED:1\nFINDINGS_FIXED:1\nFINDINGS_FIXED:1\nFINDINGS_FIXED:1\nCLEAN\nCLEAN\nCLEAN'
assert_success "no default max"
assert_eq "8" "$(call_count pass)" "no default max pass count"
assert_no_assessor "no default max explicit tier"
assert_receipt "small" "3" "no default max"

run_case "upward-escalation" "small" $'CLEAN\nCLEAN\nESCALATE:normal:cross-module\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN'
assert_success "upward escalation"
assert_eq "9" "$(call_count pass)" "upward escalation pass count"
assert_no_assessor "upward escalation explicit tier"
assert_receipt "normal" "6" "upward escalation"
assert_standalone_telemetry "completed" "9" "upward escalation telemetry"

run_case "escalation-raises-override" "small" $'ESCALATE:normal:cross-module\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "" "" "" "single" "derived" "" "3"
assert_success "escalation raises explicit gate to tier floor"
assert_eq "7" "$(call_count pass)" "escalation raised gate pass count"
assert_no_assessor "escalation raised gate explicit tier"
assert_receipt "normal" "6" "escalation raised gate"

run_concurrent_case

printf 'review-loop-test passed\n'
