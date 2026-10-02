#!/usr/bin/env bash
# The critical review between `validated` and `activate`.
#
#   consume-review.sh <package-dir> <baseline-runtime-dir> <candidate-dir> <out.json>
#
# The deterministic evaluator shows that a patch applies inside the allowlist
# and flips its reproduction check. It cannot say whether the change is
# general, correct, or worth the context it will cost every future session.
# A fresh bounded model session answers that. It gets the candidate's
# manifest, evidence summary and metrics, the unified diff, and the full text
# of each changed file as it reads with the patch applied, plus read-only
# tools (Read, Grep, Glob) over the candidate runtime, which is its working
# directory, so it can check what the rest of Dex already says. The bar is in
# the prompt: the change earns its keep only if a future Dex session would
# behave better for it on more than the one incident that produced it.
#
# The answer must hold exactly one fenced ```json block:
#   {"decision": "approve|reject", "reason": "…", "risks": […], "generality": "one-off|repo|dex-wide"}
# which is normalised and written to <out.json>; the prompt and the raw answer
# are kept beside it. The model runs under dx_run_with_timeout, which
# backgrounds its command, so stdin would be /dev/null: a child reopens stdin
# from the prompt file before exec'ing the model.
#
# DX_CONSUME_CLAUDE_BIN replaces the binary (the tests use a stub);
# DX_CONSUME_MODEL_TIMEOUT bounds the call in seconds (600).
#
# Exit 0 with a decision; 2 usage; 1 when the call failed, the answer held no
# single json block, the decision was unknown, or the reason was missing.
set -euo pipefail

DEX_DIR="${DEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DEX_DIR
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"

