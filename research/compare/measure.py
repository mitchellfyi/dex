#!/usr/bin/env python3
"""Measure one finished workspace for the arm comparison.

Every subcommand works on a disposable copy of the workspace: it stages all
changes in the copy's git index, installs dependencies, runs tests and mutates
source files in place (restoring them afterwards). trial.sh makes the copy.

  measure.py main     --scenario-dir D --ws W --baseline SHA --stream S --out O [--exclude F ...]
  measure.py followup --scenario-dir D --ws W --baseline SHA --stream S --out O
  measure.py hidden   --scenario-dir D --ws W [--followup]
  measure.py mutate   --scenario-dir D --ws W

The metrics are outcomes, not process: what hidden tests say about the code,
how many planted bugs the agent's own tests catch, how large the change is,
whether the agent's closing claim matches its test suite, and what it cost.
"""

import argparse
import fnmatch
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

DEFAULT_DIFF_EXCLUDE = [
    "package-lock.json",
    "npm-shrinkwrap.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    ".DS_Store",
]
DEFAULT_MUTATION_EXCLUDE = [
    "node_modules/*",
    "tests/*",
    "test/*",
    "__tests__/*",
    "spec/*",
    "coverage/*",
    "*.test.*",
    "*.spec.*",
    "*.config.*",
    ".eslintrc*",
]
NPM_DEFAULT_TEST = 'echo "Error: no test specified" && exit 1'
TEST_TIMEOUT_S = 600
MUTANT_TIMEOUT_S = 120
MUTATION_BUDGET_S = 1200


# ── Helpers ──────────────────────────────────────────────────────────────────


def run(cmd, cwd, timeout, env=None):
    """Run a command; return (exit_code, output, seconds). 124 means timeout.

    The command gets its own process group, and a timeout kills the whole
    group. Killing only the direct child is not enough: `npm test` starts node,
    node starts test workers, and a mutant that loops forever keeps those
    running at full CPU long after npm is gone.
    """
    started = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        start_new_session=True,
    )
    try:
        out, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        kill_group(proc)
        out, _ = proc.communicate()
        code = 124
    finally:
        # A command that exited normally can still leave background children
        # in its group; stop them too.
        kill_group(proc)
    return code, out or "", time.monotonic() - started


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def load_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def matches(path, patterns):
    return any(fnmatch.fnmatch(path, pattern) for pattern in patterns)


def compare_config(scenario_dir):
    return load_json(os.path.join(scenario_dir, "compare", "compare.json"), {}) or {}


def tail(text, lines=40):
    return "\n".join((text or "").splitlines()[-lines:])


# ── Agent usage ──────────────────────────────────────────────────────────────


