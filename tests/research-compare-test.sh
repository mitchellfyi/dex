#!/usr/bin/env bash
set -euo pipefail

# The arm comparison (research/compare/) grades agents with hidden tests it
# never shows them. A hidden test that is wrong grades every trial wrongly, and
# nothing in a benchmark run would say so. This checks each hidden suite
# against a known answer: the scenario's reference solution must pass all of
# it, and the code before the fix must fail the part that asks for the fix.
# It also pins the measurement pieces that turn a workspace into numbers.
#
# No agent runs here: the "agents" are the reference solutions.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then
  printf '%s\n' 'SKIP: research compare tests require Node 22+'
  exit 0
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-research-compare-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

SCENARIOS="$ROOT/research/scenarios"
MEASURE="$ROOT/research/compare/measure.py"

# build <name> <overlay dir...> — a workspace made of the overlays in order.
build() {
  local ws="$TMP_DIR/$1"
  shift
  mkdir -p "$ws"
  local overlay
  for overlay in "$@"; do
    cp -R "$overlay/." "$ws/"
  done
  printf '%s\n' "$ws"
}

# rates <scenario> <ws> [--followup] — "group=passed/total ..." sorted by group.
rates() {
  local scenario="$1" ws="$2"
  shift 2
  python3 "$MEASURE" hidden --scenario-dir "$SCENARIOS/$scenario" --ws "$ws" "$@" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d["load_errors"]:
    print("LOAD-ERRORS " + " ".join(d["load_errors"]))
print(" ".join("%s=%d/%d" % (g, b["passed"], b["total"]) for g, b in sorted(d["groups"].items())))
'
}

# all_pass <rates> — every group fully passed.
all_pass() {
  python3 -c '
import sys
parts = sys.argv[1].split()
ok = bool(parts) and all(p.split("=")[1].split("/")[0] == p.split("=")[1].split("/")[1] for p in parts)
sys.exit(0 if ok else 1)
' "$1"
}

# group_pass <rates> <group> — did that group fully pass?
group_pass() {
  python3 -c '
import sys
rates = dict(p.split("=") for p in sys.argv[1].split())
passed, total = rates.get(sys.argv[2], "0/0").split("/")
sys.exit(0 if total != "0" and passed == total else 1)
' "$1" "$2"
}

# ── buggy-code-fix ───────────────────────────────────────────────────────────

B="$SCENARIOS/buggy-code-fix"
ws=$(build bcf-ref "$B/compare/reference")
r=$(rates buggy-code-fix "$ws")
all_pass "$r" || { echo "buggy-code-fix reference: $r" >&2; assert_at $LINENO; }

ws="$TMP_DIR/bcf-unfixed"
mkdir -p "$ws/src"
python3 -c '
import re, sys
text = open(sys.argv[1]).read()
sys.stdout.write(re.search(r"```javascript\n(.*?)```", text, re.S).group(1))
' "$B/prompt.md" > "$ws/src/cart.js"
r=$(rates buggy-code-fix "$ws")
! group_pass "$r" spec || { echo "unfixed cart passed spec: $r" >&2; assert_at $LINENO; }

ws=$(build bcf-fup "$B/compare/reference" "$B/compare/followup/reference")
r=$(rates buggy-code-fix "$ws" --followup)
all_pass "$r" || { echo "buggy-code-fix follow-up reference: $r" >&2; assert_at $LINENO; }
r=$(rates buggy-code-fix "$TMP_DIR/bcf-ref" --followup)
! group_pass "$r" followup || { echo "follow-up passed before the follow-up: $r" >&2; assert_at $LINENO; }

# ── cli-todo-app ─────────────────────────────────────────────────────────────

C="$SCENARIOS/cli-todo-app"
ws=$(build cli-ref "$C/compare/reference")
r=$(rates cli-todo-app "$ws")
all_pass "$r" || { echo "cli-todo-app reference: $r" >&2; assert_at $LINENO; }
mkdir -p "$TMP_DIR/cli-empty"
r=$(rates cli-todo-app "$TMP_DIR/cli-empty")
! group_pass "$r" spec || { echo "an empty workspace passed spec: $r" >&2; assert_at $LINENO; }
ws=$(build cli-fup "$C/compare/reference" "$C/compare/followup/reference")
r=$(rates cli-todo-app "$ws" --followup)
all_pass "$r" || { echo "cli-todo-app follow-up reference: $r" >&2; assert_at $LINENO; }

