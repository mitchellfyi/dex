#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-loop-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    show_case_output
    exit 1
  fi
}

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
  local version tier required clean_count fingerprint ledger_hash extra

  if [[ ! -f "$receipt" ]]; then
    printf '%s: missing review receipt at %s\n' "$label" "$receipt" >&2
    show_case_output
    exit 1
  fi

  IFS=$'\t' read -r version tier required clean_count fingerprint ledger_hash extra < "$receipt"
  assert_eq "2" "$version" "$label receipt version"
  assert_eq "$expected_tier" "$tier" "$label receipt tier"
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

  if ! DEX_DIR="$ROOT" \
    HOME="$CASE_HOME" \
    DX_STATE_DIR="$CASE_STATE_DIR" \
    DX_LOOP_DIR="$CASE_LOOP_DIR" \
    DX_ARTIFACT_DIR="$CASE_DIR/artifacts" \
    DX_TOOL_DIR="$CASE_DIR/tools" \
    DX_RUN_ROOT="$CASE_DIR/runs" \
      bash -c 'source "$DEX_DIR/lib/common.sh"; dx_review_receipt_valid "$1" "$2"' \
        _ "$CASE_SESSION_ID" "$CASE_REPO"; then
    printf '%s: receipt helper rejected the successful review\n' "$label" >&2
    show_case_output
    exit 1
  fi
}