usage() {
  echo "Usage: consume-review.sh <package-dir> <baseline-runtime-dir> <candidate-dir> <out.json>" >&2
  exit 2
}
[[ $# -eq 4 ]] || usage
PACKAGE="$1" BASELINE="$2" CANDIDATE="$3" OUT="$4"
CLAUDE_BIN="${DX_CONSUME_CLAUDE_BIN:-claude}"
MODEL_TIMEOUT="${DX_CONSUME_MODEL_TIMEOUT:-600}"
[[ -f "$PACKAGE/manifest.json" && -f "$PACKAGE/evidence-summary.md" && -f "$PACKAGE/proposed-change.patch" ]] \
  || { echo "consume-review: $PACKAGE is not a candidate package with a patch" >&2; exit 2; }
[[ -d "$BASELINE" && -d "$CANDIDATE" ]] \
  || { echo "consume-review: baseline and candidate runtimes are required" >&2; exit 2; }
[[ "$MODEL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || { echo "consume-review: DX_CONSUME_MODEL_TIMEOUT must be a positive integer" >&2; exit 2; }
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "consume-review: $CLAUDE_BIN is not on PATH" >&2; exit 2; }

PROMPT_FILE="$OUT.prompt"
ANSWER_FILE="$OUT.answer"
CHANGED_FILE="$OUT.changed"
rm -f "$OUT" "$PROMPT_FILE" "$ANSWER_FILE" "$CHANGED_FILE"
# The changed paths come from the patch itself, as the consumer judged them.
if grep -q '^+++ b/' "$PACKAGE/proposed-change.patch"; then STRIP=1; else STRIP=0; fi
(cd "$CANDIDATE" && git apply --numstat "-p$STRIP" "$PACKAGE/proposed-change.patch" 2>/dev/null \
  | awk -F'\t' '{print $3}') > "$CHANGED_FILE" || true

python3 - "$PACKAGE" "$CANDIDATE" "$CHANGED_FILE" "$PROMPT_FILE" <<'PY'
import json
import os
import sys

package, candidate, changed_file, prompt_path = sys.argv[1:5]


def read(path, limit):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    if len(text) > limit:
        return text[:limit] + f"\n[truncated at {limit} of {len(text)} characters]"
    return text


with open(os.path.join(package, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
evidence = read(os.path.join(package, "evidence-summary.md"), 6000).strip()
metrics_path = os.path.join(package, "metrics.json")
metrics = read(metrics_path, 2000).strip() if os.path.isfile(metrics_path) else "{}"
patch = read(os.path.join(package, "proposed-change.patch"), 20000)
with open(changed_file, encoding="utf-8") as handle:
    changed = [line.strip() for line in handle if line.strip()]

lines = [
    "You are the critical reviewer for a change to Dex, the workflow framework these sessions run "
    "under. A project reported a problem; a deterministic evaluator confirmed that this patch applies "
    "inside the allowed paths (prompts/**/*.md, skills/*/SKILL.md) and that the problem's reproduction "
    "check fails without it and passes with it. If you approve, the patch is applied to the live Dex "
    "checkout, unstaged, and every future session reads it. Nothing else reviews it.",
    "",
    "The bar: the change earns its keep only if a future Dex session would behave better for it on "
    "more than the one incident that produced it. Reject:",
    "- prose that restates what the file already says;",
    "- anything that narrows or contradicts an existing rule without saying so;",
    "- anything specific to one repository, one host or one incident;",
    "- anything a reader could not check against the runtime or a later session's behaviour.",
    "Approve only a change that is general, correct as written, and worth the context it costs on "
    "every read of that file.",
    "",
    "What you can see: the report, the evidence summary and metrics the reporter left, the diff, and "
    "the changed files as they read with the patch applied. Your working directory is the candidate "
    "runtime with the patch applied; read other files there (prompts/, skills/, lib/) to check whether "
    "the rule already exists or conflicts with one. You cannot see the incident itself, the project "
    "that reported it, or how later sessions behave; judge the text against the evidence.",
    "",
    "Problem report:",
]
for key in ("mechanism", "symptom", "impact", "suspected_cause", "candidate_mechanism", "applicability", "exclusions"):
    value = str(manifest.get(key) or "").strip()
    if value:
        lines.append(f"- {key.replace('_', ' ')}: {value}")
lines += [f"- support: {manifest.get('support', 1)} report(s); origin {manifest.get('origin', 'project')}", ""]
lines += ["Evidence summary:", evidence, "", "Metrics:", metrics, "", "Unified diff:", "```diff", patch.rstrip("\n"), "```", ""]
for rel in changed:
    target = os.path.join(candidate, rel)
    if os.path.isfile(target):
        lines += [f"Full text of {rel} with the patch applied:", "```", read(target, 30000).rstrip("\n"), "```", ""]
    else:
        lines += [f"{rel} is not present in the candidate runtime.", ""]
lines += [
    "Answer with exactly one fenced ```json block and nothing else in a code block:",
    '{"decision": "approve" | "reject", "reason": "one or two sentences a person can act on", '
    '"risks": ["each specific risk, or an empty list"], "generality": "one-off" | "repo" | "dex-wide"}',
    "A sentence or two of reasoning outside the block is fine. When in doubt, reject and say what "
    "evidence would change your mind.",
]
with open(prompt_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY

export DX_REVIEW_PROMPT_FILE="$PROMPT_FILE"
if ! (cd "$CANDIDATE" && dx_run_with_timeout "$MODEL_TIMEOUT" \
    bash -c 'exec "$@" < "$DX_REVIEW_PROMPT_FILE"' _ \
    "$CLAUDE_BIN" -p --output-format text --max-turns 4 \
    --allowedTools "Read,Grep,Glob" --disallowedTools "Edit,Write,NotebookEdit,Bash,Agent" \
    --setting-sources "project,local" --strict-mcp-config \
    > "$ANSWER_FILE" 2> "$OUT.err"); then
  echo "consume-review: model call failed: $(head -c 300 "$OUT.err" | tr '\n' ' ')" >&2
  exit 1
fi

if ! python3 - "$ANSWER_FILE" "$OUT" "$PROMPT_FILE" "$CHANGED_FILE" <<'PY'
import json
import re
import sys

answer_path, out_path, prompt_path, changed_file = sys.argv[1:5]
with open(answer_path, encoding="utf-8", errors="replace") as handle:
    text = handle.read()
blocks = re.findall(r"^```json[ \t]*\n(.*?)\n```[ \t]*$", text, re.S | re.M)
if len(blocks) != 1:
    print(f"consume-review: expected exactly one fenced json block, found {len(blocks)}", file=sys.stderr)
    sys.exit(1)
try:
    data = json.loads(blocks[0])
except ValueError as error:
    print(f"consume-review: the json block does not parse: {error}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("consume-review: the json block is not an object", file=sys.stderr)
    sys.exit(1)
decision = str(data.get("decision", "")).strip().lower()
if decision not in ("approve", "reject"):
    print(f"consume-review: unknown decision {decision!r}", file=sys.stderr)
    sys.exit(1)
reason = str(data.get("reason", "")).strip()
if not reason:
    print("consume-review: the decision carries no reason", file=sys.stderr)
    sys.exit(1)
risks = data.get("risks", [])
if not isinstance(risks, list):
    risks = [risks] if risks else []
generality = str(data.get("generality", "")).strip().lower()
if generality not in ("one-off", "repo", "dex-wide"):
    generality = "unspecified"
with open(changed_file, encoding="utf-8") as handle:
    changed = [line.strip() for line in handle if line.strip()]
record = {
    "decision": decision, "reason": reason[:1000], "risks": [str(risk)[:300] for risk in risks][:20],
    "generality": generality, "changed_paths": changed, "answer": answer_path, "prompt": prompt_path,
}
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=1, sort_keys=True)
print(json.dumps({"decision": decision, "generality": generality}))
PY
then
  exit 1
fi
