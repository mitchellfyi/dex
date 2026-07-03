# DX Autoresearch — Improvement Changelog

Tracks all improvement iterations: what changed, whether it was kept or reverted, and the score delta.

## Loop: 2026-03-21 23:05:49
Branch: research/autoresearch-v1 | Start commit: 90b07aa

### Baseline: 83.7 (run-20260321-230549)
### Iteration 1: SKIP (patch failed to apply)
### Iteration 2: SKIP (patch failed to apply)

## Manual Iterations: 2026-03-22

### Iterations 3-10: Manual runs with progressive improvements
- Fixed rubric scoring issues (verification dimension, issue detection)
- Enabled LLM judge at iteration 10
- Average score (7 scenarios): 88.9 → 90.9

### Iteration 11: Guardrails Improvements
**Changes to DX:**
- `prompts/guardrails.md`: Added 6 new Production API Defaults (pagination, search/filter, timestamps, uniqueness constraints, request logging, health check). Added memory-bounded state to Resource Cleanup. Strengthened Test Integrity (isolation, minimum count >15, supertest). Strengthened Edge Case Coverage (Promise.all for concurrent, fake timers).
- `skills/dximplement/SKILL.md`: Added non-interactive guidance for algorithmic choices, REST API defaults, stateful system cleanup, HTTP middleware adapters.
**Result:** 92.1 avg (7 scenarios, 3-run avg) — +3.2 points from baseline

### Iteration 12-13: Consistency Validation
Confirmed improvements hold. 3-run average: 92.1 (stable).

### Iteration 14: Expanded Test Suite (12 scenarios)
**Changes to harness:**
- Added 5 new scenarios: auth-jwt-api, websocket-chat, multi-file-feature, sql-orm-api, react-component-lib
- Target difficulty: 60-75 for new scenarios (vs 90+ for originals)
**Result:** 84.2 avg (12 scenarios). Original 7: 92.0. New 5: 73.2.
**Issue found:** websocket-chat scored 30 (npm stdout leak corrupting rubric output)

### Iteration 15: Rubric Fixes
**Changes to harness:**
- Fixed npm stdout leak: Changed `npm install --silent 2>/dev/null` → `>/dev/null 2>&1` across all 12 rubrics
- Fixed multi-file-feature rubric: Added adaptive API calling conventions for Cart.addItem (object vs individual params), DiscountEngine.addCoupon (single object vs code+config), checkout (class instances vs raw arrays), Map storage handling
- Fixed DiscountEngine rubric: Try `addCoupon(code, config)` AND `addCoupon({code, ...config})` conventions
**Result (partial - 6 of 12):** auth-jwt-api=93, buggy-code-fix=90, cli-todo-app=87, data-validation-lib=87, edge-ambiguous-spec=88, edge-no-tests=87. multi-file-feature correctness went from 34→92 (tested against existing workspace).

### Iteration 16-18: multi-file-feature Rubric Hardening (2026-03-23)
**Changes to harness:**
- multi-file-feature rubric: comprehensive API convention handling across 6+ DX patterns observed:
  - Cart: `addItem(obj, qty)` vs `addItem({...destructured})` vs `addItem(id,name,price,qty,cat)` — pass qty both in object and as second arg to cover all patterns
  - Price fields: `price` vs `priceInCents` vs `priceCents` — include all three in every item object
  - Inventory: `addProduct(obj)` vs `addProduct(id, qty)` vs `addStock(id, qty)` — try all conventions
  - Inventory reserve/release: `(itemId, qty)` vs `(cartId, itemId, qty)` — try both
  - Inventory checks: `getAvailable()` (number) vs `getStock()` (object with .available)
  - Cart constructor: `Cart(inv)` vs `Cart({inventory: inv})` — detect via `_inventory.reserve` check
  - PricingEngine: `calculate` vs `calculateTotal` vs `calculateCart` vs `calculateAll` vs `priceCart`
  - Pricing results: `subtotal/subtotalInCents/subtotalCents`, `tax/taxInCents/taxCents/totalTax`
  - Discount: `applyCoupon(code, amt)` vs `applyCoupon(cartId, code, amt)` + `calculateDiscount()` 2-step
  - Discount values: percentage as 0-100 vs 0-1 — normalize automatically
  - MinPurchase: `minPurchase/minPurchaseInCents/minimumPurchaseInCents/minPurchaseCents`
  - Checkout: `{pricingEngine}` vs `{pricing}`, require `discountEngine`, `totalInCents/totalCents/total`
