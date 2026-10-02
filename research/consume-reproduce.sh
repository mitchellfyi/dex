#!/usr/bin/env bash
# Ask the model for the reproduction a captured candidate lacks.
#
#   consume-reproduce.sh <package-dir> <baseline-runtime-dir> <out-check.sh>
#
# The package's manifest.json and evidence-summary.md become one prompt. The
# model runs in print mode with at most four turns, project and local settings
# only and no MCP servers, with the sealed baseline runtime as its working
# directory so what it reads is the pinned Dex. It must answer with exactly one
# fenced ```bash block: a check that exits non-zero on a runtime where the
# described problem is present and 0 where it is absent. That block is written
# to <out-check.sh> (mode 0700) once it parses and names nothing on the
# denylist below. Nothing here runs the check; research/consume.sh does, on
# both runtimes. The raw answer is kept at <out-check.sh>.answer.
#
# DX_CONSUME_CLAUDE_BIN replaces the binary (the tests use a stub that prints a
# fixed answer). DX_CONSUME_MODEL_TIMEOUT bounds the call in seconds (600).
#
# Exit 0 ok; 2 usage; 3 no usable script (the call failed, the answer did not
# hold one bash block, the script did not parse, or it reached for something
# the denylist names).
set -euo pipefail

usage() {
  echo "Usage: consume-reproduce.sh <package-dir> <baseline-runtime-dir> <out-check.sh>" >&2
  exit 2
}
[[ $# -eq 3 ]] || usage
PACKAGE="$1" BASELINE="$2" OUT="$3"
CLAUDE_BIN="${DX_CONSUME_CLAUDE_BIN:-claude}"
MODEL_TIMEOUT="${DX_CONSUME_MODEL_TIMEOUT:-600}"
MAX_TURNS="${DX_CONSUME_REPRODUCE_MAX_TURNS:-12}"
[[ "$MAX_TURNS" =~ ^[1-9][0-9]{0,2}$ ]] \
  || { echo "consume-reproduce: DX_CONSUME_REPRODUCE_MAX_TURNS must be a positive integer" >&2; exit 2; }
[[ -f "$PACKAGE/evidence-summary.md" && -f "$PACKAGE/manifest.json" ]] \
  || { echo "consume-reproduce: $PACKAGE is not a candidate package" >&2; exit 2; }
[[ -d "$BASELINE" ]] || { echo "consume-reproduce: no baseline runtime at $BASELINE" >&2; exit 2; }
[[ "$MODEL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || { echo "consume-reproduce: DX_CONSUME_MODEL_TIMEOUT must be a positive integer" >&2; exit 2; }
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "consume-reproduce: $CLAUDE_BIN is not on PATH" >&2; exit 2; }

# Read into a variable first: macOS bash 3.2 scans a heredoc inside $( … ) for
# backticks, and the ``` in this prompt left one unmatched.
read -r -d '' PROMPT_SCRIPT <<'PY' || true
import json
import os
import sys

package = sys.argv[1]
with open(os.path.join(package, "manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
with open(os.path.join(package, "evidence-summary.md"), encoding="utf-8") as handle:
    evidence = handle.read().strip()
lines = [
    "You are writing a reproduction check for the Dex research consumer. Dex is a shell and "
    "Python workflow framework; a runtime directory holds its dx.sh, settings.json, bin/, hooks/, "
    "lib/, prompts/, scripts/ and skills/.",
    "",
    "Problem report:",
]
for key in ("mechanism", "symptom", "impact", "suspected_cause", "candidate_mechanism", "applicability", "exclusions"):
    value = str(manifest.get(key) or "").strip()
    if value:
        lines.append(f"- {key.replace('_', ' ')}: {value}")
lines += ["", "Evidence summary:", evidence[:6000], ""]
lines += [
    "Write one bash script that decides whether this problem is present in a Dex runtime directory.",
    "Contract:",
    "- DEX_DIR is set to the runtime directory and it is the working directory. Exit non-zero when "
    "the problem is present there; exit 0 when it is absent. Decide only from what the runtime "
    "shows; never guess.",
    "- Read-only. Read files under $DEX_DIR and run its scripts only with inputs you build under a "
    "`mktemp -d` directory that you remove at the end. Never modify $DEX_DIR, never use the network, "
    "never call git, sudo, rm -r outside your temp directory, or another model.",
    "- Finish within 60 seconds using bash, coreutils, grep, sed, awk and python3 only. Nothing interactive.",
    "You may read files in the current directory first to find the exact text or behaviour to check.",
    "Answer with exactly one fenced ```bash code block holding the whole script, starting with "
    "#!/usr/bin/env bash and set -euo pipefail. Put nothing else in a code block; a sentence of "
    "explanation outside it is fine.",
]
print("\n".join(lines))
PY
PROMPT=$(python3 -c "$PROMPT_SCRIPT" "$PACKAGE")

ANSWER="$OUT.answer"
rm -f "$ANSWER" "$OUT"
# The timeout is enforced from Python: macOS ships no `timeout`.
if ! (cd "$BASELINE" && python3 - "$CLAUDE_BIN" "$MODEL_TIMEOUT" "$ANSWER" "$PROMPT" "$MAX_TURNS" <<'PY'
import subprocess
import sys

binary, timeout, answer_path, prompt, max_turns = sys.argv[1:6]
# Read-only tools, granted up front: without them every Read is denied in
# print mode and the model burns its turns asking. The live run that hit
# "Reached max turns (4)" is why the cap is higher and configurable.
command = [binary, "-p", "--max-turns", max_turns,
           "--allowedTools", "Read,Grep,Glob",
           "--disallowedTools", "Edit,Write,NotebookEdit,Bash,Agent",
           "--setting-sources", "project,local",
           "--strict-mcp-config", "--output-format", "text", prompt]
try:
    completed = subprocess.run(command, timeout=int(timeout), capture_output=True, text=True,
                               stdin=subprocess.DEVNULL, check=False)
except subprocess.TimeoutExpired:
    print(f"model call exceeded {timeout}s", file=sys.stderr)
    sys.exit(124)
with open(answer_path, "w", encoding="utf-8") as handle:
    handle.write(completed.stdout)
if completed.returncode != 0:
    print(completed.stderr.strip()[-600:], file=sys.stderr)
    sys.exit(completed.returncode)
PY
); then
  echo "consume-reproduce: model call failed" >&2
  exit 3
fi

# The deterministic floor under what the model wrote: one block, it parses,
# and it reaches for nothing outside the runtime and its own temp directory.
if ! python3 - "$ANSWER" "$OUT" <<'PY'
import os
import re
import sys

answer_path, out_path = sys.argv[1:3]
with open(answer_path, encoding="utf-8", errors="replace") as handle:
    text = handle.read()
blocks = re.findall(r"^```(?:bash|sh)[ \t]*\n(.*?)\n```[ \t]*$", text, re.S | re.M)
if len(blocks) != 1:
    print(f"consume-reproduce: expected exactly one fenced bash block, found {len(blocks)}", file=sys.stderr)
    sys.exit(3)
body = blocks[0].strip("\n") + "\n"
if not body.startswith("#!"):
    body = "#!/usr/bin/env bash\nset -euo pipefail\n" + body
# The denylist reads commands, not text. A reproduction of a parser bug has
# to carry the offending text as data (a quoted heredoc that says
# `git commit`), and a sandboxed init needs a stub file named `curl`; the
# first live run refused both. Heredoc bodies and comments are removed with
# the parser the guards share, and a denied word only counts in command
# position. Anything the parser cannot read is refused.
sys.path.insert(0, os.path.join(os.environ.get("DEX_DIR", ""), "hooks"))
try:
    from shell_parse import strip_heredoc_bodies
except ImportError:
    print("consume-reproduce: hooks/shell_parse.py is not importable; refused", file=sys.stderr)
    sys.exit(3)
try:
    stripped = strip_heredoc_bodies(body)
    code = stripped[0] if isinstance(stripped, tuple) else stripped
except Exception as error:  # noqa: BLE001 - fail closed on anything the parser rejects
    print(f"consume-reproduce: the script could not be parsed ({error}); refused", file=sys.stderr)
    sys.exit(3)
code = "\n".join(line for line in code.splitlines() if not line.lstrip().startswith("#"))
# Command position: the start of a line or of a pipeline/list element, a
# substitution, or after a keyword that introduces a command.
POS = r"(?:(?<=^)|(?<=[;&|(`{])|(?<=\$\()|(?<=\bthen\s)|(?<=\bdo\s)|(?<=\belse\s)|(?<=\bexec\s)|(?<=\beval\s))\s*"
denied = [
    (POS + r"sudo\b", "sudo"),
    (POS + r"(?:env\s+(?:[A-Z_][A-Z0-9_]*=\S*\s+)*)?(curl|wget|ssh|scp|nc|ncat|telnet)\b", "network access"),
    (POS + r"git\s+(?:-C\s+\S+\s+)?(push|commit|reset|checkout|clean|stash|rebase|merge|tag|branch|am|apply)\b", "a git mutation"),
    (POS + r"rm\s+-[a-zA-Z]*[rRf][a-zA-Z]*\s+(/|~|\"?\$\{?HOME|\"?\$\{?DEX_DIR)", "rm -r outside its temp directory"),
    (POS + r"(mkfs|dd)\b|>\s*/dev/(sd|disk|nvme)", "a device write"),
    (POS + r"chmod\s+-R\b|" + POS + r"chown\b", "a recursive mode change"),
    (POS + r"(claude|codex)\b", "another model"),
]
for pattern, label in denied:
    match = re.search(pattern, code, flags=re.M)
    if match:
        print(f"consume-reproduce: the script uses {label} ({match.group(0).strip()!r}); refused", file=sys.stderr)
        sys.exit(3)
descriptor = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    handle.write(body)
os.chmod(out_path, 0o700)
PY
then
  rm -f "$OUT"
  exit 3
fi
bash -n "$OUT" >/dev/null 2>&1 || { echo "consume-reproduce: the model's script does not parse" >&2; rm -f "$OUT"; exit 3; }
printf '{"check": "%s", "answer": "%s"}\n' "$OUT" "$ANSWER"