def agent_usage(stream_path):
    """Cost, tokens, turns and tool calls from a Claude stream-json log.

    The final `result` event carries the session totals. A run killed by the
    timeout never writes one, so fall back to summing per-message usage, which
    has tokens but no dollar cost.
    """
    usage = {
        "has_result": False,
        "model": None,
        "claude_code_version": None,
        "result_subtype": None,
        "is_error": None,
        "cost_usd": None,
        "num_turns": None,
        "duration_ms": None,
        "duration_api_ms": None,
        "tokens": {},
        "model_usage": {},
        "tool_calls": {},
        "final_text": "",
        # The dex-loop arm records hook events: each audit the Stop hook
        # injects is a blocking response (exit 2); completion says so.
        "stop_hook_blocks": 0,
        "loop_completed": False,
    }
    if not stream_path or not os.path.exists(stream_path):
        return usage

    per_message = {}
    seen_tools = set()
    last_text = ""
    with open(stream_path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind == "system" and event.get("subtype") == "init":
                usage["model"] = event.get("model")
                usage["claude_code_version"] = event.get("claude_code_version")
                usage["plugins"] = [p.get("name") for p in event.get("plugins") or []]
                usage["mcp_servers"] = [m.get("name") for m in event.get("mcp_servers") or []]
            elif kind == "system" and event.get("subtype") == "hook_response" and event.get("hook_event") == "Stop":
                if str(event.get("exit_code")) == "2":
                    usage["stop_hook_blocks"] += 1
                if "Dex loop complete" in (event.get("stdout") or event.get("output") or ""):
                    usage["loop_completed"] = True
            elif kind == "assistant":
                message = event.get("message") or {}
                if message.get("id") and message.get("usage"):
                    per_message[message["id"]] = message["usage"]
                texts = []
                for block in message.get("content") or []:
                    if block.get("type") == "tool_use" and block.get("id") not in seen_tools:
                        seen_tools.add(block.get("id"))
                        name = block.get("name") or "?"
                        usage["tool_calls"][name] = usage["tool_calls"].get(name, 0) + 1
                    elif block.get("type") == "text":
                        texts.append(block.get("text") or "")
                if texts:
                    last_text = "\n".join(texts)
            elif kind == "result":
                usage["has_result"] = True
                usage["result_subtype"] = event.get("subtype")
                usage["is_error"] = event.get("is_error")
                usage["cost_usd"] = event.get("total_cost_usd")
                usage["num_turns"] = event.get("num_turns")
                usage["duration_ms"] = event.get("duration_ms")
                usage["duration_api_ms"] = event.get("duration_api_ms")
                usage["tokens"] = token_totals(event.get("usage") or {})
                usage["model_usage"] = event.get("modelUsage") or {}
                usage["final_text"] = event.get("result") or last_text

    if not usage["has_result"]:
        summed = {}
        for message_usage in per_message.values():
            for key, value in token_totals(message_usage).items():
                summed[key] = summed.get(key, 0) + value
        usage["tokens"] = summed
        usage["final_text"] = last_text
    # modelUsage holds per-model totals including subagents; prefer it when
    # present, since the top-level usage can omit a subagent's tokens.
    if usage["model_usage"]:
        summed = {}
        for model_usage in usage["model_usage"].values():
            for key, value in token_totals(model_usage).items():
                summed[key] = summed.get(key, 0) + value
        if summed.get("total", 0) >= usage["tokens"].get("total", 0):
            usage["tokens"] = summed
    return usage


def token_totals(raw):
    def pick(*names):
        for name in names:
            value = raw.get(name)
            if isinstance(value, (int, float)):
                return int(value)
        return 0

    totals = {
        "input": pick("input_tokens", "inputTokens"),
        "output": pick("output_tokens", "outputTokens"),
        "cache_read": pick("cache_read_input_tokens", "cacheReadInputTokens"),
        "cache_creation": pick("cache_creation_input_tokens", "cacheCreationInputTokens"),
    }
    totals["total"] = sum(totals.values())
    return totals


# ── Claims ───────────────────────────────────────────────────────────────────

CLAIM_RE = re.compile(
    r"all\s+(?:\d+\s+)?(?:of\s+the\s+)?(?:tests?|specs?)\s+(?:are\s+|now\s+)*pass"
    r"|\btests?\s+(?:are\s+|all\s+|now\s+|still\s+)*(?:passing|pass(?:ed)?)\b"
    r"|\b(?:they|these|which)\s+(?:all\s+)?(?:now\s+)?pass\b"
    r"|\bpass(?:es|ed)?\s+all\s+(?:\d+\s+)?(?:of\s+the\s+)?(?:tests?|specs?)"
    r"|\ball\s+(?:\d+\s+)?(?:are\s+)?passing\b"
    r"|\b(\d+)\s*/\s*\1\s+(?:tests?\s+)?(?:pass|passing|passed)\b"
    r"|\b\d+\s+(?:tests?\s+)?(?:pass|passing|passed),?\s+0\s+fail"
    r"|\ball green\b",
    re.IGNORECASE,
)
NEGATION_RE = re.compile(r"\bnot\s+(?:all\s+)?pass|n't\s+pass|\bnot\s+passing", re.IGNORECASE)


def claims(final_text, own_tests_pass):
    """Did the closing message claim the tests pass, and were they right?"""
    text = final_text or ""
    match = CLAIM_RE.search(text)
    claimed = bool(match) and not NEGATION_RE.search(text)
    snippet = None
    if match:
        start = max(0, match.start() - 60)
        snippet = text[start : match.end() + 60].replace("\n", " ")
    return {
        "claims_tests_pass": claimed,
        "claim_snippet": snippet,
        "false_claim": bool(claimed and own_tests_pass is False),
    }


# ── Diff ─────────────────────────────────────────────────────────────────────

TEST_PATH_RE = re.compile(r"(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[cm]?[jt]sx?$")
CONFIG_NAMES = {
    "package.json",
    "tsconfig.json",
    ".gitignore",
    ".npmrc",
    ".nvmrc",
    ".editorconfig",
    ".prettierrc",
}


def path_category(path):
    base = os.path.basename(path)
    if TEST_PATH_RE.search(path):
        return "test"
    if base.lower().endswith((".md", ".txt", ".rst")):
        return "docs"
    if base in CONFIG_NAMES or base.startswith((".eslintrc", "eslint.config", "jest.config", ".prettierrc")):
        return "config"
    return "source"


def diff_stats(ws, baseline, exclude, scope):
    """Lines and files changed since the baseline commit, by category."""
    subprocess.run(["git", "-C", ws, "add", "-A"], check=False, capture_output=True)
    proc = subprocess.run(
        ["git", "-C", ws, "diff", "--cached", "--numstat", "-M", "-z", baseline],
        capture_output=True,
        text=True,
        errors="replace",
    )
    fields = proc.stdout.split("\0")
    entries = []
    i = 0
    while i < len(fields):
        head = fields[i]
        if not head:
            i += 1
            continue
        parts = head.split("\t")
        if len(parts) == 3 and parts[2] == "":
            # Rename: "added\tdeleted\t" then old path, new path.
            added, deleted = parts[0], parts[1]
            path = fields[i + 2] if i + 2 < len(fields) else fields[i + 1]
            i += 3
        else:
            added, deleted, path = parts[0], parts[1], parts[2] if len(parts) > 2 else ""
            i += 1
        entries.append((path, added, deleted))

    stats = {
        "files_changed": 0,
        "by_category": {},
        "binary_files": 0,
        "outside_scope": [],
        "forbidden_touched": [],
    }
    allowed = (scope or {}).get("allowed") or []
    forbidden = (scope or {}).get("forbidden") or []
    for path, added, deleted in entries:
        if matches(path, exclude):
            continue
        stats["files_changed"] += 1
        category = path_category(path)
        bucket = stats["by_category"].setdefault(category, {"files": 0, "added": 0, "deleted": 0})
        bucket["files"] += 1
        if added == "-" or deleted == "-":
            stats["binary_files"] += 1
            continue
        bucket["added"] += int(added)
        bucket["deleted"] += int(deleted)
        if allowed and not matches(path, allowed):
            stats["outside_scope"].append(path)
        if forbidden and matches(path, forbidden):
            stats["forbidden_touched"].append(path)
    for category in ("source", "test", "docs", "config"):
        stats["by_category"].setdefault(category, {"files": 0, "added": 0, "deleted": 0})
    stats["source_lines"] = stats["by_category"]["source"]["added"] + stats["by_category"]["source"]["deleted"]
    stats["test_lines"] = stats["by_category"]["test"]["added"] + stats["by_category"]["test"]["deleted"]
    stats["total_lines"] = sum(b["added"] + b["deleted"] for b in stats["by_category"].values())
    return stats


# ── Install and own tests ────────────────────────────────────────────────────


def package_json(ws):
    return load_json(os.path.join(ws, "package.json"), None)


def npm_install(ws):
    pkg = package_json(ws)
    if not pkg:
        return {"needed": False, "ok": None}
    if not (pkg.get("dependencies") or pkg.get("devDependencies")):
        return {"needed": False, "ok": True}
    code, out, secs = run(["npm", "install", "--no-audit", "--no-fund", "--loglevel=error"], ws, 600)
    return {"needed": True, "ok": code == 0, "seconds": round(secs, 1), "output_tail": tail(out, 15) if code else ""}


def test_command(ws):
    pkg = package_json(ws)
    script = ((pkg or {}).get("scripts") or {}).get("test")
    if not script or script.strip() == NPM_DEFAULT_TEST:
        return None
    return ["npm", "test", "--silent"]


def test_env():
    env = dict(os.environ)
    env.update({"CI": "1", "NO_COLOR": "1", "FORCE_COLOR": "0"})
    env.pop("BENCH_WS", None)
    return env


COUNT_PATTERNS = [
    # node:test summary
    (re.compile(r"^[#ℹ]\s*pass\s+(\d+)", re.M), re.compile(r"^[#ℹ]\s*fail\s+(\d+)", re.M)),
    # jest / vitest
    (re.compile(r"Tests:.*?(\d+) passed"), re.compile(r"Tests:.*?(\d+) failed")),
    # mocha
    (re.compile(r"(\d+) passing"), re.compile(r"(\d+) failing")),
]


def parse_counts(output):
    for pass_re, fail_re in COUNT_PATTERNS:
        passed = pass_re.findall(output)
        if passed:
            failed = fail_re.findall(output)
            return {"passed": sum(int(p) for p in passed), "failed": sum(int(f) for f in failed)}
    return None


def own_tests(ws):
    cmd = test_command(ws)
    if not cmd:
        return {"has_test_script": False, "pass": False}
    code, out, secs = run(cmd, ws, TEST_TIMEOUT_S, env=test_env())
    counts = parse_counts(out)
    zero_tests = counts is not None and counts["passed"] == 0 and counts["failed"] == 0
    return {
        "has_test_script": True,
        "exit_code": code,
        "pass": code == 0 and not zero_tests,
        "counts": counts,
        "seconds": round(secs, 1),
        "output_tail": tail(out) if code else "",
    }


# ── Hidden tests ─────────────────────────────────────────────────────────────

TAP_RE = re.compile(r"^(\s*)(not ok|ok) \d+ - (.*?)(?:\s+#\s*(SKIP|TODO)\b.*)?$")
GROUP_RE = re.compile(r"^\[(\w+)\]")


def hidden_dirs(scenario_dir, followup):
    base = os.path.join(scenario_dir, "compare")
    dirs = [os.path.join(base, "hidden")]
    if followup:
        dirs.append(os.path.join(base, "followup", "hidden"))
    return [d for d in dirs if os.path.isdir(d)]


def run_hidden(ws, dirs):
    """Stage the hidden suites outside the workspace and run them against it."""
    if not dirs:
        return None
    stage = tempfile.mkdtemp(prefix="bench-hidden-")
    try:
        for directory in dirs:
            for name in os.listdir(directory):
                src = os.path.join(directory, name)
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(stage, name))
        files = sorted(f for f in os.listdir(stage) if f.endswith(".test.js"))
        env = test_env()
        env["BENCH_WS"] = os.path.realpath(ws)
        cmd = ["node", "--test", "--test-reporter=tap", "--test-concurrency=1"] + files
        code, out, secs = run(cmd, stage, TEST_TIMEOUT_S, env=env)
    finally:
        shutil.rmtree(stage, ignore_errors=True)

    tests = {}
    load_errors = []
    for line in out.splitlines():
        match = TAP_RE.match(line)
        if not match:
            continue
        ok = match.group(2) == "ok"
        name = match.group(3).strip()
        if match.group(4):
            continue
        if GROUP_RE.match(name):
            tests[name] = ok
        elif not ok and name.endswith(".test.js"):
            load_errors.append(name)

    groups = {}
    for name, ok in tests.items():
        group = GROUP_RE.match(name).group(1)
        bucket = groups.setdefault(group, {"passed": 0, "total": 0})
        bucket["total"] += 1
        bucket["passed"] += int(ok)
    for bucket in groups.values():
        bucket["rate"] = round(bucket["passed"] / bucket["total"], 4) if bucket["total"] else None
    return {
        "exit_code": code,
        "seconds": round(secs, 1),
        "groups": groups,
        "failed": sorted(name for name, ok in tests.items() if not ok),
        "load_errors": load_errors,
        "output_tail": tail(out) if (load_errors or not tests) else "",
    }