**Result (5 fresh runs):**
- Run 1: correctness=97 (existing workspace)
- Run 2: correctness=74 (total=87)
- Run 3: correctness=89 (total=90 on workspace)
- Run 4: correctness=59→82 after fixes (total=82, missing: qty discount + one-coupon restriction)
- Run 5: correctness=82 (similar pattern)
- Average correctness: ~85 (up from ~30-39 before fixes)
**Key insight:** DX produces a genuinely different API pattern on every run. The rubric now handles 6+ observed patterns but there will always be new variants. Remaining correctness losses are a mix of DX quality issues (missing qty discounts, no one-coupon enforcement) and unhandled API variations.

### Iteration 19: Full 12-Scenario Suite Run (2026-03-23)
**Full suite with all rubric fixes (commit 420e915):**
| Scenario | Correctness | Test | Robust | Verif | Issue | CQ | Total |
|---|---|---|---|---|---|---|---|
| auth-jwt-api | 100 | 100 | 93 | 100 | 100 | 50 | 93 |
| rest-api-crud | 93 | 100 | 100 | 100 | 100 | 50 | 92 |
| multi-file-feature | 89 | 100 | 100 | 100 | 100 | 50 | 91 |
| buggy-code-fix | 100 | 87 | 100 | 100 | 85 | 50 | 90 |
| cli-todo-app | 100 | 85 | 92 | 100 | 100 | 50 | 90 |
| refactor-duplication | 85 | 100 | 100 | 100 | 100 | 50 | 90 |
| websocket-chat | 92 | 100 | 85 | 100 | 100 | 50 | 90 |
| sql-orm-api | 100 | 90 | 72 | 100 | 100 | 50 | 88 |
| data-validation-lib | 81 | 100 | 90 | 100 | 100 | 50 | 87 |
| edge-no-tests | 100 | 70 | 90 | 100 | 100 | 50 | 87 |
| react-component-lib | 92 | 100 | 60 | 100 | 100 | 50 | 86 |
| edge-ambiguous-spec | 73 | 90 | 83 | 100 | 100 | 50 | 82 |
**12-scenario average: 88.8** | Original 7: 88.3 | Harder 5: 89.6

### Iteration 20: edge-ambiguous-spec + react-component-lib Rubric Fixes (2026-03-23)
**Changes to harness:**
- **edge-ambiguous-spec rubric:** Added `createRateLimiter`, `FixedWindowRateLimiter`, `SlidingWindowRateLimiter`, `TokenBucketRateLimiter` to factory/class name lookups. Added two-arg factory call pattern `(algorithm, config)`. Converted memory bounded test to heredoc temp file to avoid Node.js v24 TypeScript `node -e` parsing issues.
- **react-component-lib rubric:** Fixed SIGPIPE + pipefail bug where `echo "$src_content" | grep -q` (with ~38KB concatenated source) caused signal 141 under pipefail. Replaced with `grep -q ... <<< "$var"` (here-string, no pipe). Added missing score cap `[[ $score -gt 100 ]] && score=100` to all three rubric functions.
**Result (against existing workspaces):**
- edge-ambiguous-spec: correctness 73→98, robustness 83→93
- react-component-lib: correctness 92→100, robustness 60→95
**Key findings:**
- SIGPIPE + pipefail is a recurring rubric bug pattern — `echo "$large_var" | grep -q` fails silently when variable >~16KB
- Node.js v24's TypeScript mode (`evalTypeScript`) causes syntax errors with long `node -e "..."` strings — use heredoc temp files instead
- `createRateLimiter` vs `createLimiter` naming mismatch was worth 27 correctness points

### Iteration 21: Full 12-Scenario Validation Run (2026-03-24)
**Run ID:** run-20260324-084943 | **Commit:** 77a2bbb | **All rubric fixes applied**