assert_standalone_telemetry() { # <status> <pass-count> <label>
  local expected_status="$1" expected_passes="$2" label="$3"
  if ! python3 - "$CASE_DIR/runs" "$expected_status" "$expected_passes" <<'PY'
import json
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
  local unique_sessions unique_contexts contaminated missing_context_path

  unique_sessions=$(awk -F '\t' '$1 == "pass" { print $2 }' "$CASE_CALLS" | sort -u | wc -l | tr -d ' ')
  unique_contexts=$(awk -F '\t' '$1 == "pass" { print $3 }' "$CASE_CALLS" | sort -u | wc -l | tr -d ' ')
  contaminated=$(awk -F '\t' '$1 == "pass" && $4 != "0" { count++ } END { print count + 0 }' "$CASE_CALLS")
  missing_context_path=$(awk -F '\t' '$1 == "pass" && $5 != "1" { count++ } END { print count + 0 }' "$CASE_CALLS")

  assert_eq "$expected" "$unique_sessions" "$label unique pass sessions"
  assert_eq "$expected" "$unique_contexts" "$label unique context paths"
  assert_eq "0" "$contaminated" "$label context contamination"
  assert_eq "0" "$missing_context_path" "$label supplied context paths"

  if awk -F '\t' -v parent="$CASE_SESSION_ID" '
    $1 == "pass" && $2 == parent { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$CASE_CALLS"; then
    printf '%s: pass session reused the parent session id\n' "$label" >&2
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
  printf 'base\n' > "$CASE_REPO/app.txt"
  git -C "$CASE_REPO" add app.txt
  git -C "$CASE_REPO" commit -qm "test: initialize review fixture"
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
      cd "$CASE_REPO"

      unset DEX_LOOP_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE DEX_LOOP_PROMISE \
        DEX_SESSION_ID \
        DEX_REVIEW_ASSESSMENT_ACTIVE DEX_REVIEW_PROFILE DEX_REVIEW_CLEAN_PASSES \
        DEX_REVIEW_PASS_TIMEOUT DEX_RUN_ID DX_REVIEW_PROFILE \
        DX_REVIEW_SMALL_CLEAN_PASSES DX_REVIEW_NORMAL_CLEAN_PASSES \
        DX_REVIEW_COMPLEX_CLEAN_PASSES DX_REVIEW_LIGHT_CLEAN_PASSES \
        DX_REVIEW_STANDARD_CLEAN_PASSES DX_REVIEW_THOROUGH_CLEAN_PASSES

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
      dx_agent_host() { print -r -- claude; }
      dx_agent_host_label() { print -r -- Claude; }
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
      fi

      __dx_claude() {
        local invocation_args="$*"
        if [[ "${DEX_REVIEW_ASSESSMENT_ACTIVE:-}" == "1" ]]; then
          local assessment_index
          assessment_index=$(awk -F "\t" '\''$1 == "assessor" { count++ } END { print count + 1 }'\'' "$CASE_CALLS")
          printf "assessor\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
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

        local pass_index result context_path evidence_path sentinel contamination=0 context_supplied=0 hash apply_fix=0
        local evidence_checks=pass evidence_verifier=pass evidence_findings=0 evidence_fixes=0 coverage
        if [[ "$CASE_PASS_MODE" == "timeout" ]]; then
          printf "pass-start\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
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

        context_path=$(dx_review_context_file "$DEX_SESSION_ID")
        [[ "$invocation_args" == *"$context_path"* ]] && context_supplied=1
        while IFS= read -r sentinel; do
          [[ -n "$sentinel" && "$invocation_args" == *"$sentinel"* ]] && contamination=1
        done < "$CASE_SENTINELS"

        sentinel="private-context-${pass_index}"
        {
          printf "## Scope\n\n%s for the complete supplied change set and pass %s.\n\n" "$sentinel" "$pass_index"
          printf "## Deterministic Checks\n\nAll applicable fixture checks passed.\n\n"
          printf "## Review Coverage\n\nCore review domains were independently inspected.\n\n"
          printf "## Verification\n\nThe fixture verifier rechecked the final result and evidence.\n"
        } >| "$context_path"
        printf "%s\n%s\n" "$sentinel" "$context_path" >> "$CASE_SENTINELS"
        case "$result" in
          CLEAN_MUTATED)
            printf "invalid-clean-mutation\n" >> "$CASE_REPO/app.txt"
            result="CLEAN"
            ;;
          FINDINGS_FIXED_NO_CHANGE:*)
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
        evidence_path=$(dx_review_evidence_file "$DEX_SESSION_ID")
        printf "{\"version\":1,\"scope_fingerprint\":\"%s\",\"deterministic_checks\":\"%s\",\"coverage\":%s,\"verifier\":\"%s\",\"verified_findings\":%s,\"fixes_applied\":%s}\n" \
          "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" "$evidence_checks" "$coverage" "$evidence_verifier" "$evidence_findings" "$evidence_fixes" >| "$evidence_path"

        printf "%s\n" "$result" >| "$(dx_review_result_file "$DEX_SESSION_ID")"
        touch "$(dx_complete_file "$DEX_SESSION_ID")"
        printf "pass\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$DEX_SESSION_ID" "$context_path" "$contamination" "$context_supplied" \
          "${DEX_REVIEW_TIER:-}" "${DEX_REVIEW_PROFILE:-}" "$result" >> "$CASE_CALLS"
        return 0
      }

      case "$CASE_SETUP_MODE" in
        corrupt-state)
          fingerprint=$(dx_review_scope_fingerprint "$CASE_REPO")
          dx_review_write_selection "$CASE_SESSION_ID" small environment operator-override "$CASE_REPO"
          printf "1\tsmall\t3\t0\t3\t%s\n" "$fingerprint" >| "$(dx_review_state_file "$CASE_SESSION_ID")"
          ;;
        resume-state)
          dx_review_write_selection "$CASE_SESSION_ID" small environment operator-override "$CASE_REPO"
          fingerprint=$(dx_review_scope_fingerprint "$CASE_REPO")
          dx_review_ledger_append "$CASE_SESSION_ID" 1 prior-clean-pass "$fingerprint" 0123456789abcdef
          dx_review_write_state "$CASE_SESSION_ID" small 3 1 1 "$CASE_REPO"
          ;;
      esac

      if [[ "$CASE_INVOCATION_MODE" == "twice" ]]; then
        dxreviewloop
        first_status=$?
        printf "invocation\tfirst\t%s\n" "$first_status" >> "$CASE_CALLS"
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
        dx_agent_host() { print -r -- claude; }
        dx_agent_host_label() { print -r -- Claude; }
        dx_session_id() { print -r -- "$CASE_SESSION_ID"; }
        dx_provider_write_session_state() { return 0; }
        dx_provider_cleanup_session_state() { return 0; }
        __dx_provider_prompt() { return 0; }
        claude() { return 0; }

        printf "3\n" >| "$(dx_state_file "$CASE_SESSION_ID")"

        __dx_claude() {
          if [[ "$CASE_ROLE" == "contender" ]]; then
            printf "contender-pass\t%s\n" "${DEX_SESSION_ID:-missing}" >> "$CASE_CALLS"
            return 97
          fi

          local pass_index context_path evidence_path
          pass_index=$(awk -F "\t" '\''$1 == "owner-pass" { count++ } END { print count + 1 }'\'' "$CASE_CALLS")
          if [[ "$pass_index" -eq 1 ]]; then
            touch "$CASE_OWNER_READY"
            for _ in {1..200}; do
              [[ -f "$CASE_OWNER_RELEASE" ]] && break
              sleep 0.05
            done
            [[ -f "$CASE_OWNER_RELEASE" ]] || return 96
          fi

          context_path=$(dx_review_context_file "$DEX_SESSION_ID")
          {
            printf "## Scope\n\nConcurrent fixture pass %s reviewed the supplied scope.\n\n" "$pass_index"
            printf "## Deterministic Checks\n\nAll applicable fixture checks passed.\n\n"
            printf "## Review Coverage\n\nCorrectness, security, contracts, tests, and architecture.\n\n"
            printf "## Verification\n\nThe independent fixture verifier passed.\n"
          } >| "$context_path"
          evidence_path=$(dx_review_evidence_file "$DEX_SESSION_ID")
          printf "{\"version\":1,\"scope_fingerprint\":\"%s\",\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}\n" \
            "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" >| "$evidence_path"
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

run_case "mutating-clean" "small" "CLEAN_MUTATED"
assert_failure "mutating clean"
assert_eq "1" "$(call_count pass)" "mutating clean pass count"
assert_no_receipt "mutating clean"

run_case "false-fix" "small" "FINDINGS_FIXED_NO_CHANGE:1"
assert_failure "false fix"
assert_eq "1" "$(call_count pass)" "false fix pass count"
assert_no_receipt "false fix"

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

run_case "escalation-raises-override" "small" $'ESCALATE:normal:cross-module\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN\nCLEAN' "" \
  "standalone" "" "" "" "single" "derived" "" "3"
assert_success "escalation raises explicit gate to tier floor"
assert_eq "7" "$(call_count pass)" "escalation raised gate pass count"
assert_no_assessor "escalation raised gate explicit tier"
assert_receipt "normal" "6" "escalation raised gate"

run_concurrent_case

printf 'review-loop-test passed\n'