# ── Mutation testing ─────────────────────────────────────────────────────────
#
# A small mutation tester for plain JavaScript, so no dependency has to be
# installed into the workspace. It tokenizes just enough (strings, template
# literals, comments, regex literals) to leave literals alone, then flips one
# operator per mutant and runs the agent's own test command. A mutant the
# tests fail on is "killed"; the score is the share killed.

OPERATORS = [
    ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
    "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=",
    "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>",
    "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "|", "^", "?", ":",
    ";", ",", ".", "(", ")", "[", "]", "{", "}", "@", "#",
]
FLIPS = {
    "===": "!==", "!==": "===", "==": "!=", "!=": "==",
    "<=": "<", ">=": ">", "<": "<=", ">": ">=",
    "&&": "||", "||": "&&",
    "+": "-", "-": "+", "*": "/", "/": "*",
    "!": "",
    "true": "false", "false": "true",
}
REGEX_AFTER_WORDS = {
    "return", "typeof", "case", "do", "else", "in", "of", "new", "delete",
    "void", "throw", "instanceof", "yield", "await",
}
REGEX_AFTER_PUNCT = set("(,=:[!&|?{};+-*%<>~^") | {
    "=>", "==", "===", "!=", "!==", "&&", "||", "??", "<=", ">=", "+=", "-=", "*=",
}
IDENT_RE = re.compile(r"[A-Za-z_$][\w$]*")
NUMBER_RE = re.compile(r"\d[\w.]*|\.\d[\w]*")


