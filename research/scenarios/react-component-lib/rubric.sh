#!/usr/bin/env bash
# Rubric for: react-component-lib
# Hardened rubric — target score ~50-65 for typical implementations.
# React component library with form components, accessibility, and tests.

rubric_correctness() {
  local ws="$1"
  local score=0

  # ── package.json exists (5 pts) ──────────────────────────────────────
  [[ -f "$ws/package.json" ]] && score=$((score + 5))

  # ── npm install works (5 pts) ────────────────────────────────────────
  if (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    score=$((score + 5))
  else
    # Can't proceed without install
    echo "$score"; return
  fi

  # ── Has React/ReactDOM dependencies (3 pts) ─────────────────────────
  local pkg_content
  pkg_content=$(cat "$ws/package.json" 2>/dev/null) || true
  if grep -q '"react"' <<< "$pkg_content" 2>/dev/null; then
    score=$((score + 2))
  fi
  if grep -q '"react-dom"' <<< "$pkg_content" 2>/dev/null; then
    score=$((score + 1))
  fi

  # ── Has testing library dependency (3 pts) ───────────────────────────
  if grep -q '@testing-library/react' <<< "$pkg_content" 2>/dev/null; then
    score=$((score + 3))
  fi

  # ── Component files exist (4 pts each = 20 pts) ─────────────────────
  local all_src
  all_src=$(find "$ws/src" "$ws/components" "$ws/lib" "$ws" -maxdepth 4 \
    \( -name "*.tsx" -o -name "*.jsx" -o -name "*.ts" -o -name "*.js" \) \
    ! -path "*/node_modules/*" ! -path "*/__tests__/*" ! -path "*/*.test.*" \
    ! -path "*/*.spec.*" 2>/dev/null) || true

  for comp in "TextInput" "Select" "Checkbox" "Form" "FormField"; do
    local found
    found=$(echo "$all_src" | grep -i "$comp" 2>/dev/null) || true
    if [[ -n "$found" ]]; then
      score=$((score + 4))
    else
      # Check if component is defined inside another file
      local inline_found
      inline_found=$(find "$ws" -maxdepth 5 \( -name "*.tsx" -o -name "*.jsx" -o -name "*.ts" -o -name "*.js" \) \
        ! -path "*/node_modules/*" -exec grep -l "export.*${comp}\|function ${comp}\|const ${comp}" {} + 2>/dev/null) || true
      [[ -n "$inline_found" ]] && score=$((score + 4))
    fi
  done

  # ── Index file exports all components (5 pts) ────────────────────────
  local index_file=""
  for f in "src/index.tsx" "src/index.ts" "src/index.jsx" "src/index.js" \
           "index.tsx" "index.ts" "index.jsx" "index.js" \
           "components/index.tsx" "components/index.ts" "components/index.jsx" "components/index.js"; do
    [[ -f "$ws/$f" ]] && index_file="$ws/$f" && break
  done

  if [[ -n "$index_file" ]]; then
    local export_count=0
    for comp in "TextInput" "Select" "Checkbox" "Form" "FormField"; do
      if grep -q "$comp" "$index_file" 2>/dev/null; then
        export_count=$((export_count + 1))
      fi
    done
    [[ $export_count -ge 5 ]] && score=$((score + 5))
    [[ $export_count -ge 3 && $export_count -lt 5 ]] && score=$((score + 3))
  fi

  # ── Gather all source files for grepping ─────────────────────────────
  local src_content
  src_content=$(find "$ws" -maxdepth 5 \( -name "*.tsx" -o -name "*.jsx" -o -name "*.ts" -o -name "*.js" \) \
    ! -path "*/node_modules/*" ! -path "*/*.test.*" ! -path "*/*.spec.*" \
    ! -path "*/__tests__/*" -exec cat {} + 2>/dev/null) || true

  # ── TextInput has value/onChange props (5 pts) ───────────────────────
  local has_value has_onchange
  has_value=$(echo "$src_content" | grep -c "value" 2>/dev/null) || true
  has_onchange=$(echo "$src_content" | grep -c "onChange" 2>/dev/null) || true
  [[ "$has_value" -gt 0 && "$has_onchange" -gt 0 ]] && score=$((score + 5))

  # ── Select renders option elements (5 pts) ──────────────────────────
  local has_option
  has_option=$(echo "$src_content" | grep -c "<option" 2>/dev/null) || true
  [[ "$has_option" -gt 0 ]] && score=$((score + 5))

  # ── Checkbox supports controlled mode (5 pts) ───────────────────────
  local has_checked
  has_checked=$(echo "$src_content" | grep -c "checked" 2>/dev/null) || true
  [[ "$has_checked" -gt 0 && "$has_onchange" -gt 0 ]] && score=$((score + 5))

  # ── Form handles onSubmit with preventDefault (5 pts) ────────────────
  local has_prevent has_submit
  has_prevent=$(echo "$src_content" | grep -c "preventDefault" 2>/dev/null) || true
  has_submit=$(echo "$src_content" | grep -c "onSubmit" 2>/dev/null) || true
  [[ "$has_prevent" -gt 0 && "$has_submit" -gt 0 ]] && score=$((score + 5))

  # ── Validation: required/minLength/maxLength prop handling (8 pts) ───
  local val_score=0
  grep -q "required" <<< "$src_content" 2>/dev/null && val_score=$((val_score + 2))
  grep -q "minLength\|minlength" <<< "$src_content" 2>/dev/null && val_score=$((val_score + 2))
  grep -q "maxLength\|maxlength" <<< "$src_content" 2>/dev/null && val_score=$((val_score + 2))
  grep -q "pattern" <<< "$src_content" 2>/dev/null && val_score=$((val_score + 2))
  score=$((score + val_score))

  # ── Error display: components render error messages (5 pts) ──────────
  local has_error_display
  has_error_display=$(echo "$src_content" | grep -c "error\|Error\|errorMessage\|error-message\|helperText\|validationMessage" 2>/dev/null) || true
  [[ "$has_error_display" -ge 3 ]] && score=$((score + 5))

  # ── Accessibility: aria-invalid, aria-describedby (8 pts) ───────────
  local aria_score=0
  grep -q "aria-invalid" <<< "$src_content" 2>/dev/null && aria_score=$((aria_score + 4))
  grep -q "aria-describedby" <<< "$src_content" 2>/dev/null && aria_score=$((aria_score + 4))
  score=$((score + aria_score))

  # ── Label association: htmlFor and matching id (5 pts) ───────────────
  local has_htmlfor has_id
  has_htmlfor=$(echo "$src_content" | grep -c "htmlFor" 2>/dev/null) || true
  has_id=$(echo "$src_content" | grep -c 'id=' 2>/dev/null) || true
  [[ "$has_htmlfor" -gt 0 && "$has_id" -gt 0 ]] && score=$((score + 5))

  # ── TypeScript types or PropTypes (5 pts) ────────────────────────────
  local has_tsx has_proptypes has_interface
  has_tsx=$(find "$ws" -maxdepth 5 -name "*.tsx" ! -path "*/node_modules/*" 2>/dev/null | head -1) || true
  has_proptypes=$(echo "$src_content" | grep -c "PropTypes\|propTypes" 2>/dev/null) || true
  has_interface=$(echo "$src_content" | grep -c "interface.*Props\|type.*Props" 2>/dev/null) || true
  [[ -n "$has_tsx" || "$has_proptypes" -gt 0 || "$has_interface" -gt 0 ]] && score=$((score + 5))

  # ── Spread props: ...rest or ...props (5 pts) ──────────────────────
  local has_spread
  has_spread=$(echo "$src_content" | grep -c '\.\.\.rest\|\.\.\.props\|\.\.\.other' 2>/dev/null) || true
  [[ "$has_spread" -gt 0 ]] && score=$((score + 5))

  # ── Tests pass: npm test (8 pts) ────────────────────────────────────
  local test_output
  test_output=$(cd "$ws" && npm test -- --watchAll=false --forceExit 2>&1) || true
  if echo "$test_output" | grep -qE "Tests:.*passed|Test Suites:.*passed|passing" 2>/dev/null; then
    # Tests actually passed (no failures)
    if ! echo "$test_output" | grep -qE "Tests:.*failed|Test Suites:.*failed|failing" 2>/dev/null; then
      score=$((score + 8))
    else
      score=$((score + 3))  # Partial: some passed, some failed
    fi
  fi

  # ── Uses hooks (useState, useCallback, etc.) (3 pts) ────────────────
  grep -q "useState\|useCallback\|useEffect\|useRef\|useMemo" <<< "$src_content" 2>/dev/null && score=$((score + 3))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # ── Test files exist (10 pts) ───────────────────────────────────────
  local test_files
  test_files=$(find "$ws" -maxdepth 5 \( -name "*.test.tsx" -o -name "*.test.jsx" -o -name "*.test.ts" -o -name "*.test.js" \
    -o -name "*.spec.tsx" -o -name "*.spec.jsx" -o -name "*.spec.ts" -o -name "*.spec.js" \) \
    ! -path "*/node_modules/*" 2>/dev/null) || true
  local test_file_count
  test_file_count=$(echo "$test_files" | grep -c "." 2>/dev/null) || true
  [[ "$test_file_count" -ge 1 ]] && score=$((score + 5))
  [[ "$test_file_count" -ge 3 ]] && score=$((score + 5))

  # ── Tests pass (25 pts) ─────────────────────────────────────────────
  local test_output
  test_output=$(cd "$ws" && npm test -- --watchAll=false --forceExit 2>&1) || true
  if echo "$test_output" | grep -qE "Tests:.*passed|Test Suites:.*passed|passing" 2>/dev/null; then
    if ! echo "$test_output" | grep -qE "Tests:.*failed|Test Suites:.*failed|failing" 2>/dev/null; then
      score=$((score + 25))
    else
      score=$((score + 10))  # Partial credit
    fi
  fi

  # ── Gather all test content ─────────────────────────────────────────
  local test_content
  test_content=$(echo "$test_files" | xargs cat 2>/dev/null) || true

  # ── Tests cover each component (5 pts each = 20 pts) ────────────────
  for comp in "TextInput" "Select" "Checkbox" "Form"; do
    local comp_tested
    comp_tested=$(echo "$test_content" | grep -c "$comp" 2>/dev/null) || true
    [[ "$comp_tested" -gt 0 ]] && score=$((score + 5))
  done

  # ── Tests use render/screen from testing-library (10 pts) ───────────
  local has_render has_screen
  has_render=$(echo "$test_content" | grep -c "render(" 2>/dev/null) || true
  has_screen=$(echo "$test_content" | grep -c "screen\." 2>/dev/null) || true
  [[ "$has_render" -gt 0 ]] && score=$((score + 5))
  [[ "$has_screen" -gt 0 ]] && score=$((score + 5))

  # ── Tests check accessibility (getByRole, getByLabelText) (10 pts) ──
  local has_role has_label
  has_role=$(echo "$test_content" | grep -c "getByRole\|getAllByRole\|queryByRole\|findByRole" 2>/dev/null) || true
  has_label=$(echo "$test_content" | grep -c "getByLabelText\|getAllByLabelText\|queryByLabelText" 2>/dev/null) || true
  [[ "$has_role" -gt 0 ]] && score=$((score + 5))
  [[ "$has_label" -gt 0 ]] && score=$((score + 5))

  # ── Tests cover validation (required, error display) (10 pts) ───────
  local has_val_test
  has_val_test=$(echo "$test_content" | grep -c "required\|error\|invalid\|valid\|validation" 2>/dev/null) || true
  [[ "$has_val_test" -ge 2 ]] && score=$((score + 5))
  [[ "$has_val_test" -ge 5 ]] && score=$((score + 5))

  # ── Tests cover form submission flow (5 pts) ────────────────────────
  local has_submit_test
  has_submit_test=$(echo "$test_content" | grep -c "submit\|onSubmit\|fireEvent.submit\|userEvent.*click" 2>/dev/null) || true
  [[ "$has_submit_test" -ge 2 ]] && score=$((score + 5))

  # ── Test count >10 (5 pts), >20 (5 pts) ────────────────────────────
  local total_tests
  total_tests=$(echo "$test_content" | grep -cE "it\(|test\(" 2>/dev/null) || true
  [[ "$total_tests" -ge 10 ]] && score=$((score + 5))
  [[ "$total_tests" -ge 20 ]] && score=$((score + 5))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  # ── Gather all source files content ─────────────────────────────────
  local src_content
  src_content=$(find "$ws" -maxdepth 5 \( -name "*.tsx" -o -name "*.jsx" -o -name "*.ts" -o -name "*.js" \) \
    ! -path "*/node_modules/*" ! -path "*/*.test.*" ! -path "*/*.spec.*" \
    ! -path "*/__tests__/*" -exec cat {} + 2>/dev/null) || true

  # ── All components are functional — no class components (10 pts) ────
  local has_class_component
  has_class_component=$(echo "$src_content" | grep -c "class.*extends.*Component\|class.*extends.*React.Component" 2>/dev/null) || true
  local has_functional
  has_functional=$(echo "$src_content" | grep -c "function\|=>" 2>/dev/null) || true
  if [[ "$has_class_component" -eq 0 && "$has_functional" -gt 0 ]]; then
    score=$((score + 10))
  fi

  # ── Uses hooks correctly (useState, useEffect, etc.) (10 pts) ──────
  local hook_types=0
  grep -q "useState" <<< "$src_content" 2>/dev/null && hook_types=$((hook_types + 1))
  grep -q "useEffect" <<< "$src_content" 2>/dev/null && hook_types=$((hook_types + 1))
  grep -q "useCallback" <<< "$src_content" 2>/dev/null && hook_types=$((hook_types + 1))
  grep -q "useRef" <<< "$src_content" 2>/dev/null && hook_types=$((hook_types + 1))
  grep -q "useMemo" <<< "$src_content" 2>/dev/null && hook_types=$((hook_types + 1))
  [[ $hook_types -ge 2 ]] && score=$((score + 5))
  [[ $hook_types -ge 4 ]] && score=$((score + 5))

  # ── Proper prop destructuring (10 pts) ──────────────────────────────
  local has_destructure
  has_destructure=$(echo "$src_content" | grep -c "{ .*} =" 2>/dev/null) || true
  local has_destructure2
  has_destructure2=$(echo "$src_content" | grep -c "({.*})" 2>/dev/null) || true
  [[ "$has_destructure" -gt 2 || "$has_destructure2" -gt 2 ]] && score=$((score + 10))

  # ── Accessibility: aria-invalid on error (10 pts) ──────────────────
  grep -q "aria-invalid" <<< "$src_content" 2>/dev/null && score=$((score + 10))

  # ── Accessibility: aria-describedby linking input to error (10 pts) ─
  grep -q "aria-describedby" <<< "$src_content" 2>/dev/null && score=$((score + 10))

  # ── Has forwardRef for input components (5 pts) ────────────────────
  grep -q "forwardRef\|React.forwardRef" <<< "$src_content" 2>/dev/null && score=$((score + 5))

  # ── No inline styles — prefers className (5 pts) ──────────────────
  local inline_style_count
  inline_style_count=$(echo "$src_content" | grep -c "style={{" 2>/dev/null) || true
  local classname_count
  classname_count=$(echo "$src_content" | grep -c "className" 2>/dev/null) || true
  if [[ "$inline_style_count" -le 1 && "$classname_count" -ge 2 ]]; then
    score=$((score + 5))
  elif [[ "$inline_style_count" -eq 0 ]]; then
    score=$((score + 5))
  fi

  # ── Clean exports from index (10 pts) ──────────────────────────────
  local index_file=""
  for f in "src/index.tsx" "src/index.ts" "src/index.jsx" "src/index.js" \
           "index.tsx" "index.ts" "index.jsx" "index.js" \
           "components/index.tsx" "components/index.ts" "components/index.jsx" "components/index.js"; do
    [[ -f "$ws/$f" ]] && index_file="$ws/$f" && break
  done
  if [[ -n "$index_file" ]]; then
    local export_count
    export_count=$(grep -c "export" "$index_file" 2>/dev/null) || true
    [[ "$export_count" -ge 5 ]] && score=$((score + 10))
  fi

  # ── Error boundary or proper error handling (5 pts) ────────────────
  local has_error_boundary
  has_error_boundary=$(echo "$src_content" | grep -c "ErrorBoundary\|componentDidCatch\|getDerivedStateFromError\|try.*catch" 2>/dev/null) || true
  [[ "$has_error_boundary" -gt 0 ]] && score=$((score + 5))

  # ── Memo/useCallback for performance (5 pts) ──────────────────────
  local has_memo
  has_memo=$(echo "$src_content" | grep -c "React.memo\|useMemo\|useCallback\|memo(" 2>/dev/null) || true
  [[ "$has_memo" -ge 2 ]] && score=$((score + 5))

  # ── Has proper Jest config (5 pts) ─────────────────────────────────
  local has_jest_config=0
  [[ -f "$ws/jest.config.js" || -f "$ws/jest.config.ts" || -f "$ws/jest.config.cjs" || -f "$ws/jest.config.mjs" ]] && has_jest_config=1
  if [[ "$has_jest_config" -eq 0 ]]; then
    # Check package.json for jest config
    local pkg
    pkg=$(cat "$ws/package.json" 2>/dev/null) || true
    echo "$pkg" | grep -q '"jest"' 2>/dev/null && has_jest_config=1
  fi
  [[ "$has_jest_config" -eq 1 ]] && score=$((score + 5))

  # ── Has Babel config for JSX transform (5 pts) ────────────────────
  local has_babel=0
  [[ -f "$ws/.babelrc" || -f "$ws/babel.config.js" || -f "$ws/babel.config.json" || -f "$ws/babel.config.cjs" ]] && has_babel=1
  if [[ "$has_babel" -eq 0 ]]; then
    local pkg2
    pkg2=$(cat "$ws/package.json" 2>/dev/null) || true
    echo "$pkg2" | grep -q '"babel"' 2>/dev/null && has_babel=1
  fi
  # Also accept ts-jest or @swc/jest as alternatives to Babel
  if [[ "$has_babel" -eq 0 ]]; then
    grep -q "ts-jest\|@swc/jest" <<< "$src_content" 2>/dev/null && has_babel=1
    [[ -f "$ws/tsconfig.json" ]] && grep -q '"jsx"' "$ws/tsconfig.json" 2>/dev/null && has_babel=1
  fi
  [[ "$has_babel" -eq 1 ]] && score=$((score + 5))

  # ── TypeScript strict mode or PropTypes on all components (10 pts) ──
  local ts_strict=0
  if [[ -f "$ws/tsconfig.json" ]]; then
    grep -q '"strict".*true' "$ws/tsconfig.json" 2>/dev/null && ts_strict=1
  fi
  local proptypes_count
  proptypes_count=$(echo "$src_content" | grep -c "PropTypes\.\|propTypes" 2>/dev/null) || true
  local interface_count
  interface_count=$(echo "$src_content" | grep -c "interface.*Props\|type.*Props" 2>/dev/null) || true
  if [[ "$ts_strict" -eq 1 ]]; then
    score=$((score + 10))
  elif [[ "$interface_count" -ge 4 ]]; then
    score=$((score + 8))
  elif [[ "$proptypes_count" -ge 4 ]]; then
    score=$((score + 8))
  elif [[ "$interface_count" -ge 2 || "$proptypes_count" -ge 2 ]]; then
    score=$((score + 4))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}