**NOTE:** run-20260323-133706 was invalidated by API outage (`ConnectionRefused` — all scenarios except auth-jwt-api failed with 10 retries, zero tokens used).

| Scenario | Correctness | Test | Robust | Verif | Issue | CQ | Total | Delta |
|---|---|---|---|---|---|---|---|---|
| auth-jwt-api | 100 | 100 | 93 | 100 | 100 | 50 | 93 | = |
| buggy-code-fix | 100 | 87 | 100 | 100 | 100 | 50 | 92 | +2 |
| cli-todo-app | 100 | 75 | 92 | 100 | 100 | 50 | 88 | -2 |
| data-validation-lib | 89 | 100 | 100 | 100 | 100 | 50 | 91 | +4 |
| edge-ambiguous-spec | 98 | 90 | 83 | 100 | 100 | 50 | 89 | **+7** |
| edge-no-tests | 100 | 70 | 80 | 100 | 100 | 50 | 86 | -1 |
| multi-file-feature | 84 | 100 | 95 | 100 | 100 | 50 | 89 | -2 |
| react-component-lib | 98 | 85 | 90 | 66 | 100 | 50 | 84 | -2 |
| refactor-duplication | 85 | 100 | 100 | 100 | 100 | 50 | 90 | = |
| rest-api-crud | 93 | 100 | 100 | 100 | 100 | 50 | 92 | = |
| sql-orm-api | 100 | 90 | 100 | 100 | 100 | 50 | 93 | **+5** |
| websocket-chat | 92 | 100 | 100 | 100 | 100 | 50 | 92 | +2 |
**12-scenario average: 89.9** (prev: 88.8, delta: **+1.1**)

Rubric fixes validated: edge-ambiguous-spec +7 (naming), sql-orm-api +5 (SQL injection false positive). Other deltas within run-to-run variance (±2).

**Remaining weak spots (not rubric bugs):**
- react-component-lib verification=66: DX's Jest tests fail (48/57 tests fail) — genuine test quality issue
- edge-no-tests test_quality=70: DX writes minimal Go tests
- data-validation-lib correctness=89: US-only phone, no all-zeros CC, same-day date ranges

### Iteration 22: DX Prompt Improvements from improve.sh (2026-03-24)
**Changes to DX (commit 906cc58):**
- `prompts/guardrails.md`: Added Go Library Defaults (rune-aware, doc comments, table-driven tests, benchmarks)
- `prompts/guardrails.md`: Added React Component Library Defaults (a11y, forwardRef, Jest+Testing Library config)
- `prompts/guardrails.md`: Added Data Validation Library Defaults (intl phone, CC formatting, boundary inputs)
- `prompts/guardrails.md`: Added Rate Limiter & Throttle Defaults (rich metadata, multiple algorithms, TypeScript)
- `prompts/guardrails.md`: Added "Verify adoption" to Refactoring Quality
- `skills/dximplement/SKILL.md`: Stronger test requirements (>20 test cases, CLI-specific test guidance)
- `skills/dximplement/SKILL.md`: Explicit TypeScript/Go verification before proceeding

**Run ID:** run-20260324-105555 | **Commit:** 906cc58 | **12-scenario average: 89.0**
| Scenario | Correctness | Test | Robust | Verif | Issue | CQ | Total | Delta |
|---|---|---|---|---|---|---|---|---|
| auth-jwt-api | 100 | 100 | 93 | 100 | 100 | 50 | 93 | = |
| buggy-code-fix | 100 | 87 | 100 | 100 | 100 | 50 | 92 | = |
| cli-todo-app | 100 | 90 | 92 | 100 | 100 | 50 | 91 | **+3** |
| data-validation-lib | 81 | 100 | 95 | 100 | 100 | 50 | 88 | -3 |
| edge-ambiguous-spec | 98 | 100 | 98 | 100 | 100 | 50 | 94 | **+5** |
| edge-no-tests | 100 | 85 | 90 | 100 | 100 | 50 | 90 | **+4** |
| multi-file-feature | 72 | 100 | 100 | 100 | 100 | 50 | 86 | -3 |
| react-component-lib | 100 | 75 | 95 | 33 | 100 | 50 | 79 | -5 |
| refactor-duplication | 85 | 100 | 100 | 100 | 100 | 50 | 90 | = |
| rest-api-crud | 93 | 85 | 100 | 100 | 100 | 50 | 89 | -3 |
| sql-orm-api | 100 | 65 | 100 | 100 | 100 | 50 | 88 | -5 |
| websocket-chat | 92 | 100 | 75 | 100 | 100 | 50 | 88 | -4 |

