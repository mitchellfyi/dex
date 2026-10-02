#!/usr/bin/env bash
# Rubric for: pnpm-shared-tyrefactor
# Checks shared type migration, consumers, fixtures, and no unsafe casts.

_run_checks() {
  local ws="$1"
  (cd "$ws" && npm test >/tmp/dx-tyrefactor-test.log 2>&1 && npm run typecheck >/tmp/dx-tyrefactor-typecheck.log 2>&1)
}

rubric_correctness() {
  local ws="$1"
  local score=0
  local user_file="$ws/packages/types/src/user.ts"

  [[ -f "$user_file" ]] || { echo 0; return; }

  grep -q "firstName" "$user_file" && score=$((score + 15))
  grep -q "lastName" "$user_file" && score=$((score + 15))
  grep -q "displayName" "$user_file" && score=$((score + 15))

  if ! grep -R "fullName" "$ws/packages" >/dev/null 2>&1; then
    score=$((score + 25))
  fi

  if grep -R "displayName" "$ws/packages/frontend/src" "$ws/packages/backend/src" >/dev/null 2>&1; then
    score=$((score + 15))
  fi

  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  if _run_checks "$ws"; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  local changed_tests
  changed_tests=$(cd "$ws" && git diff --name-only HEAD -- packages 2>/dev/null | grep -cE '/tests?/|\\.test\\.ts$' || true)
  changed_tests=${changed_tests//[[:space:]]/}
  [[ -z "$changed_tests" ]] && changed_tests=0
  if [[ "$changed_tests" -ge 2 ]]; then
    score=$((score + 35))
  elif [[ "$changed_tests" -eq 1 ]]; then
    score=$((score + 20))
  fi

  grep -R "firstName\\|lastName\\|displayName" "$ws/packages/frontend/tests" "$ws/packages/backend/tests" >/dev/null 2>&1 && score=$((score + 30))
  if ! grep -R "fullName" "$ws/packages/frontend/tests" "$ws/packages/backend/tests" >/dev/null 2>&1; then
    score=$((score + 20))
  fi

  if _run_checks "$ws"; then
    score=$((score + 15))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=20

  if ! grep -R "as any\\|@ts-ignore\\|: any\\b" "$ws/packages" >/dev/null 2>&1; then
    score=$((score + 35))
  fi

  if grep -R "from ['\"].*types" "$ws/packages/frontend/src" "$ws/packages/backend/src" >/dev/null 2>&1; then
    score=$((score + 20))
  fi

  local package_changes
  package_changes=$(cd "$ws" && git diff --name-only HEAD -- package.json pnpm-workspace.yaml scripts 2>/dev/null | wc -l | tr -d ' ')
  [[ "$package_changes" -eq 0 ]] && score=$((score + 15))

  local helper_defs
  helper_defs=$(grep -R "function displayName\\|const displayName" "$ws/packages" --include='*.ts' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$helper_defs" -eq 1 ]] && score=$((score + 10))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_issue_detection() {
  local ws="$1"
  local score=30

  local touched=0
  for dir in packages/types packages/frontend packages/backend; do
    if (cd "$ws" && git diff --name-only HEAD -- "$dir" 2>/dev/null | grep -q .); then
      touched=$((touched + 1))
    fi
  done
  score=$((score + touched * 20))

  if ! grep -R "fullName" "$ws/packages" >/dev/null 2>&1; then
    score=$((score + 10))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}