# ── oss-bug-triage ───────────────────────────────────────────────────────────

O="$SCENARIOS/oss-bug-triage"
ws=$(build oss-seed "$O/seed")
r=$(rates oss-bug-triage "$ws")
! group_pass "$r" spec || { echo "the unfixed seed passed spec: $r" >&2; assert_at $LINENO; }
group_pass "$r" preserve || { echo "the seed failed its own preserve suite: $r" >&2; assert_at $LINENO; }
ws=$(build oss-ref "$O/seed" "$O/compare/reference")
r=$(rates oss-bug-triage "$ws")
all_pass "$r" || { echo "oss-bug-triage reference: $r" >&2; assert_at $LINENO; }
ws=$(build oss-fup "$O/seed" "$O/compare/reference" "$O/compare/followup/reference")
r=$(rates oss-bug-triage "$ws" --followup)
all_pass "$r" || { echo "oss-bug-triage follow-up reference: $r" >&2; assert_at $LINENO; }

# ── long-refactor-inheritance ────────────────────────────────────────────────

L="$SCENARIOS/long-refactor-inheritance"
# The golden file is the seed's own behaviour, so the seed passes by definition;
# this catches a case edited without regenerating golden.json.
ws=$(build lr-seed "$L/seed")
r=$(rates long-refactor-inheritance "$ws")
all_pass "$r" || { echo "the refactor seed failed its golden cases: $r" >&2; assert_at $LINENO; }
ws=$(build lr-fup "$L/seed" "$L/compare/followup/reference")
r=$(rates long-refactor-inheritance "$ws" --followup)
all_pass "$r" || { echo "refactor follow-up reference: $r" >&2; assert_at $LINENO; }
r=$(rates long-refactor-inheritance "$TMP_DIR/lr-seed" --followup)
! group_pass "$r" followup || { echo "webhook tests passed without a webhook: $r" >&2; assert_at $LINENO; }

# ── inventory-race ───────────────────────────────────────────────────────────

I="$SCENARIOS/inventory-race"
ws=$(build inv-seed "$I/seed")
r=$(rates inventory-race "$ws")
! group_pass "$r" spec || { echo "the racy seed passed spec: $r" >&2; assert_at $LINENO; }
group_pass "$r" preserve || { echo "the seed failed its own contract: $r" >&2; assert_at $LINENO; }
ws=$(build inv-ref "$I/seed" "$I/compare/reference")
r=$(rates inventory-race "$ws")
all_pass "$r" || { echo "inventory-race reference: $r" >&2; assert_at $LINENO; }
# A service-wide lock is correct but serializes every call; the prompt rules
# it out, and the overlap tests are what notice.
ws=$(build inv-global "$I/seed" "$I/compare/reference")
sed -i.bak 's/this.locks.acquire(keys)/this.locks.acquire(["*"])/' "$ws/src/inventory.js"
r=$(rates inventory-race "$ws")
! group_pass "$r" spec || { echo "a service-wide lock passed spec: $r" >&2; assert_at $LINENO; }
group_pass "$r" robust || { echo "a service-wide lock failed robust: $r" >&2; assert_at $LINENO; }
ws=$(build inv-fup "$I/seed" "$I/compare/reference" "$I/compare/followup/reference")
r=$(rates inventory-race "$ws" --followup)
all_pass "$r" || { echo "inventory-race follow-up reference: $r" >&2; assert_at $LINENO; }

# ── csv-rfc4180 ──────────────────────────────────────────────────────────────

