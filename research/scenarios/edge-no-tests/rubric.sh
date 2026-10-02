#!/usr/bin/env bash
# Rubric for: edge-no-tests
# Key test: DX should write tests even though the prompt doesn't ask for them.
# Target: a "perfect" DX implementation should score ~80-85, not 100.
# This is a HARD scenario — the prompt never mentions tests, but good engineering
# practice demands them.
#
# Scoring totals: correctness=100, test_quality=100, robustness=100
# Expected "good DX" scores: correctness ~75, test_quality ~65, robustness ~60
# Overall weighted: ~80-85

rubric_correctness() {
  local ws="$1"
  local score=0

  [[ -f "$ws/go.mod" ]] && score=$((score + 5))

  # Find any Go source file (DX may split across multiple files)
  local go_files
  go_files=$(find "$ws" -maxdepth 1 -name "*.go" ! -name "*_test.go" 2>/dev/null | head -1)
  [[ -z "$go_files" ]] && { echo "$score"; return; }

  # Go builds cleanly
  if (cd "$ws" && go build ./... 2>/dev/null); then
    score=$((score + 5))
  else
    echo "$score"; return
  fi

  # All correctness checks inject a temporary test file into the package,
  # run it via `go test`, then clean up. This avoids import resolution issues.
  # Note: filename must NOT start with _ or . (Go ignores those files).
  local tmptest="$ws/dxrubric_test.go"

  # Detect the actual package name from Go source files (DX may use strutil, stringutil, main, etc.)
  local pkg_name
  # shellcheck disable=SC2086  # go_files is a find-produced file list for grep.
  pkg_name=$(grep -m1 '^package ' $go_files 2>/dev/null | awk '{print $2}') || true
  [[ -z "$pkg_name" ]] && pkg_name="strutil"

  # --- Reverse: basic ASCII + empty string (10pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricReverseBasic(t *testing.T) {
    if Reverse("hello") == "olleh" && Reverse("") == "" {
        fmt.Println("PASS_REV_BASIC")
    } else {
        t.Fatal("FAIL")
    }
}
GOEOF
  local rev_basic
  rev_basic=$(cd "$ws" && go test -run TestDKRubricReverseBasic -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$rev_basic" == *"PASS_REV_BASIC"* ]] && score=$((score + 10))

  # --- Reverse: multi-byte Unicode / rune-level (7pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricReverseUnicode(t *testing.T) {
    if Reverse("héllo") == "olléh" {
        fmt.Println("PASS_REV_UNI")
    } else {
        t.Fatalf("FAIL: got %q", Reverse("héllo"))
    }
}
GOEOF
  local rev_unicode
  rev_unicode=$(cd "$ws" && go test -run TestDKRubricReverseUnicode -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$rev_unicode" == *"PASS_REV_UNI"* ]] && score=$((score + 7))

  # --- Reverse: emoji / grapheme clusters (5pts) ---
  # This is HARD — most naive rune-based Reverse breaks combining chars.
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricReverseEmoji(t *testing.T) {
    // Flag emoji is two code points (regional indicators).
    // Naive rune reverse of "ab🇯🇵" would split the flag.
    r := Reverse("ab🇯🇵")
    if r == "🇯🇵ba" {
        fmt.Println("PASS_REV_EMOJI")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local rev_emoji
  rev_emoji=$(cd "$ws" && go test -run TestDKRubricReverseEmoji -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$rev_emoji" == *"PASS_REV_EMOJI"* ]] && score=$((score + 5))

  # --- Capitalize: basic (10pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricCapBasic(t *testing.T) {
    r := Capitalize("hello world")
    if r == "Hello World" {
        fmt.Println("PASS_CAP_BASIC")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local cap_basic
  cap_basic=$(cd "$ws" && go test -run TestDKRubricCapBasic -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$cap_basic" == *"PASS_CAP_BASIC"* ]] && score=$((score + 10))

  # --- Capitalize: Unicode accented chars (5pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricCapUnicode(t *testing.T) {
    // "école de paris" -> "École De Paris" (É is correct Unicode uppercase of é)
    r := Capitalize("école de paris")
    if r == "École De Paris" {
        fmt.Println("PASS_CAP_UNI")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local cap_unicode
  cap_unicode=$(cd "$ws" && go test -run TestDKRubricCapUnicode -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$cap_unicode" == *"PASS_CAP_UNI"* ]] && score=$((score + 5))

  # --- Capitalize: empty and whitespace (4pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricCapEmpty(t *testing.T) {
    if Capitalize("") == "" && Capitalize("   ") == "   " {
        fmt.Println("PASS_CAP_EMPTY")
    } else {
        t.Fatal("FAIL")
    }
}
GOEOF
  local cap_empty
  cap_empty=$(cd "$ws" && go test -run TestDKRubricCapEmpty -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$cap_empty" == *"PASS_CAP_EMPTY"* ]] && score=$((score + 4))

  # --- Truncate: basic (10pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricTruncBasic(t *testing.T) {
    r := Truncate("hello world", 5)
    // "he..." (5 total including dots) or "hello..." (append dots after 5 chars) — both OK
    pass := r == "he..." || r == "hello..."
    // No truncation if string fits
    r2 := Truncate("hi", 10)
    if pass && r2 == "hi" {
        fmt.Println("PASS_TRUNC_BASIC")
    } else {
        t.Fatalf("FAIL: got %q and %q", r, r2)
    }
}
GOEOF
  local trunc_basic
  trunc_basic=$(cd "$ws" && go test -run TestDKRubricTruncBasic -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$trunc_basic" == *"PASS_TRUNC_BASIC"* ]] && score=$((score + 10))

  # --- Truncate: must not break multi-byte characters (5pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
    "unicode/utf8"
)

func TestDKRubricTruncUnicode(t *testing.T) {
    // Truncating "héllo" at maxLen=3 should give valid UTF-8
    r := Truncate("héllo", 3)
    if utf8.ValidString(r) {
        fmt.Println("PASS_TRUNC_UNI")
    } else {
        t.Fatal("FAIL: invalid UTF-8 output")
    }
}
GOEOF
  local trunc_unicode
  trunc_unicode=$(cd "$ws" && go test -run TestDKRubricTruncUnicode -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$trunc_unicode" == *"PASS_TRUNC_UNI"* ]] && score=$((score + 5))

  # --- Truncate: edge cases — 0, negative, empty (5pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricTruncEdge(t *testing.T) {
    r1 := Truncate("", 5)
    r2 := Truncate("hello", 0)
    // Empty input -> empty; 0 maxLen -> "..." or ""
    if r1 == "" && (r2 == "..." || r2 == "") {
        fmt.Println("PASS_TRUNC_EDGE")
    } else {
        t.Fatalf("FAIL: got %q and %q", r1, r2)
    }
}
GOEOF
  local trunc_edge
  trunc_edge=$(cd "$ws" && go test -run TestDKRubricTruncEdge -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$trunc_edge" == *"PASS_TRUNC_EDGE"* ]] && score=$((score + 5))

  # --- Slugify: basic (8pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricSlugBasic(t *testing.T) {
    r := Slugify("Hello World!")
    if r == "hello-world" {
        fmt.Println("PASS_SLUG_BASIC")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local slug_basic
  slug_basic=$(cd "$ws" && go test -run TestDKRubricSlugBasic -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$slug_basic" == *"PASS_SLUG_BASIC"* ]] && score=$((score + 8))

  # --- Slugify: multiple spaces / special chars (6pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "strings"
    "testing"
)

func TestDKRubricSlugSpecial(t *testing.T) {
    r := Slugify("  Hello   World!!! ---  ")
    pass := !strings.HasPrefix(r, "-") && !strings.HasSuffix(r, "-") && !strings.Contains(r, "--")
    if pass && r == "hello-world" {
        fmt.Println("PASS_SLUG_SPECIAL")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local slug_special
  slug_special=$(cd "$ws" && go test -run TestDKRubricSlugSpecial -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$slug_special" == *"PASS_SLUG_SPECIAL"* ]] && score=$((score + 6))

  # --- Slugify: Unicode / accented chars (5pts) ---
  # Hard: "Café Résumé" should become "cafe-resume" (transliterated) or "caf-rsum" (stripped)
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "strings"
    "testing"
)

func TestDKRubricSlugUnicode(t *testing.T) {
    r := Slugify("Café Résumé")
    // Best: "cafe-resume" (transliterated). Acceptable: "caf-rsum" (stripped non-ASCII).
    // Must be valid slug: lowercase, no special chars, no leading/trailing hyphens
    pass := !strings.HasPrefix(r, "-") && !strings.HasSuffix(r, "-") && !strings.Contains(r, "--")
    if pass && len(r) >= 3 && r == strings.ToLower(r) {
        fmt.Println("PASS_SLUG_UNI")
    } else {
        t.Fatalf("FAIL: got %q", r)
    }
}
GOEOF
  local slug_unicode
  slug_unicode=$(cd "$ws" && go test -run TestDKRubricSlugUnicode -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$slug_unicode" == *"PASS_SLUG_UNI"* ]] && score=$((score + 5))

  # --- Slugify: empty / whitespace only (5pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "testing"
)

func TestDKRubricSlugEmpty(t *testing.T) {
    r1 := Slugify("")
    r2 := Slugify("   ")
    if r1 == "" && r2 == "" {
        fmt.Println("PASS_SLUG_EMPTY")
    } else {
        t.Fatalf("FAIL: got %q and %q", r1, r2)
    }
}
GOEOF
  local slug_empty
  slug_empty=$(cd "$ws" && go test -run TestDKRubricSlugEmpty -v ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$slug_empty" == *"PASS_SLUG_EMPTY"* ]] && score=$((score + 5))

  # --- Long string stress test — 10K+ chars (5pts) ---
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "strings"
    "testing"
)

func TestDKRubricLongString(t *testing.T) {
    long := strings.Repeat("abcde ", 2000) // ~12K chars
    // Should not panic on any function
    _ = Reverse(long)
    _ = Capitalize(long)
    _ = Truncate(long, 100)
    _ = Slugify(long)
    fmt.Println("PASS_LONG")
}
GOEOF
  local long_test
  long_test=$(cd "$ws" && go test -run TestDKRubricLongString -v -timeout 30s ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$long_test" == *"PASS_LONG"* ]] && score=$((score + 5))

  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  # ============================================================
  # THIS IS THE KEY DIMENSION: The prompt NEVER asks for tests.
  # A great DX should write them anyway — that's the whole point
  # of this scenario.
  # ============================================================

  # Step 1: Do test files exist at all? (CRITICAL — 40pt bonus)
  local test_files
  test_files=$(find "$ws" -name "*_test.go" ! -name "dxrubric*" 2>/dev/null | wc -l | tr -d ' ')

  if [[ $test_files -gt 0 ]]; then
    score=$((score + 40))  # Massive bonus for writing tests unprompted
  else
    # No tests at all — this dimension is effectively 0
    echo "0"
    return
  fi

  # Step 2: Tests actually pass (not just present)
  local tests_output
  # Run DX's tests (exclude our rubric injected tests by name prefix).
  # The rubric test files are cleaned up before this runs, so this is just a safety measure.
  tests_output=$(cd "$ws" && go test ./... -count=1 2>&1) || true
  if [[ "$tests_output" == *"PASS"* && "$tests_output" != *"FAIL"* ]]; then
    score=$((score + 10))
  fi

  # Step 3: Tests cover ALL 4 functions
  local funcs_tested=0
  for func in "Reverse" "Capitalize" "Truncate" "Slugify"; do
    if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -ql "$func" {} + 2>/dev/null; then
      funcs_tested=$((funcs_tested + 1))
    fi
  done
  [[ $funcs_tested -ge 3 ]] && score=$((score + 5))
  [[ $funcs_tested -ge 4 ]] && score=$((score + 5))

  # Step 4: Table-driven tests (idiomatic Go)
  if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -qlE '\[\]struct|testCases|testcases|tests\s*:=|cases\s*:=|tt\.|tc\.' {} + 2>/dev/null; then
    score=$((score + 8))
  fi

  # Step 5: Edge cases in tests (empty strings, Unicode, long strings)
  local edge_cases=0
  # Check for empty string test cases
  if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -ql '""' {} + 2>/dev/null; then
    edge_cases=$((edge_cases + 1))
  fi
  # Check for Unicode test cases
  if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -qlE 'unicode|rune|utf|emoji|héllo|café|accented|ñ|ü|é' {} + 2>/dev/null; then
    edge_cases=$((edge_cases + 1))
  fi
  # Check for long string or boundary tests
  if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -qlE 'Repeat|long|boundary|10000|1000|large' {} + 2>/dev/null; then
    edge_cases=$((edge_cases + 1))
  fi
  [[ $edge_cases -ge 1 ]] && score=$((score + 5))
  [[ $edge_cases -ge 2 ]] && score=$((score + 5))
  [[ $edge_cases -ge 3 ]] && score=$((score + 7))

  # Step 6: Benchmark tests (bonus — very few DXs will do this)
  if find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -ql "func Benchmark" {} + 2>/dev/null; then
    score=$((score + 5))
  fi

  # Step 7: Test count — more tests = more thorough
  local test_func_count
  test_func_count=$(find "$ws" -name "*_test.go" ! -name "dxrubric*" -exec grep -c "func Test" {} + 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  [[ $test_func_count -ge 4 ]] && score=$((score + 5))
  [[ $test_func_count -ge 8 ]] && score=$((score + 5))

  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  # Find all Go source files (DX may split across multiple files)
  local src_files
  src_files=$(find "$ws" -maxdepth 1 -name "*.go" ! -name "*_test.go" 2>/dev/null)
  [[ -z "$src_files" ]] && { echo "0"; return; }

  # Detect the actual package name (needed for injected test file)
  local pkg_name
  # shellcheck disable=SC2086  # src_files is a find-produced file list for grep.
  pkg_name=$(grep -m1 '^package ' $src_files 2>/dev/null | awk '{print $2}') || true
  [[ -z "$pkg_name" ]] && pkg_name="strutil"

  # Concatenate all source content for pattern matching
  local src_content
  # shellcheck disable=SC2086  # src_files is a find-produced file list for cat.
  src_content=$(cat $src_files 2>/dev/null)

  # --- Empty string handling (explicit checks in source) --- (10pts)
  if grep -qE 'len\(s\)\s*==\s*0|s\s*==\s*""|len\(.*\)\s*==\s*0' <<< "$src_content" 2>/dev/null; then
    score=$((score + 10))
  fi

  # --- Unicode-aware: uses runes not bytes in Reverse --- (10pts)
  if grep -q "rune\|utf8\|RuneCountInString" <<< "$src_content" 2>/dev/null; then
    score=$((score + 10))
  fi

  # --- Truncate boundary checks (maxLen <= 0, maxLen >= len) --- (10pts)
  if grep -qE 'maxLen\s*[<]=\s*0|maxLen\s*>=\s*len|maxLen\s*>\s*len|len\(.*\)\s*<=\s*max' <<< "$src_content" 2>/dev/null; then
    score=$((score + 10))
  fi

  # --- go vet passes --- (10pts)
  if (cd "$ws" && go vet ./... 2>/dev/null); then
    score=$((score + 10))
  fi

  # --- Go doc comments on all exported functions --- (10pts)
  local exported_funcs
  # shellcheck disable=SC2086  # src_files is a find-produced file list for grep.
  exported_funcs=$(grep -cE '^func [A-Z]' $src_files 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || true
  local documented_funcs
  # A doc comment is a // comment on the line immediately before func
  # shellcheck disable=SC2086  # src_files is a find-produced file list for grep.
  documented_funcs=$(grep -cB1 '^func [A-Z]' $src_files 2>/dev/null | grep -c '//' 2>/dev/null) || true
  if [[ $exported_funcs -gt 0 && $documented_funcs -ge $exported_funcs ]]; then
    score=$((score + 10))
  elif [[ $documented_funcs -ge 2 ]]; then
    score=$((score + 5))  # Partial credit
  fi

  # --- staticcheck / golangci-lint passes (if available) --- (10pts)
  local lint_pass=0
  if command -v staticcheck &>/dev/null; then
    if (cd "$ws" && staticcheck ./... 2>/dev/null); then
      lint_pass=1
    fi
  elif command -v golangci-lint &>/dev/null; then
    if (cd "$ws" && golangci-lint run ./... 2>/dev/null); then
      lint_pass=1
    fi
  else
    # Neither available — give benefit of the doubt if go vet passed
    lint_pass=1
  fi
  [[ $lint_pass -eq 1 ]] && score=$((score + 10))

  # --- No unnecessary dependencies (stdlib only) --- (10pts)
  local dep_count
  dep_count=$(cd "$ws" && grep -c "require" go.mod 2>/dev/null) || true
  if [[ $dep_count -le 0 ]]; then
    score=$((score + 10))
  fi

  # --- Thread safety: concurrent calls don't panic --- (10pts)
  local tmptest="$ws/dxrubric_test.go"
  cat > "$tmptest" <<GOEOF
package ${pkg_name}

import (
    "fmt"
    "sync"
    "testing"
)

func TestDKRubricConcurrent(t *testing.T) {
    var wg sync.WaitGroup
    for i := 0; i < 100; i++ {
        wg.Add(4)
        go func() { defer wg.Done(); _ = Reverse("hello world") }()
        go func() { defer wg.Done(); _ = Capitalize("hello world") }()
        go func() { defer wg.Done(); _ = Truncate("hello world", 5) }()
        go func() { defer wg.Done(); _ = Slugify("Hello World!") }()
    }
    wg.Wait()
    fmt.Println("PASS_CONCURRENT")
}
GOEOF
  local concurrent_test
  concurrent_test=$(cd "$ws" && go test -run TestDKRubricConcurrent -v -race -timeout 30s ./... 2>&1) || true
  rm -f "$tmptest" 2>/dev/null
  [[ "$concurrent_test" == *"PASS_CONCURRENT"* ]] && score=$((score + 10))

  # --- Uses strings.Builder or efficient concatenation --- (10pts)
  if grep -qE 'strings\.Builder|bytes\.Buffer|strings\.Join|append.*rune' <<< "$src_content" 2>/dev/null; then
    score=$((score + 10))
  fi

  # --- Slugify uses regexp or unicode package for special char handling --- (10pts)
  if grep -qE 'regexp\.|unicode\.|strings\.Map' <<< "$src_content" 2>/dev/null; then
    score=$((score + 10))
  fi

  echo "$score"
}

# Custom issue detection: specifically check if DX's self-review caught the Unicode issue
rubric_issue_detection() {
  local ws="$1" result_dir="$2"
  local score=50

  # Check if DX mentioned Unicode handling in its output
  if [[ -f "$result_dir/stream.jsonl" ]]; then
    if grep -qi "unicode\|rune\|utf" "$result_dir/stream.jsonl" 2>/dev/null; then
      score=$((score + 25))  # Recognized the Unicode issue
    fi
    if grep -qi "test\|_test\.go" "$result_dir/stream.jsonl" 2>/dev/null; then
      score=$((score + 25))  # Mentioned testing (even though prompt didn't ask)
    fi
  fi

  echo "$score"
}
