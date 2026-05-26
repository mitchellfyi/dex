#!/usr/bin/env bash
# Research harness — scoring engine
# Loads per-scenario rubrics, runs deterministic checks, computes weighted totals.

# shellcheck source=research/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# score_scenario <scenario_name> <result_dir> [--skip-llm-judge]
# Run all rubric checks and write results to result_dir.
# Returns the total weighted score (0-100).
score_scenario() {
  local scenario="$1"
  local result_dir="$2"
  local skip_llm="${3:-}"

  local ws
  ws=$(workspace_dir "$scenario")
  local sc_dir
  sc_dir=$(scenario_dir "$scenario")
  local rubric_file="$sc_dir/rubric.sh"

  if [[ ! -f "$rubric_file" ]]; then
    log_error "No rubric.sh found for scenario: $scenario"
    echo "0"
    return 1
  fi

  # Unset any rubric_* functions from prior scenarios to prevent pollution
  local _fn
  for _fn in $(declare -F | awk '/rubric_/{print $3}'); do
    unset -f "$_fn"
  done

  # Source the scenario's rubric (defines rubric_* functions)
  # shellcheck source=/dev/null
  source "$rubric_file"

  log_step "Scoring scenario: $scenario"

  # ── Resolve weights (per-scenario overrides fall back to globals) ────────
  local w_corr=$W_CORRECTNESS w_test=$W_TEST_QUALITY w_rob=$W_ROBUSTNESS
  local w_ver=$W_VERIFICATION w_iss=$W_ISSUE_DETECTION w_code=$W_CODE_QUALITY
  if [[ -f "$sc_dir/scenario.json" ]]; then
    local override
    override=$(W_CORR="$W_CORRECTNESS" W_TEST="$W_TEST_QUALITY" W_ROB="$W_ROBUSTNESS" \
               W_VER="$W_VERIFICATION" W_ISS="$W_ISSUE_DETECTION" W_CODE="$W_CODE_QUALITY" \
               SC="$sc_dir/scenario.json" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["SC"]))
    w = d.get("weights")
    if isinstance(w, dict):
        out = [
            int(w.get("correctness", os.environ["W_CORR"])),
            int(w.get("test_quality", os.environ["W_TEST"])),
            int(w.get("robustness", os.environ["W_ROB"])),
            int(w.get("verification", os.environ["W_VER"])),
            int(w.get("issue_detection", os.environ["W_ISS"])),
            int(w.get("code_quality", os.environ["W_CODE"])),
        ]
        if sum(out) == 100:
            print(" ".join(str(x) for x in out))
except Exception:
    pass
' 2>/dev/null)
    if [[ -n "$override" ]]; then
      read -r w_corr w_test w_rob w_ver w_iss w_code <<< "$override"
      log_info "  Per-scenario weights: $w_corr/$w_test/$w_rob/$w_ver/$w_iss/$w_code"
    fi
  fi

  # ── Run each dimension ───────────────────────────────────────────────────
  local correctness=0 test_quality=0 robustness=0 verification=0 issue_detection=0 code_quality=0

  # Correctness (scenario-specific)
  if declare -f rubric_correctness &>/dev/null; then
    correctness=$(rubric_correctness "$ws" 2>/dev/null || echo "0")
    correctness=$(_clamp "$correctness")
    log_info "  Correctness: $correctness/100"
  fi

  # Test quality (scenario-specific)
  if declare -f rubric_test_quality &>/dev/null; then
    test_quality=$(rubric_test_quality "$ws" 2>/dev/null || echo "0")
    test_quality=$(_clamp "$test_quality")
    log_info "  Test quality: $test_quality/100"
  fi

  # Robustness (scenario-specific)
  if declare -f rubric_robustness &>/dev/null; then
    robustness=$(rubric_robustness "$ws" 2>/dev/null || echo "0")
    robustness=$(_clamp "$robustness")
    log_info "  Robustness: $robustness/100"
  fi

  # Verification (shared — check if lint/typecheck/tests pass)
  verification=$(_score_verification "$ws" 2>/dev/null || echo "0")
  verification=$(_clamp "$verification")
  log_info "  Verification: $verification/100"

  # Issue detection (scenario-specific or default)
  if declare -f rubric_issue_detection &>/dev/null; then
    issue_detection=$(rubric_issue_detection "$ws" "$result_dir" 2>/dev/null || echo "0")
  else
    issue_detection=$(_score_issue_detection_default "$ws" "$result_dir" 2>/dev/null || echo "0")
  fi
  issue_detection=$(_clamp "$issue_detection")
  log_info "  Issue detection: $issue_detection/100"

  # Code quality (LLM-judged)
  if [[ "$skip_llm" != "--skip-llm-judge" ]] && [[ -f "$sc_dir/rubric-llm.md" ]]; then
    code_quality=$(_score_llm_judge "$scenario" "$ws" "$result_dir" 2>/dev/null || echo "50")
    code_quality=$(_clamp "$code_quality")
    log_info "  Code quality (LLM): $code_quality/100"
  else
    code_quality=50  # Neutral default when skipping
    log_info "  Code quality (LLM): skipped, using default 50"
  fi

  # ── Compute weighted total ───────────────────────────────────────────────
  local total
  total=$(( (correctness * w_corr + test_quality * w_test + robustness * w_rob + verification * w_ver + issue_detection * w_iss + code_quality * w_code) / 100 ))

  log_success "  Total: $total/100"

  # ── Write results ────────────────────────────────────────────────────────
  json_write "$result_dir/rubric-results.json" "{
    \"scenario\": \"$scenario\",
    \"correctness\": $correctness,
    \"test_quality\": $test_quality,
    \"robustness\": $robustness,
    \"verification\": $verification,
    \"issue_detection\": $issue_detection,
    \"code_quality\": $code_quality,
    \"total\": $total,
    \"weights\": {
      \"correctness\": $w_corr,
      \"test_quality\": $w_test,
      \"robustness\": $w_rob,
      \"verification\": $w_ver,
      \"issue_detection\": $w_iss,
      \"code_quality\": $w_code
    }
  }"

  echo "$total"
}