V="$SCENARIOS/csv-rfc4180"
ws=$(build csv-ref "$V/compare/reference")
r=$(rates csv-rfc4180 "$ws")
all_pass "$r" || { echo "csv-rfc4180 reference: $r" >&2; assert_at $LINENO; }
mkdir -p "$TMP_DIR/csv-empty"
r=$(rates csv-rfc4180 "$TMP_DIR/csv-empty")
! group_pass "$r" spec || { echo "an empty workspace passed csv spec: $r" >&2; assert_at $LINENO; }
ws=$(build csv-fup "$V/compare/reference" "$V/compare/followup/reference")
r=$(rates csv-rfc4180 "$ws" --followup)
all_pass "$r" || { echo "csv-rfc4180 follow-up reference: $r" >&2; assert_at $LINENO; }

# ── Mutation testing ─────────────────────────────────────────────────────────

git -C "$TMP_DIR/bcf-ref" init --quiet
git -C "$TMP_DIR/bcf-ref" add -A
score=$(python3 "$MEASURE" mutate --scenario-dir "$B" --ws "$TMP_DIR/bcf-ref" \
  | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["score"] if d["score"] is not None else -1)')
python3 -c 'import sys; sys.exit(0 if 0.5 <= float(sys.argv[1]) <= 1 else 1)' "$score" \
  || { echo "reference mutation score out of range: $score" >&2; assert_at $LINENO; }
git -C "$TMP_DIR/bcf-ref" diff --quiet -- src || { echo "mutation left src/ modified" >&2; assert_at $LINENO; }

# ── Measurement units ────────────────────────────────────────────────────────

PYTHONPATH="$ROOT/research/compare" python3 - "$TMP_DIR" <<'PY'
import json
import os
import subprocess
import sys

import measure

tmp = sys.argv[1]

# Mutation sites skip strings, template text, comments and regex literals.
src = (
    "const a = 'x === y';\n"
    "const b = `t ${n + 1} < u`;\n"
    "// c && d\n"
    "const r = /a|b+/g;\n"
    "if (x === y && !z) { return q / 2; }\n"
)
sites = [(src[s:e], rep) for s, e, _, rep in measure.mutation_sites(src)]
assert sites.count(("+", "-")) == 1, sites  # the template expression, not the regex
assert sites.count(("===", "!==")) == 1, sites
assert ("&&", "||") in sites and ("!", "") in sites and ("/", "*") in sites, sites
assert ("<", "<=") not in sites, sites

# A closing claim is compared with what the suite really did.
assert measure.claims("All 12 tests pass.", False)["false_claim"] is True
assert measure.claims("All 12 tests pass.", True)["false_claim"] is False
assert measure.claims("Tests are not passing yet.", False)["claims_tests_pass"] is False
assert measure.claims("I fixed the bug.", False)["claims_tests_pass"] is False
assert measure.claims("`npm test` runs 17 tests and they all pass.", True)["claims_tests_pass"] is True
assert measure.claims("`npm test` now passes all 26 tests.", True)["claims_tests_pass"] is True

# The diff is measured against the baseline, by category, without the
# excluded (harness-injected) files.
repo = os.path.join(tmp, "diff-repo")
os.makedirs(os.path.join(repo, "src"))
os.makedirs(os.path.join(repo, "tests"))
def git(*args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)
git("init", "--quiet")
git("config", "user.email", "t@t.test")
git("config", "user.name", "t")
open(os.path.join(repo, "src", "a.js"), "w").write("one\ntwo\n")
git("add", "-A")
git("commit", "--quiet", "-m", "base")
base = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
open(os.path.join(repo, "src", "a.js"), "w").write("one\nTWO\nthree\n")
open(os.path.join(repo, "tests", "a.test.js"), "w").write("t\n")
open(os.path.join(repo, "CLAUDE.md"), "w").write("injected\n")
open(os.path.join(repo, "extra.js"), "w").write("x\n")
stats = measure.diff_stats(repo, base, ["CLAUDE.md"], {"allowed": ["src/*", "tests/*"]})
assert stats["source_lines"] == 4, stats  # a.js: 2 added, 1 deleted; extra.js: 1 added
assert stats["test_lines"] == 1, stats
assert stats["files_changed"] == 3, stats
assert stats["outside_scope"] == ["extra.js"], stats

