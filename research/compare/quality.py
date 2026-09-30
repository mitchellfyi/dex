#!/usr/bin/env python3
"""Quality dimensions beyond the hidden tests, measured on a saved snapshot.

  quality.py measure --scenario-dir D --ws W --out O [--skip perf,fuzz,...]
  quality.py tools          # install the pinned lint tools, print their versions

quality.sh runs this after every trial of a run has finished, one trial at a
time, so the timing-sensitive parts (performance, suite runtime, flakiness)
are not competing with agents that are still working. W must be a disposable
copy: this installs dependencies into it, runs its tests, and writes files.

Dimensions (each is a key in the output; a skipped or inapplicable one is
null, with the reason under "skipped"):

  deps       dependencies added, packages installed, npm audit findings
  suite      the agent's own test suite run 5 times: flakiness, runtime,
             files it leaves behind in the workspace and the temp directory
  static     eslint recommended findings per KLOC, cyclomatic complexity,
             function length, nesting depth, parameter counts
  duplication  duplicated source lines (jscpd)
  cli        CLI conventions: errors on stderr, non-zero exits, usage text,
             messages that name the bad input (scenarios with a "cli" block)
  docs       whether the commands and code samples in the README run
  perf       workloads timed against the reference solution (ratio)
  fuzz       differential fuzzing against the reference solution
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import measure  # noqa: E402  (shared helpers: run, test_command, npm_install, ...)

RESEARCH_DIR = os.path.dirname(HERE)
TOOLS_SRC = os.path.join(HERE, "tools", "package.json")
TOOLS_DIR = os.path.join(RESEARCH_DIR, ".tools", "compare")
JS_DIR = os.path.join(HERE, "js")
DIMENSIONS = ["deps", "suite", "static", "duplication", "cli", "docs", "perf", "fuzz"]
SUITE_RUNS = 5
METRIC_RULES = {"complexity", "max-lines-per-function", "max-depth", "max-params"}
STACK_RE = re.compile(r"^\s+at .*:\d+:\d+\)?$", re.M)


def load_json(path, default=None):
    return measure.load_json(path, default)


def quality_config(scenario_dir):
    return load_json(os.path.join(scenario_dir, "compare", "quality.json"), {}) or {}


def source_files(ws):
    """Tracked and untracked files, minus ignored ones, relative to ws."""
    proc = subprocess.run(
        ["git", "-C", ws, "ls-files", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        files = proc.stdout.splitlines()
    else:
        files = []
        for root, dirs, names in os.walk(ws):
            dirs[:] = [d for d in dirs if d not in ("node_modules", ".git")]
            for name in names:
                files.append(os.path.relpath(os.path.join(root, name), ws))
    return sorted(f for f in set(files) if os.path.isfile(os.path.join(ws, f)) and "node_modules/" not in f)


def js_files(ws):
    out = {"source": [], "test": []}
    for rel in source_files(ws):
        if not rel.endswith((".js", ".cjs", ".mjs")):
            continue
        kind = measure.path_category(rel)
        if kind in ("source", "test"):
            out[kind].append(rel)
    return out


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return {
        "n": len(values),
        "mean": round(statistics.mean(values), 2),
        "max": ordered[-1],
        "p90": ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))],
    }


# ── Tools ────────────────────────────────────────────────────────────────────


def ensure_tools():
    """Install research/compare/tools/package.json into research/.tools/compare.

    Reinstalls when the pinned manifest changes. Returns the tools dir, or
    raises with the install output.
    """
    with open(TOOLS_SRC, "rb") as fh:
        wanted = fh.read()
    stamp = os.path.join(TOOLS_DIR, ".manifest-sha256")
    digest = hashlib.sha256(wanted).hexdigest()
    if os.path.exists(stamp) and open(stamp).read().strip() == digest and os.path.isdir(os.path.join(TOOLS_DIR, "node_modules")):
        return TOOLS_DIR
    os.makedirs(TOOLS_DIR, exist_ok=True)
    with open(os.path.join(TOOLS_DIR, "package.json"), "wb") as fh:
        fh.write(wanted)
    code, out, _ = measure.run(["npm", "install", "--no-audit", "--no-fund", "--loglevel=error"], TOOLS_DIR, 600)
    if code != 0:
        raise RuntimeError(f"could not install quality tools: {measure.tail(out, 10)}")
    with open(stamp, "w") as fh:
        fh.write(digest)
    return TOOLS_DIR


def tool_versions(tools):
    versions = {}
    for name in ("eslint", "@eslint/js", "globals", "jscpd"):
        pkg = load_json(os.path.join(tools, "node_modules", name, "package.json"), {}) or {}
        versions[name] = pkg.get("version")
    return versions


# ── Dependencies ─────────────────────────────────────────────────────────────


def deps(ws):
    pkg = measure.package_json(ws)
    if not pkg:
        return {"package_json": False}
    runtime = sorted((pkg.get("dependencies") or {}).keys())
    dev = sorted((pkg.get("devDependencies") or {}).keys())
    lock = load_json(os.path.join(ws, "node_modules", ".package-lock.json"), {}) or {}
    installed = sum(1 for key in (lock.get("packages") or {}) if key.startswith("node_modules/"))
    out = {
        "package_json": True,
        "runtime": runtime,
        "dev": dev,
        "declared": len(runtime) + len(dev),
        "installed_packages": installed,
        "audit": None,
    }
    if out["declared"] and os.path.exists(os.path.join(ws, "package-lock.json")):
        code, text, _ = measure.run(["npm", "audit", "--json"], ws, 300)
        try:
            vulns = json.loads(text).get("metadata", {}).get("vulnerabilities", {})
            out["audit"] = {k: vulns.get(k, 0) for k in ("info", "low", "moderate", "high", "critical", "total")}
        except ValueError:
            out["audit"] = {"error": measure.tail(text, 5)}
    return out


# ── Test-suite health ────────────────────────────────────────────────────────


def git_dirty(ws):
    proc = subprocess.run(
        ["git", "-C", ws, "status", "--porcelain", "--untracked-files=all"],
        capture_output=True,
        text=True,
    )
    return {line[3:] for line in proc.stdout.splitlines() if "node_modules/" not in line}


def suite(ws):
    cmd = measure.test_command(ws)
    if not cmd:
        return {"has_test_script": False}
    before = git_dirty(ws)
    runs = []
    leftovers_tmp = 0
    for _ in range(SUITE_RUNS):
        tmp = tempfile.mkdtemp(prefix="bench-suite-tmp-")
        env = measure.test_env()
        env.update({"TMPDIR": tmp, "TMP": tmp, "TEMP": tmp})
        code, out, secs = measure.run(cmd, ws, measure.TEST_TIMEOUT_S, env=env)
        left = len(os.listdir(tmp))
        leftovers_tmp = max(leftovers_tmp, left)
        shutil.rmtree(tmp, ignore_errors=True)
        runs.append({"exit": code, "seconds": round(secs, 2), "tmp_leftovers": left})
    passes = sum(1 for r in runs if r["exit"] == 0)
    return {
        "has_test_script": True,
        "runs": SUITE_RUNS,
        "passes": passes,
        "flaky": 0 < passes < SUITE_RUNS,
        "median_seconds": round(statistics.median(r["seconds"] for r in runs), 2),
        "tmp_leftovers": leftovers_tmp,
        "workspace_leftovers": sorted(git_dirty(ws) - before),
        "detail": runs,
    }


# ── Static analysis ──────────────────────────────────────────────────────────


def eslint_config(ws, tools, path):
    pkg = measure.package_json(ws) or {}
    source_type = "module" if pkg.get("type") == "module" else "commonjs"
    tools_json = json.dumps(os.path.join(tools, "node_modules"))
    config = f"""