def mutation_sites(src):
    """Return (start, end, original, replacement) for every mutable token."""
    sites = []
    i = 0
    n = len(src)
    prev = None  # previous significant token, for regex-vs-division
    template_depths = []  # brace depth at which each open ${ returns to its template
    depth = 0

    def skip_string(pos, quote):
        pos += 1
        while pos < n and src[pos] != quote:
            if src[pos] == "\\":
                pos += 1
            elif src[pos] == "\n":
                break
            pos += 1
        return pos + 1

    def skip_template(pos):
        # pos is just after a backtick or a closing }; return (pos, entered_expr)
        while pos < n:
            ch = src[pos]
            if ch == "\\":
                pos += 2
                continue
            if ch == "`":
                return pos + 1, False
            if ch == "$" and pos + 1 < n and src[pos + 1] == "{":
                return pos + 2, True
            pos += 1
        return pos, False

    def skip_regex(pos):
        pos += 1
        in_class = False
        while pos < n:
            ch = src[pos]
            if ch == "\\":
                pos += 2
                continue
            if ch == "\n":
                return pos
            if in_class:
                if ch == "]":
                    in_class = False
            elif ch == "[":
                in_class = True
            elif ch == "/":
                pos += 1
                while pos < n and (src[pos].isalnum() or src[pos] == "_"):
                    pos += 1
                return pos
            pos += 1
        return pos

    while i < n:
        ch = src[i]
        if ch.isspace():
            i += 1
            continue
        if src.startswith("//", i) or (i == 0 and src.startswith("#!")):
            end = src.find("\n", i)
            i = n if end == -1 else end
            continue
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        if ch in "'\"":
            i = skip_string(i, ch)
            prev = "str"
            continue
        if ch == "`":
            i, entered = skip_template(i + 1)
            if entered:
                template_depths.append(depth)
                depth += 1
                prev = "{"
            else:
                prev = "str"
            continue
        if ch == "}" and template_depths and depth - 1 == template_depths[-1]:
            template_depths.pop()
            depth -= 1
            i, entered = skip_template(i + 1)
            if entered:
                template_depths.append(depth)
                depth += 1
                prev = "{"
            else:
                prev = "str"
            continue
        if ch == "/" and (prev is None or prev in REGEX_AFTER_PUNCT or prev in REGEX_AFTER_WORDS):
            i = skip_regex(i)
            prev = "regex"
            continue
        ident = IDENT_RE.match(src, i)
        if ident:
            word = ident.group(0)
            if word in ("true", "false"):
                sites.append((i, ident.end(), word, FLIPS[word]))
            prev = word
            i = ident.end()
            continue
        number = NUMBER_RE.match(src, i)
        if number and (ch.isdigit() or (ch == "." and i + 1 < n and src[i + 1].isdigit())):
            prev = "num"
            i = number.end()
            continue
        for op in OPERATORS:
            if src.startswith(op, i):
                if op == "{":
                    depth += 1
                elif op == "}":
                    depth -= 1
                if op in FLIPS:
                    sites.append((i, i + len(op), op, FLIPS[op]))
                prev = op
                i += len(op)
                break
        else:
            prev = ch
            i += 1
    return sites