# Usage comes from the result event, or from per-message usage when the run
# was killed before writing one.
stream = os.path.join(tmp, "stream.jsonl")
events = [
    {"type": "system", "subtype": "init", "model": "m-1", "plugins": [], "mcp_servers": []},
    {"type": "assistant", "message": {"id": "a", "usage": {"input_tokens": 10, "output_tokens": 5},
        "content": [{"type": "tool_use", "id": "t1", "name": "Bash"}, {"type": "text", "text": "done"}]}},
    {"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": 0.5, "num_turns": 3,
        "result": "All tests pass.", "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100}},
]
with open(stream, "w") as fh:
    fh.write("\n".join(json.dumps(e) for e in events) + "\n")
usage = measure.agent_usage(stream)
assert usage["model"] == "m-1" and usage["cost_usd"] == 0.5 and usage["num_turns"] == 3, usage
assert usage["tokens"]["total"] == 115 and usage["tool_calls"] == {"Bash": 1}, usage
with open(stream, "w") as fh:
    fh.write("\n".join(json.dumps(e) for e in events[:2]) + "\n")
usage = measure.agent_usage(stream)
assert usage["has_result"] is False and usage["cost_usd"] is None and usage["tokens"]["total"] == 15, usage
assert usage["final_text"] == "done", usage
PY

# ── Differential fuzzing ─────────────────────────────────────────────────────

# fuzz_passed <scenario> <agent ws> <reference ws> <sequences> <steps>
fuzz_passed() {
  node "$ROOT/research/compare/js/fuzz-runner.js" "$SCENARIOS/$1/compare/fuzz.js" "$2" "$3" "$4" "$5" 7 \
    | python3 -c 'import json, sys; d = json.load(sys.stdin); print("harness-error" if d["harness_errors"] else d["passed"])'
}

# Every fuzz definition agrees with its own reference, and catches the code
# before the fix (or, for the refactor, a one-character behaviour change).
[[ "$(fuzz_passed buggy-code-fix "$TMP_DIR/bcf-ref" "$TMP_DIR/bcf-ref" 5 30)" == 5 ]] || assert_at $LINENO
[[ "$(fuzz_passed buggy-code-fix "$TMP_DIR/bcf-unfixed" "$TMP_DIR/bcf-ref" 5 30)" == 0 ]] || assert_at $LINENO
[[ "$(fuzz_passed oss-bug-triage "$TMP_DIR/oss-ref" "$TMP_DIR/oss-ref" 5 40)" == 5 ]] || assert_at $LINENO
[[ "$(fuzz_passed oss-bug-triage "$TMP_DIR/oss-seed" "$TMP_DIR/oss-ref" 5 40)" == 0 ]] || assert_at $LINENO
[[ "$(fuzz_passed oss-bug-triage "$TMP_DIR/oss-fup" "$TMP_DIR/oss-ref" 5 40)" == 5 ]] || assert_at $LINENO
[[ "$(fuzz_passed long-refactor-inheritance "$TMP_DIR/lr-seed" "$TMP_DIR/lr-seed" 5 60)" == 5 ]] || assert_at $LINENO
ws=$(build lr-broken "$L/seed")
sed -i.bak 's/segmentLength - 1)}/segmentLength - 2)}/' "$ws/src/notifications/SmsNotifier.js"
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) < 5 else 1)' \
  "$(fuzz_passed long-refactor-inheritance "$ws" "$TMP_DIR/lr-seed" 5 60)" || assert_at $LINENO
[[ "$(fuzz_passed cli-todo-app "$TMP_DIR/cli-ref" "$TMP_DIR/cli-ref" 2 10)" == 2 ]] || assert_at $LINENO
[[ "$(fuzz_passed cli-todo-app "$TMP_DIR/cli-empty" "$TMP_DIR/cli-ref" 2 10)" == 0 ]] || assert_at $LINENO
# inventory-race alternates sequential and concurrent sequences by seed.
[[ "$(fuzz_passed inventory-race "$TMP_DIR/inv-ref" "$TMP_DIR/inv-ref" 8 40)" == 8 ]] || assert_at $LINENO
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) < 8 else 1)' \
  "$(fuzz_passed inventory-race "$TMP_DIR/inv-seed" "$TMP_DIR/inv-ref" 8 40)" || assert_at $LINENO