const path = require('node:path');
const base = {tools_json};
const js = require(path.join(base, '@eslint/js'));
const globals = require(path.join(base, 'globals'));
const metrics = {{
  complexity: ['warn', 0],
  'max-lines-per-function': ['warn', {{ max: 0, skipBlankLines: true, skipComments: true }}],
  'max-depth': ['warn', 0],
  'max-params': ['warn', 0]
}};
module.exports = [
  js.configs.recommended,
  {{
    files: ['**/*.js', '**/*.cjs', '**/*.mjs'],
    languageOptions: {{ ecmaVersion: 'latest', sourceType: '{source_type}', globals: {{ ...globals.node }} }},
    rules: metrics
  }},
  {{ files: ['**/*.cjs'], languageOptions: {{ sourceType: 'commonjs' }} }},
  {{ files: ['**/*.mjs'], languageOptions: {{ sourceType: 'module' }} }},
  {{
    files: ['**/*.test.*', '**/*.spec.*', 'test/**', 'tests/**', '__tests__/**'],
    languageOptions: {{ globals: {{ ...globals.node, ...globals.jest, ...globals.mocha }} }}
  }}
];
"""
    with open(path, "w") as fh:
        fh.write(config)


NUMBER_IN = {
    "complexity": re.compile(r"complexity of (\d+)"),
    "max-lines-per-function": re.compile(r"too many lines \((\d+)\)"),
    "max-depth": re.compile(r"nested too deeply \((\d+)\)"),
    "max-params": re.compile(r"too many parameters \((\d+)\)"),
}


def static(ws, tools):
    files = js_files(ws)
    if not files["source"]:
        return {"skipped": "no JavaScript source files"}
    scratch = tempfile.mkdtemp(prefix="bench-eslint-")
    try:
        config = os.path.join(scratch, "eslint.config.cjs")
        eslint_config(ws, tools, config)
        cmd = [os.path.join(tools, "node_modules", ".bin", "eslint"), "-c", config, "--format", "json", "--no-warn-ignored"]
        code, out, _ = measure.run(cmd + files["source"] + files["test"], ws, 300)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    try:
        report = json.loads(out[out.index("[") :])
    except ValueError:
        return {"error": measure.tail(out, 10)}

    lines = {"source": 0, "test": 0}
    findings = {"source": {}, "test": {}}
    parse_errors = []
    metrics = {rule: [] for rule in METRIC_RULES}
    test_set = set(files["test"])
    for entry in report:
        rel = os.path.relpath(entry["filePath"], ws)
        kind = "test" if rel in test_set else "source"
        with open(os.path.join(ws, rel), errors="replace") as fh:
            lines[kind] += sum(1 for line in fh if line.strip())
        for message in entry.get("messages", []):
            rule = message.get("ruleId")
            if rule is None:
                parse_errors.append(f"{rel}: {message.get('message')}")
            elif rule in METRIC_RULES:
                if kind == "source":
                    match = NUMBER_IN[rule].search(message.get("message", ""))
                    if match:
                        metrics[rule].append(int(match.group(1)))
            else:
                findings[kind][rule] = findings[kind].get(rule, 0) + 1

    def per_kloc(kind):
        total = sum(findings[kind].values())
        return round(total / (lines[kind] / 1000), 2) if lines[kind] else None

    return {
        "source_files": len(files["source"]),
        "test_files": len(files["test"]),
        "source_lines": lines["source"],
        "findings": {"source": sum(findings["source"].values()), "test": sum(findings["test"].values())},
        "findings_per_kloc": {"source": per_kloc("source"), "test": per_kloc("test")},
        "rules": findings,
        "parse_errors": parse_errors[:10],
        "complexity": distribution(metrics["complexity"]),
        "function_lines": distribution(metrics["max-lines-per-function"]),
        "max_depth": max(metrics["max-depth"]) if metrics["max-depth"] else 0,
        "max_params": max(metrics["max-params"]) if metrics["max-params"] else 0,
    }


def duplication(ws, tools):
    files = js_files(ws)["source"]
    if not files:
        return {"skipped": "no JavaScript source files"}
    out_dir = tempfile.mkdtemp(prefix="bench-jscpd-")
    try:
        cmd = [
            os.path.join(tools, "node_modules", ".bin", "jscpd"),
            "--min-tokens", "40",
            "--reporters", "json",
            "--output", out_dir,
            "--format", "javascript",
        ] + files
        code, out, _ = measure.run(cmd, ws, 300)
        report = load_json(os.path.join(out_dir, "jscpd-report.json"))
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    if not report:
        # jscpd exits non-zero when every file is below --min-tokens: nothing
        # large enough to duplicate, which is no duplication.
        return {"percentage": 0.0, "clones": 0, "duplicated_lines": 0, "note": measure.tail(out, 3)}
    total = report.get("statistics", {}).get("total", {})
    return {
        "percentage": round(total.get("percentage", 0.0), 2),
        "clones": total.get("clones", 0),
        "duplicated_lines": total.get("duplicatedLines", 0),
        "lines": total.get("lines", 0),
    }


# ── CLI conventions ──────────────────────────────────────────────────────────


def cli(ws, config):
    """Conventions a CLI user relies on, beyond what the prompt specified."""
    entry = os.path.join(ws, config.get("entry", "index.js"))
    if not os.path.exists(entry):
        return {"skipped": f"no {config.get('entry', 'index.js')}"}
    commands = config.get("commands", [])
    checks = []

    def invoke(args, setup=None):
        cwd = tempfile.mkdtemp(prefix="bench-cli-")
        try:
            for pre in setup or []:
                measure.run(["node", entry] + pre, cwd, 30, env=measure.test_env())
            proc = subprocess.run(
                ["node", entry] + args, cwd=cwd, capture_output=True, text=True, timeout=30, env=measure.test_env()
            )
            return proc.returncode, proc.stdout, proc.stderr
        except subprocess.TimeoutExpired:
            return None, "", "timeout"
        finally:
            shutil.rmtree(cwd, ignore_errors=True)

    def check(name, ok, detail=""):
        checks.append({"check": name, "ok": bool(ok), "detail": detail[:200]})

    usage_seen = False
    for args in ([], ["--help"], ["help"]):
        code, out, err = invoke(args)
        named = sum(1 for c in commands if c in out + err)
        if named >= max(1, len(commands) - 1) and not STACK_RE.search(err):
            usage_seen = True
            break
    check("usage text lists the commands (no args, --help or help)", usage_seen)

    for case in config.get("errors", []):
        args = case["args"]
        label = " ".join(args) or "(no args)"
        code, out, err = invoke(args, case.get("setup"))
        check(f"{label}: exits non-zero", code not in (0, None), f"exit {code}")
        check(f"{label}: reports on stderr", bool(err.strip()), out.strip()[:120])
        check(f"{label}: no stack trace", code is not None and not STACK_RE.search(err + out))
        if case.get("mentions"):
            check(f"{label}: message names {case['mentions']!r}", case["mentions"] in err + out, (err or out).strip()[:120])

    for case in config.get("ok", []):
        args = case["args"]
        label = " ".join(args)
        code, out, err = invoke(args, case.get("setup"))
        check(f"{label}: exits 0 with output on stdout", code == 0 and bool(out.strip()), f"exit {code}")
        check(f"{label}: nothing on stderr", not err.strip(), err.strip()[:120])

    passed = sum(1 for c in checks if c["ok"])
    return {"passed": passed, "total": len(checks), "rate": round(passed / len(checks), 4) if checks else None, "checks": checks}


# ── Docs ─────────────────────────────────────────────────────────────────────

FENCE_RE = re.compile(r"^```([\w+-]*)[^\n]*\n(.*?)^```", re.M | re.S)
SHELL_LANGS = {"", "bash", "sh", "shell", "console", "zsh", "terminal"}
JS_LANGS = {"js", "javascript", "node", "cjs", "mjs"}
RUNNABLE_RE = re.compile(r"^(node|npm|npx)\s")
SKIP_RE = re.compile(r"<[^>]+>|\.\.\.|\bnpm (start|run dev)\b|--watch\b|\bnpm (i|install) -g\b")
EXPECT_FAIL_RE = re.compile(r"#.*\b(error|errors|fails?|invalid|not found|rejected)\b", re.I)
LOCAL_IMPORT_RE = re.compile(r"""require\(\s*['"]\.{1,2}/|from\s+['"]\.{1,2}/""")


def docs(ws):
    readmes = [f for f in os.listdir(ws) if re.match(r"^readme(\.(md|markdown|txt))?$", f, re.I)]
    if not readmes:
        return {"readme": False}
    text = "\n".join(open(os.path.join(ws, f), errors="replace").read() for f in readmes)
    shell, js = [], []
    for lang, body in FENCE_RE.findall(text):
        lang = lang.lower()
        if lang in SHELL_LANGS:
            for raw in body.splitlines():
                line = raw.strip()
                if lang == "console" and not line.startswith("$ "):
                    continue
                line = line[2:] if line.startswith("$ ") else line
                if RUNNABLE_RE.match(line) and not SKIP_RE.search(line):
                    shell.append(line)
        elif lang in JS_LANGS and LOCAL_IMPORT_RE.search(body):
            js.append((lang, body))

    results = []
    # Commands run in order in one copy, so a README that adds and then lists
    # todos is checked the way a reader would follow it.
    for line in shell:
        expect_fail = bool(EXPECT_FAIL_RE.search(line))
        command = re.sub(r"\s+#.*$", "", line)
        code, out, _ = measure.run(["bash", "-c", command], ws, 120, env=measure.test_env())
        crashed = bool(STACK_RE.search(out))
        ok = (code != 0 if expect_fail else code == 0) and not crashed and code != 124
        results.append({"kind": "command", "run": command, "ok": ok, "exit": code, "output": "" if ok else measure.tail(out, 5)})
    for i, (lang, body) in enumerate(js):
        name = f".bench-doc-{i}.{'mjs' if lang == 'mjs' or re.search(r'^\s*import\s', body, re.M) else 'js'}"
        path = os.path.join(ws, name)
        with open(path, "w") as fh:
            fh.write(body)
        code, out, _ = measure.run(["node", name], ws, 60, env=measure.test_env())
        os.remove(path)
        ok = code == 0
        results.append({"kind": "js", "run": body.strip().splitlines()[0][:120], "ok": ok, "exit": code, "output": "" if ok else measure.tail(out, 5)})

    passed = sum(1 for r in results if r["ok"])
    return {
        "readme": True,
        "files": readmes,
        "samples": len(results),
        "passed": passed,
        "rate": round(passed / len(results), 4) if results else None,
        "failures": [r for r in results if not r["ok"]][:5],
    }


# ── Performance and fuzzing ──────────────────────────────────────────────────


def reference_workspace(scenario_dir, scratch):
    """The seed with the scenario's reference solution laid over it."""
    ref = os.path.join(scratch, "reference")
    os.makedirs(ref, exist_ok=True)
    for overlay in (os.path.join(scenario_dir, "seed"), os.path.join(scenario_dir, "compare", "reference")):
        if os.path.isdir(overlay):
            shutil.copytree(overlay, ref, dirs_exist_ok=True)
    measure.npm_install(ref)
    return ref


def run_js(script, args, timeout):
    code, out, _ = measure.run(["node", os.path.join(JS_DIR, script)] + args, HERE, timeout)
    try:
        return json.loads(out[out.index("{") :])
    except ValueError:
        return {"error": f"exit {code}: {measure.tail(out, 10)}"}


def perf(ws, ref, scenario_dir, config):
    definition = os.path.join(scenario_dir, "compare", "perf.js")
    if not os.path.exists(definition):
        return {"skipped": "no compare/perf.js"}
    reps = str(config.get("reps", 6))
    result = run_js("perf-runner.js", [definition, ws, ref, reps], 1800)
    result["load_average_before"] = os.getloadavg()
    return result


def fuzz(ws, ref, scenario_dir, config):
    definition = os.path.join(scenario_dir, "compare", "fuzz.js")
    if not os.path.exists(definition):
        return {"skipped": "no compare/fuzz.js"}
    args = [definition, ws, ref, str(config.get("sequences", 30)), str(config.get("steps", 40)), str(config.get("seed", 1))]
    return run_js("fuzz-runner.js", args, 1800)


# ── Measure ──────────────────────────────────────────────────────────────────


def measure_all(scenario_dir, ws, skip):
    config = quality_config(scenario_dir)
    out = {"load_average_start": os.getloadavg(), "cpus": os.cpu_count(), "skipped": {}}

    def guarded(name, fn):
        if name in skip:
            out[name] = None
            out["skipped"][name] = "skipped by --skip"
            return
        try:
            result = fn()
        except Exception as exc:  # one broken dimension must not lose the others
            result = {"error": f"{type(exc).__name__}: {exc}"}
        if isinstance(result, dict) and "skipped" in result and len(result) == 1:
            out["skipped"][name] = result["skipped"]
            result = None
        out[name] = result

    measure.npm_install(ws)
    guarded("deps", lambda: deps(ws))
    guarded("suite", lambda: suite(ws))

    tools = None
    if not {"static", "duplication"} <= set(skip):
        try:
            tools = ensure_tools()
            out["tools"] = tool_versions(tools)
        except RuntimeError as exc:
            out["tools"] = {"error": str(exc)}
    for name, fn in (("static", static), ("duplication", duplication)):
        guarded(name, (lambda f=fn: f(ws, tools)) if tools else (lambda: {"skipped": "quality tools unavailable"}))

    cli_config = config.get("cli")
    guarded("cli", (lambda: cli(ws, cli_config)) if cli_config else (lambda: {"skipped": "scenario has no CLI"}))
    guarded("docs", lambda: docs(ws))

    scratch = tempfile.mkdtemp(prefix="bench-quality-ref-")
    try:
        ref = reference_workspace(scenario_dir, scratch)
        guarded("perf", lambda: perf(ws, ref, scenario_dir, config.get("perf", {})))
        guarded("fuzz", lambda: fuzz(ws, ref, scenario_dir, config.get("fuzz", {})))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    out["load_average_end"] = os.getloadavg()
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("measure")
    p.add_argument("--scenario-dir", required=True)
    p.add_argument("--ws", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--skip", default="", help=f"comma-separated: {','.join(DIMENSIONS)}")
    sub.add_parser("tools")
    args = parser.parse_args()

    if args.command == "tools":
        print(json.dumps(tool_versions(ensure_tools()), indent=2))
        return
    skip = {s for s in args.skip.split(",") if s}
    unknown = skip - set(DIMENSIONS)
    if unknown:
        parser.error(f"unknown dimension(s): {', '.join(sorted(unknown))}")
    # realpath: tools report resolved paths (macOS /var is /private/var), and
    # every relative path here is computed against the workspace.
    result = measure_all(os.path.realpath(args.scenario_dir), os.path.realpath(args.ws), skip)
    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