def mutation_targets(ws, config):
    include = config.get("include") or []
    exclude = DEFAULT_MUTATION_EXCLUDE + (config.get("exclude") or [])
    proc = subprocess.run(
        ["git", "-C", ws, "ls-files", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
    )
    files = []
    for rel in proc.stdout.splitlines():
        if rel.endswith((".js", ".cjs", ".mjs")) and matches(rel, include) and not matches(rel, exclude):
            files.append(rel)
    return sorted(set(files))


def mutation(ws, config, baseline_pass):
    if not config:
        return None
    cmd = test_command(ws)
    result = {"applicable": True, "killed": 0, "survived": 0, "invalid": 0, "score": None, "mutants": []}
    if not cmd or not baseline_pass:
        result["skipped"] = "own tests do not pass on the unmutated code"
        return result

    targets = mutation_targets(ws, config)
    candidates = []
    digest = hashlib.sha256()
    for rel in targets:
        with open(os.path.join(ws, rel), errors="replace") as fh:
            src = fh.read()
        digest.update(rel.encode() + b"\0" + src.encode())
        for start, end, original, replacement in mutation_sites(src):
            candidates.append((rel, start, end, original, replacement, src.count("\n", 0, start) + 1))
    result["targets"] = targets
    result["sites"] = len(candidates)
    if not candidates:
        result["skipped"] = "no mutable operators in the target files"
        return result

    # Same code, same sample: seed from the code itself.
    rng = random.Random(digest.hexdigest())
    sample = candidates if len(candidates) <= config.get("max_mutants", 40) else rng.sample(
        candidates, config.get("max_mutants", 40)
    )
    sample.sort(key=lambda c: (c[0], c[1]))
    originals = {}
    started = time.monotonic()
    env = test_env()
    try:
        for rel, start, end, original, replacement, line in sample:
            if time.monotonic() - started > MUTATION_BUDGET_S:
                result["budget_exhausted"] = True
                break
            path = os.path.join(ws, rel)
            if rel not in originals:
                with open(path, errors="replace") as fh:
                    originals[rel] = fh.read()
            src = originals[rel]
            mutated = src[:start] + replacement + src[end:]
            with open(path, "w") as fh:
                fh.write(mutated)
            check, _, _ = run(["node", "--check", path], ws, 30)
            record = {"file": rel, "line": line, "from": original, "to": replacement}
            if check != 0:
                record["outcome"] = "invalid"
                result["invalid"] += 1
            else:
                code, _, _ = run(cmd, ws, MUTANT_TIMEOUT_S, env=env)
                killed = code != 0
                record["outcome"] = "killed" if killed else "survived"
                result["killed" if killed else "survived"] += 1
            result["mutants"].append(record)
            with open(path, "w") as fh:
                fh.write(src)
    finally:
        for rel, src in originals.items():
            with open(os.path.join(ws, rel), "w") as fh:
                fh.write(src)
    valid = result["killed"] + result["survived"]
    result["score"] = round(result["killed"] / valid, 4) if valid else None
    result["seconds"] = round(time.monotonic() - started, 1)
    return result


# ── Subcommands ──────────────────────────────────────────────────────────────


def measure(args, followup):
    config = compare_config(args.scenario_dir)
    exclude = DEFAULT_DIFF_EXCLUDE + (config.get("diff_exclude") or []) + (args.exclude or [])
    usage = agent_usage(args.stream)
    out = {
        "usage": usage,
        "diff": diff_stats(args.ws, args.baseline, exclude, None if followup else config.get("scope")),
    }
    out["install"] = npm_install(args.ws)
    out["own_tests"] = own_tests(args.ws)
    out["hidden"] = run_hidden(args.ws, hidden_dirs(args.scenario_dir, followup))
    out["claims"] = claims(usage.get("final_text"), out["own_tests"].get("pass"))
    if not followup:
        out["mutation"] = mutation(args.ws, config.get("mutation"), out["own_tests"].get("pass"))
    usage["final_text"] = (usage.get("final_text") or "")[-4000:]
    with open(args.out, "w") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("main", "followup"):
        p = sub.add_parser(name)
        p.add_argument("--scenario-dir", required=True)
        p.add_argument("--ws", required=True)
        p.add_argument("--baseline", required=True)
        p.add_argument("--stream", required=True)
        p.add_argument("--out", required=True)
        p.add_argument("--exclude", action="append", default=[])
    p = sub.add_parser("hidden")
    p.add_argument("--scenario-dir", required=True)
    p.add_argument("--ws", required=True)
    p.add_argument("--followup", action="store_true")
    p = sub.add_parser("mutate")
    p.add_argument("--scenario-dir", required=True)
    p.add_argument("--ws", required=True)
    args = parser.parse_args()

    if args.command in ("main", "followup"):
        measure(args, args.command == "followup")
    elif args.command == "hidden":
        json.dump(run_hidden(args.ws, hidden_dirs(args.scenario_dir, args.followup)), sys.stdout, indent=2)
        print()
    elif args.command == "mutate":
        config = compare_config(args.scenario_dir).get("mutation")
        baseline = own_tests(args.ws).get("pass")
        json.dump(mutation(args.ws, config, baseline), sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