[[ "$(fuzz_passed csv-rfc4180 "$TMP_DIR/csv-ref" "$TMP_DIR/csv-ref" 8 40)" == 8 ]] || assert_at $LINENO
ws=$(build csv-noquote "$V/compare/reference")
# Forget one quoting rule: fields with a leading space.
sed -i.bak "s/ || text.startsWith(' ')//" "$ws/src/csv.js"
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) < 8 else 1)' \
  "$(fuzz_passed csv-rfc4180 "$ws" "$TMP_DIR/csv-ref" 8 40)" || assert_at $LINENO

# ── Performance ──────────────────────────────────────────────────────────────

# Timing is too noisy on a shared runner to assert a ratio; assert that every
# workload runs against its reference and produces one.
for pair in buggy-code-fix:bcf-ref oss-bug-triage:oss-ref long-refactor-inheritance:lr-seed cli-todo-app:cli-ref \
  inventory-race:inv-ref csv-rfc4180:csv-ref; do
  scenario="${pair%%:*}" ws="$TMP_DIR/${pair#*:}"
  node "$ROOT/research/compare/js/perf-runner.js" "$SCENARIOS/$scenario/compare/perf.js" "$ws" "$ws" 2 > "$TMP_DIR/perf.json"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["errors"] == 0 and d["geomean_ratio"] > 0, d
assert all(w["ratio"] > 0 for w in d["workloads"]), d
' "$TMP_DIR/perf.json" || { echo "perf workloads failed for $scenario" >&2; assert_at $LINENO; }
done

# ── Quality dimensions ───────────────────────────────────────────────────────

# The dimensions that need no network: the suite, CLI conventions and docs.
ws=$(build cli-quality "$C/compare/reference")
cat > "$ws/README.md" <<'EOF'
# Todo

```bash
node index.js add "Buy milk"
node index.js list
node index.js complete 42   # errors: no such todo
node index.js explode
```
EOF
python3 "$ROOT/research/compare/quality.py" measure --scenario-dir "$C" --ws "$ws" \
  --out "$TMP_DIR/quality.json" --skip deps,static,duplication,perf,fuzz
python3 - "$TMP_DIR/quality.json" <<'PY2'
import json
import sys

q = json.load(open(sys.argv[1]))
suite = q["suite"]
assert suite["runs"] == 5 and suite["passes"] == 5 and suite["flaky"] is False, suite
cli = q["cli"]
failed = [c["check"] for c in cli["checks"] if not c["ok"]]
# The reference's unknown-command error does not name the command; nothing else fails.
assert failed == ["frobnicate: message names 'frobnicate'"], failed
docs = q["docs"]
# Three commands succeed (the expected error counts as success); `explode` is unknown and fails.
assert docs["readme"] and docs["samples"] == 4 and docs["passed"] == 3, docs
assert q["static"] is None and "static" in q["skipped"], q["skipped"]
PY2

# ── Judge ────────────────────────────────────────────────────────────────────

PYTHONPATH="$ROOT/research/compare" python3 - <<'PY2'
import judge

# A criterion counts for an arm only when both orderings pick it.
assert judge.combine("dex", "dex") == "dex"
assert judge.combine("dex", "bare") == "tie"
assert judge.combine(None, None) == "tie"
assert judge.to_arm("A", "bare", "dex") == "bare" and judge.to_arm("B", "bare", "dex") == "dex"
assert judge.valid_choice("C") is None
assert judge.parse_json('noise {"overall": "A"} more') == {"overall": "A"}
PY2

# ── Improvement-loop objective ───────────────────────────────────────────────

PYTHONPATH="$ROOT/research/compare" python3 - <<'PY2'
import objective