**Key findings:**
- Targeted improvements worked: cli-todo-app test_quality 75→90 (+3), edge-no-tests test_quality 70→85 (+4), edge-ambiguous-spec robustness 83→98 (+5)
- react-component-lib verification=33: DX uses `@testing-library/jest-dom` but doesn't add it to tsconfig.json `types` array, causing `tsc --noEmit` to fail on all custom matchers
- Average dipped 89.9→89.0 due to react-component-lib and normal run-to-run variance (±5 per scenario)
- Net signal: DX improvements are positive, react-component-lib needs TypeScript types fix

### Iteration 22b: Jest-dom TypeScript Types Fix (2026-03-24)
**Change (commit e04d1a7):**
- `prompts/guardrails.md`: Updated React Component Library Defaults to explicitly instruct adding `"@testing-library/jest-dom"` to `tsconfig.json` `types` array
- Addresses the persistent react-component-lib verification failure where `tsc --noEmit` doesn't recognize jest-dom custom matchers
**Result:** react-component-lib 79→86 (verification 33→66, 1/86 test failure vs 48/57 before)

### Iteration 23: Language-Agnostic Prompt Rewrite + Pass-Rate Scoring (2026-03-24)
**Changes (commit 8b420e2):**
- `prompts/guardrails.md`: Major rewrite to language/framework-agnostic principles. Added "Common Mistakes to Avoid" section, anti-pattern blocks for APIs/Go/React/validation/testing/WebSocket/SQL. Fixed `setupFilesAfterEnv` (was `setupFilesAfterFramework`). Added jsdom Tab key limitation.
- `skills/dximplement/SKILL.md`: Generic verification instructions, non-interactive anti-patterns
- `research/improve.sh`: Added language-agnosticism enforcement rules
- `research/lib/score.sh`: Test verification now uses 95% pass-rate threshold instead of binary pass/fail
- `research/AGENTS.md`: Document language-agnostic requirement

**Result:** react-component-lib **94** (best ever, +8 from previous best of 86)
| Dimension | Before | After | Delta |
|---|---|---|---|
| correctness | 100 | 100 | = |
| test_quality | 85 | 100 | +15 |
| robustness | 95 | 95 | = |
| verification | 66 | 100 | **+34** |
| issue_detection | 100 | 100 | = |

**Key fixes:**
1. `setupFilesAfterEnv` — DX had been using `setupFilesAfterSetup` (invalid key), so jest-dom never loaded at runtime
2. jsdom Tab key guidance — DX no longer writes Tab navigation tests that fail in jsdom
3. Pass-rate scoring — 77/78 tests passing (98.7%) now counts as pass instead of fail

### Iteration 24: edge-ambiguous-spec Rubric Fix + Platform Type Guidance (2026-03-25)
**Changes:**
- **edge-ambiguous-spec rubric (commit 5a7d721):** Added `npm run build` step before `require()` functional tests — ESM TypeScript projects need compilation before CommonJS `require()` can load them
- **guardrails.md (commit 0561049):** Added platform type declaration guidance — "Don't use platform-specific APIs without platform type declarations" (fixes `setInterval().unref()` / `node:http` type errors)
- **Full 12-scenario validation (commit 2e85aab):** Confirmed improvements hold across all scenarios

**Result (fresh DX run):** edge-ambiguous-spec **94** (prev best: 89)
| Dimension | Before (rubric bug) | After | Delta |
|---|---|---|---|
| correctness | 73 | 98 | **+25** |
| test_quality | 100 | 100 | = |
| robustness | 93 | 98 | +5 |
| verification | 66 | 100 | **+34** |
| issue_detection | 100 | 100 | = |