# ── Shared scoring functions ───────────────────────────────────────────────

# Detect project type and run appropriate verification checks
_score_verification() {
  local ws="$1"
  local score=0

  # Detect project type and capture verification score
  if [[ -f "$ws/package.json" ]]; then
    score=$(_verify_node "$ws")
  elif [[ -f "$ws/requirements.txt" ]] || [[ -f "$ws/setup.py" ]] || [[ -f "$ws/pyproject.toml" ]] || find "$ws" -maxdepth 2 -name "__init__.py" 2>/dev/null | grep -q .; then
    score=$(_verify_python "$ws")
  elif [[ -f "$ws/go.mod" ]]; then
    score=$(_verify_go "$ws")
  else
    # No recognizable project — check if any code files exist at all
    local code_files
    code_files=$(find "$ws" -maxdepth 3 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" \) ! -path "*/node_modules/*" 2>/dev/null | wc -l)
    [[ $code_files -gt 0 ]] && score=50  # Partial credit for producing code
  fi

  echo "$score"
}

_verify_node() {
  local ws="$1"
  local score=0 checks=0 passed=0

  # Install deps
  if (cd "$ws" && npm install --silent &>/dev/null); then
    passed=$((passed + 1))
  fi
  checks=$((checks + 1))

  # Lint (if configured)
  if (cd "$ws" && grep -q '"lint"' package.json 2>/dev/null); then
    checks=$((checks + 1))
    if (cd "$ws" && npm run lint &>/dev/null); then
      passed=$((passed + 1))
    fi
  fi

  # Typecheck (if TypeScript)
  if [[ -f "$ws/tsconfig.json" ]]; then
    checks=$((checks + 1))
    if (cd "$ws" && npx tsc --noEmit &>/dev/null); then
      passed=$((passed + 1))
    fi
  fi

  # Tests (pass-rate aware: >95% pass rate counts as pass)
  if (cd "$ws" && grep -q '"test"' package.json 2>/dev/null); then
    checks=$((checks + 1))
    local test_output test_exit=0
    test_output=$(cd "$ws" && npm test 2>&1) || test_exit=$?
    if [[ $test_exit -eq 0 ]]; then
      passed=$((passed + 1))
    else
      # Parse Jest output for pass rate (e.g., "Tests: 1 failed, 77 passed, 78 total")
      local tests_line tests_passed=0 tests_total=0
      tests_line=$(grep -E '^Tests:' <<< "$test_output" | head -1 || true)
      tests_passed=$(grep -oE '[0-9]+ passed' <<< "$tests_line" | grep -oE '[0-9]+' || echo "0")
      tests_total=$(grep -oE '[0-9]+ total' <<< "$tests_line" | grep -oE '[0-9]+' || echo "0")
      if [[ "$tests_total" -gt 0 && "$tests_passed" -gt 0 ]]; then
        local pass_rate=$(( tests_passed * 100 / tests_total ))
        if [[ $pass_rate -ge 95 ]]; then
          passed=$((passed + 1))
        fi
      fi
    fi
  fi

  [[ $checks -gt 0 ]] && score=$(( (passed * 100) / checks ))
  echo "$score"
}

_verify_python() {
  local ws="$1"
  local score=0 checks=0 passed=0

  # Install deps
  checks=$((checks + 1))
  if [[ -f "$ws/requirements.txt" ]]; then
    if (cd "$ws" && pip install -q -r requirements.txt &>/dev/null); then
      passed=$((passed + 1))
    fi
  else
    passed=$((passed + 1))  # No deps needed
  fi

  # Run tests
  checks=$((checks + 1))
  if (cd "$ws" && python3 -m pytest &>/dev/null) || (cd "$ws" && python3 -m unittest discover &>/dev/null); then
    passed=$((passed + 1))
  fi

  [[ $checks -gt 0 ]] && score=$(( (passed * 100) / checks ))
  echo "$score"
}

_verify_go() {
  local ws="$1"
  local score=0 checks=0 passed=0

  # Build
  checks=$((checks + 1))
  if (cd "$ws" && go build ./... &>/dev/null); then
    passed=$((passed + 1))
  fi

  # Vet
  checks=$((checks + 1))
  if (cd "$ws" && go vet ./... &>/dev/null); then
    passed=$((passed + 1))
  fi

  # Test
  checks=$((checks + 1))
  if (cd "$ws" && go test ./... &>/dev/null); then
    passed=$((passed + 1))
  fi

  [[ $checks -gt 0 ]] && score=$(( (passed * 100) / checks ))
  echo "$score"
}

# Default issue detection: check if DX's output shows it found and fixed problems
_score_issue_detection_default() {
  local ws="$1" result_dir="$2"
  local score=50  # Neutral baseline

  # Check stream output for evidence of self-review and fixing
  if [[ -f "$result_dir/stream.jsonl" ]]; then
    # Look for patterns indicating DX reviewed its work
    if grep -qE '"name"\s*:\s*"Bash"' "$result_dir/stream.jsonl" 2>/dev/null; then
      # DX ran commands (likely tests/lint) — that's good
      score=$((score + 20))
    fi
    # Look for evidence of iteration (multiple edit rounds)
    local edit_count
    edit_count="$(grep -cE '"name"\s*:\s*"(Edit|Write)"' "$result_dir/stream.jsonl" 2>/dev/null)" || edit_count=0
    if [[ $edit_count -gt 3 ]]; then
      score=$((score + 15))  # Multiple edits suggest iteration/fixing
    fi
    # Check for test execution
    if grep -q 'npm test\|pytest\|go test\|jest\|mocha' "$result_dir/stream.jsonl" 2>/dev/null; then
      score=$((score + 15))
    fi
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

# LLM-as-judge scoring
_score_llm_judge() {
  local scenario="$1" ws="$2" result_dir="$3"
  local sc_dir
  sc_dir=$(scenario_dir "$scenario")
  local rubric_llm="$sc_dir/rubric-llm.md"

  # Gather the code DX produced
  local code_listing=""
  while IFS= read -r f; do
    [[ -f "$ws/$f" ]] || continue
    # Skip binary files and node_modules
    [[ "$f" == *"node_modules"* ]] && continue
    [[ "$f" == *".lock"* ]] && continue
    local content
    content=$(head -200 "$ws/$f" 2>/dev/null || true)
    code_listing+="
--- $f ---
$content
"
  done < <(workspace_files_changed "$scenario" 2>/dev/null)

  # Build the judge prompt
  local judge_prompt
  judge_prompt=$(cat "$rubric_llm")
  judge_prompt="${judge_prompt//\{\{CODE_LISTING\}\}/$code_listing}"

  # Call Claude as judge
  local judge_result
  judge_result=$(claude -p \
    --model "$LLM_JUDGE_MODEL" \
    "$CLAUDE_BYPASS_FLAG" \
    --permission-mode "$CLAUDE_PERMISSION_MODE" \
    --output-format text \
    "$judge_prompt" 2>/dev/null || echo '{"score": 50, "reasoning": "LLM judge failed"}')

  # Extract score from JSON response
  local llm_score
  llm_score=$(echo "$judge_result" | python3 -c "
import json, sys, re
text = sys.stdin.read()
# Find the outermost JSON object and parse it properly
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    try:
        parsed = json.loads(match.group(0))
        print(int(parsed.get('score', 50)))
    except (json.JSONDecodeError, ValueError, TypeError):
        print('50')
else:
    print('50')
" 2>/dev/null || echo "50")

  # Save the full judge response
  json_write "$result_dir/llm-judge.json" "{
    \"scenario\": \"$scenario\",
    \"model\": \"$LLM_JUDGE_MODEL\",
    \"score\": $llm_score,
    \"response\": $(_JR="$judge_result" python3 -c "import json,os; print(json.dumps(os.environ.get('_JR','')[:2000]))" 2>/dev/null || echo '""')
  }"

  echo "$llm_score"
}

# ── Utilities ──────────────────────────────────────────────────────────────

# Clamp a score to 0-100
_clamp() {
  local v="${1:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  [[ $v -gt 100 ]] && v=100
  [[ $v -lt 0 ]] && v=0
  echo "$v"
}
