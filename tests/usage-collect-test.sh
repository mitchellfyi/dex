#!/usr/bin/env bash
set -euo pipefail

# scripts/usage_collect.py turns Claude Code transcript JSONL into one usage
# record per request. Every assistant line of one request repeats the same
# usage block, so the collector must count a request once; it must add the
# provider's exclusive input fields rather than double-count cached input;
# it must attribute subagent transcripts to their agent; and it must say when a
# transcript is incomplete instead of reporting a clean total.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
FIX="$ROOT/tests/fixtures/usage"
COLLECT="$ROOT/scripts/usage_collect.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-usage-collect-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# jget <json-file> <python expression over d>
jget() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

[[ -f "$COLLECT" ]] || assert_at $LINENO

# Duplicate lines for one requestId count once; totals are first-per-request.
python3 "$COLLECT" "$FIX/dup-request.jsonl" > "$TMP_DIR/dup.json"
[[ "$(jget "$TMP_DIR/dup.json" 'd["schema_version"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["requests"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["duplicate_lines_skipped"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["totals"]["input_tokens"]')" == "2002" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["totals"]["cache_creation_input_tokens"]')" == "1000" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["totals"]["cache_read_input_tokens"]')" == "8500" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["totals"]["output_tokens"]')" == "60" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["totals"]["thinking_tokens"]')" == "3" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["complete"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["usage_schema"]')" == "anthropic-exclusive" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/dup.json" 'd["by_model"]["model-x"]["requests"]')" == "2" ]] || assert_at $LINENO

# Anthropic's input_tokens excludes cached input: 2000 fresh + 8000 cached is a
# 10,000-token prompt, not 18,000.
python3 "$COLLECT" "$FIX/exclusive-schema.jsonl" > "$TMP_DIR/excl.json"
[[ "$(jget "$TMP_DIR/excl.json" 'd["totals"]["prompt_tokens_total"]')" == "10000" ]] || assert_at $LINENO

# A request with no usage block stays visible as unknown, never zero-filled.
python3 "$COLLECT" "$FIX/missing-usage.jsonl" > "$TMP_DIR/missing.json"
[[ "$(jget "$TMP_DIR/missing.json" 'd["requests"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/missing.json" 'd["requests_without_usage"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/missing.json" 'd["totals"]["output_tokens"]')" == "10" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/missing.json" 'd["complete"]')" == "False" ]] || assert_at $LINENO

# A truncated tail (transcripts are written asynchronously) marks the record
# incomplete and counts the malformed line, keeping the valid totals.
python3 "$COLLECT" "$FIX/truncated.jsonl" > "$TMP_DIR/trunc.json"
[[ "$(jget "$TMP_DIR/trunc.json" 'd["complete"]')" == "False" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/trunc.json" 'd["malformed_lines"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/trunc.json" 'd["totals"]["output_tokens"]')" == "10" ]] || assert_at $LINENO

# Subagent transcripts are attributed to their agent id and type, and the
# session total includes them.
python3 "$COLLECT" "$FIX/with-subagents/main.jsonl" --subagents "$FIX/with-subagents/subagents" > "$TMP_DIR/sub.json"
[[ "$(jget "$TMP_DIR/sub.json" 'd["by_agent"]["main"]["output_tokens"]')" == "10" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/sub.json" 'd["by_agent"]["abc"]["output_tokens"]')" == "50" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/sub.json" 'd["by_agent"]["abc"]["agent_type"]')" == "dx-implementer" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/sub.json" 'd["totals"]["output_tokens"]')" == "60" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/sub.json" 'd["by_model"]["model-y"]["requests"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/sub.json" 'len(d["sources"])')" == "2" ]] || assert_at $LINENO

# Provenance says what was measured and how.
[[ "$(jget "$TMP_DIR/sub.json" 'd["provenance"]["measurement"]')" == "observed" ]] || assert_at $LINENO

# Pure helpers for other collectors. A cumulative counter stream folds to its
# last reading, a second stream adds, and a decrease is flagged rather than
# summed or ignored. Overlapping spans union to wall time, not to their sum.
PYTHONPATH="$ROOT/scripts" python3 - <<'PY'
import usage_collect as uc
value, flags = uc.fold_cumulative([100, 160, 160])
assert (value, flags) == (160, []), (value, flags)
total, flags = uc.fold_streams({"a": [100, 160, 160], "b": [20]})
assert (total, flags) == (180, []), (total, flags)
value, flags = uc.fold_cumulative([100, 160, 40])
assert value == 160 and flags == ["decrease_at_index_2"], (value, flags)
assert uc.span_union([(0, 120), (0, 120)]) == 120
assert uc.span_sum([(0, 120), (0, 120)]) == 240
assert uc.span_union([(0, 120), (60, 200), (300, 310)]) == 210
PY

echo "usage-collect-test: ok"