base = {"s": {"hidden_all": 0.9, "fuzz_pass": 1.0, "fu_success": 1.0, "cost_usd": 2.0, "lines": 400, "mutation_score": 0.8, "n": 3}}
# Same quality for less cost and code: keep.
keep, bad, good = objective.verdict(base, {"s": dict(base["s"], cost_usd=1.2, lines=250)})
assert keep and good and not bad, (keep, bad, good)
# Cheaper but less correct: revert, whatever the savings.
keep, bad, _ = objective.verdict(base, {"s": dict(base["s"], hidden_all=0.8, cost_usd=0.2)})
assert not keep and "hidden tests fell" in bad[0], bad
# More code for the same quality: revert (no measured gain).
keep, bad, _ = objective.verdict(base, {"s": dict(base["s"], lines=900)})
assert not keep and "no measured gain" in bad[0], bad
# Fuzz agreement falling is a regression even when hidden tests hold.
keep, bad, _ = objective.verdict(base, {"s": dict(base["s"], fuzz_pass=0.8)})
assert not keep and "fuzz" in bad[0], bad
# A scenario that stopped being measured is not an improvement.
keep, bad, _ = objective.verdict({"s": base["s"], "t": base["s"]}, base)
assert not keep and "not now" in bad[0], bad
PY2

# ── Report ───────────────────────────────────────────────────────────────────

RUN="$TMP_DIR/run"
for arm in bare dex; do
  t="$RUN/trials/t-$arm"
  mkdir -p "$t"
  spec=1
  [[ "$arm" == dex ]] && spec=2
  printf '{"trial_id":"t-%s","arm":"%s","scenario":"s1","replica":1,"exit_code":0,"wall_seconds":60}\n' "$arm" "$arm" > "$t/meta.json"
  printf '{"usage":{"has_result":true,"cost_usd":1.0,"tokens":{"total":1000,"output":10},"num_turns":4},"hidden":{"groups":{"spec":{"passed":%s,"total":2}}},"own_tests":{"pass":true}}\n' "$spec" > "$t/main.json"
done
printf '{"perf":{"geomean_ratio":1.0,"workloads":[{"cv":0.1}]},"fuzz":{"pass_rate":1.0}}\n' > "$RUN/trials/t-bare/quality.json"
printf '{"perf":{"geomean_ratio":2.0,"workloads":[{"cv":0.1}]},"fuzz":{"pass_rate":0.5}}\n' > "$RUN/trials/t-dex/quality.json"
printf '{"provider":"claude","same_family_as_arms":true,"pairs":{"s1:t-bare:t-dex":{"scenario":"s1","combined":{"overall":"dex","position_consistent":true,"criteria":{"correctness":"tie"}}}},"accuracy":{"t-bare":{"rating":2},"t-dex":{"rating":1}}}\n' > "$RUN/judge.json"
printf 't-bare\tbare\ts1\t1\nt-dex\tdex\ts1\t1\n' > "$RUN/trials.tsv"
python3 "$ROOT/research/compare/report.py" "$RUN" > "$TMP_DIR/report.out"
assert_contains "| Hidden tests: spec | 50% | 100% | +50pp |" "$TMP_DIR/report.out"
assert_contains "Trials: 2 of 2 finished" "$TMP_DIR/report.out"
assert_contains "| Time vs reference (geomean) | 1.00x | 2.00x | +1.00x |" "$TMP_DIR/report.out"
assert_contains "| Fuzz sequences agreeing with reference | 100% | 50% | -50pp |" "$TMP_DIR/report.out"
assert_contains "| Closing report accuracy (judge) | 100% | 50% | -50pp |" "$TMP_DIR/report.out"
assert_contains "| overall | dex 1 · tie 0 · bare 0 |" "$TMP_DIR/report.out"
assert_file "$RUN/summary.json"
python3 "$ROOT/research/compare/objective.py" --smoke "$RUN" || assert_at $LINENO
python3 "$ROOT/research/compare/evidence.py" "$RUN" --arm dex > "$TMP_DIR/evidence.out"
assert_contains "## Outcomes for the \`dex\` arm" "$TMP_DIR/evidence.out"

printf 'research compare tests passed\n'