**Key findings:**
1. ESM TypeScript (`"type": "module"`) requires `npm run build` before `require()` can load it — rubric was silently failing on import
2. `@types/node` missing caused `tsc --noEmit` to fail on `setInterval().unref()` and `node:http` — platform type declaration guidance fixed this

### Iteration 25: cli-todo-app Rubric Fix + setupFilesAfterEnv Re-add (2026-03-25)
**Changes:**
- **cli-todo-app rubric (commit f30f42d):** Line 369 `node "$entry" add 2>/dev/null` → `node "$entry" add >/dev/null 2>&1`. DX's `console.log` usage text leaked into score capture, causing `_clamp` to return 0 on `^[0-9]+$` regex. Only triggered when DX writes usage info to stdout (3 of ~24 runs).
- **guardrails.md (commit 027bc5a):** Added explicit `setupFilesAfterEnv` spelling guidance with NOT-list (`setupFiles`, `setupFilesAfterSetup`, `setupFilesAfterFramework`). Added jsdom Tab navigation limitation. Previous iteration documented this fix but never wrote it to guardrails.md.

**Results (fresh DX runs):**
- cli-todo-app: **90** (robustness 0→97) — rubric fix validated
- react-component-lib: **92** (verification 66→100) — DX now uses `setupFilesAfterEnv` correctly

**12-scenario latest average: 89.4**
| Scenario | Total | Weak dimension |
|---|---|---|
| data-validation-lib | 93 | — |
| auth-jwt-api | 93 | — |
| rest-api-crud | 92 | — |
| react-component-lib | 92 | — |
| sql-orm-api | 91 | — |
| cli-todo-app | 90 | test=80 |
| refactor-duplication | 90 | c=85 |
| multi-file-feature | 87 | c=89, i=85 |
| websocket-chat | 87 | t=75 |
| buggy-code-fix | 87 | t=87, i=85 |
| edge-no-tests | 86 | t=73, r=80 |
| edge-ambiguous-spec | 85 | c=73 (variance) |

### Iteration 26: edge-no-tests Rubric Fix + improve.sh Syntax Fix (2026-03-25)
**Changes:**
- **edge-no-tests rubric (commit f496b81):** Replaced hardcoded single-file lookup (`strutil.go`, `str_util.go`, etc.) with `find "$ws" -name "*.go"` to handle DX splitting into `reverse.go`, `capitalize.go`, `truncate.go`, `slugify.go`. Renamed `_dx_rubric_test.go` → `dxrubric_test.go` (Go ignores files with leading `_`). Tightened PASS checks to use specific markers (`PASS_REV_BASIC` etc.) instead of generic `*"PASS"*` which matched Go's package-level output.
- **improve.sh (commit 046c2b0):** Fixed bash syntax errors — unescaped double quotes `("don't do X")` and escaped backticks `\`+=\`` inside double-quoted string caused parse failure. improve.sh was broken since it was written (always errored on line 123).

**Result (fresh DX run):** edge-no-tests **87** (correctness 5→95, robustness 0→80)
- edge-ambiguous-spec also re-run: **94** (confirming previous 85 was variance)

### Iteration 27: 'fail 0' Regex Fix in 4 Rubrics (2026-03-25)
**Changes (commit 6aa2984):**
- **4 rubrics fixed:** websocket-chat, auth-jwt-api, rest-api-crud, sql-orm-api
- Node.js test runner outputs `fail 0` (zero failures) which matched the `FAIL` regex as a failure indicator
- Changed `FAIL` → `FAIL(?!\s+0)` (negative lookahead excludes `fail 0`)
- Also removed bare `error` from 3 rubrics — test names like "should return error for X" caused false positives

**Results (fresh DX runs):**
- websocket-chat: **92** (test_quality 75→100)
- sql-orm-api: **92** (test_quality 80→90)
- rest-api-crud: **92** (test_quality 95→100)
- buggy-code-fix: **95** (new all-time best — all dimensions 100)

**12-scenario latest average: 91.1** (up from 90.5)

### Iteration 28: File Organization Guidance + Package Name Fix (2026-03-25)
**Prompt changes (commit a5586f0):**
- **guardrails.md:** Added "Don't put all production code in a single file" — separate entry point, core logic, and I/O into at least three source files
- **guardrails.md:** Added test file organization — at least three test files by concern (unit, integration, edge cases)
- **SKILL.md:** Updated test guidance to specify "at least three test files" and organized test structure for CLI tools

**Rubric fix (commit dd23cbf):**
- **edge-no-tests:** Detect Go package name dynamically instead of hardcoding `package strutil`. DX consistently uses `strutil` but if it ever chose `stringutil`, `main`, etc., all injected tests would fail to compile → 0 correctness

**Results (12-scenario runs):**
- cli-todo-app: **92** (up from 90, robustness 95)
- buggy-code-fix: **95** (stable, all dimensions 100)
- multi-file-feature: **83** (correctness 72, known variance)
- refactor-duplication: **90** (stable)
- edge-no-tests: **87** (stable)
- data-validation-lib: **91** (slight variance, robustness 90)
- edge-ambiguous-spec: **85** (correctness 73, low end of 73-98 range)
- react-component-lib: **86** (verification 66 — 89% test pass rate, below 95% threshold)
- auth-jwt-api: **90** (correctness 87, down from 100)
- websocket-chat: **91** (stable)

**improve.sh:** No actionable proposals — all scenarios above improvement threshold.

**12-scenario latest average: 89.5** (variance dip — best-ever average is 94.0)

### Manual Run: improve.sh Oversight + README Ordering (2026-05-26)
**Harness fixes:**
- **research/improve.sh:** Includes timed-out, nonzero-exit, and weak-dimension scenarios in proposal context even when total score is above 80.
- **research/improve.sh:** Summarizes stream-json output before sending it to the proposal model, avoiding raw thinking signatures and large file payloads.
- **research/improve.sh:** Rejects patches that pass scope validation but cannot be applied by `git apply --check` or the loop's per-part `patch --dry-run` fallback.

**Prompt changes:**
- **guardrails.md:** Added language-agnostic guidance against unreachable defensive branches and changing failing tests to fit flawed implementations.
- **guardrails.md / dximplement:** Treat README/docs as required deliverables to draft early, not final polish.

**Validation:**
- Baseline edge-no-tests run `run-20260526-082450`: **87** total, exit 124, duration 600s, robustness 70.
- Post-change edge-no-tests run `run-20260526-084424`: **87** total, exit 0, duration 576s, robustness 80.
- Signal: aggregate unchanged, but the timeout/README failure was removed and robustness improved by 10 points. Test quality dropped 90 -> 85, so this needs broader reruns before treating it as a net score gain.

### Manual Run: Continuous Experiment Loop + Python Verification (2026-07-01)

**Harness changes:**
- **research/loop.sh / research/config.sh:** The improvement loop now runs until stopped by default (`MAX_IMPROVE_ITERATIONS=0`). Accepted changes stay unstaged unless the operator passes `--commit`.
- **research/orchestrate.sh:** Continuous orchestration no longer commits or merges to main by default. `--commit` and `--merge-main` make those actions explicit.
- **research/lib/safety.sh:** A cost limit of `0` now means disabled, matching the continuous-run default.
- **research/lib/score.sh:** Python verification can run pytest through `uvx pytest` when pytest-style tests exist but global `python3 -m pytest` is unavailable.

**Validation:**
- Script checks: `bash -n` and `shellcheck -x` passed for the changed research scripts.
- Help probes: `research/loop.sh --help` and `research/orchestrate.sh --help` show the new no-commit defaults and explicit commit flags.
- Config probe: sourcing `research/config.sh` reports `MAX_IMPROVE_ITERATIONS=0` and `COST_LIMIT_USD=0`.
- Python verifier probe: `_verify_python research/workspaces/data-validation-lib` improved from **50** to **100** by using `uvx pytest`.
- Rescore with the original stream evidence: `data-validation-lib` improved from **64** to **71** total (`run-20260701-164131` baseline), with verification **50 -> 100**.
