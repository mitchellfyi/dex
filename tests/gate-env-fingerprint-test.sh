#!/usr/bin/env bash
set -euo pipefail

# scripts/gate_env_fingerprint.py binds a gate receipt to the environment the
# gate ran in. The checkout and working fingerprints say which tree a result is
# about; this says which toolchain, which parallelism budget and which
# dependency manifests produced it. Same inputs have to hash the same so a
# receipt can be reused, and the inputs that change how a suite behaves have to
# move the hash so a receipt is not reused across them.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
SCRIPT="$ROOT/scripts/gate_env_fingerprint.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-gate-env-fingerprint-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# jget <json-file> <python expression over d>
jget() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

[[ -f "$SCRIPT" ]] || assert_at $LINENO

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
printf '{"name":"fixture"}\n' > "$REPO/package.json"
printf 'lockfileVersion: 9\n' > "$REPO/pnpm-lock.yaml"
printf 'pytest==8.0.0\n' > "$REPO/requirements.txt"
printf 'pytest-xdist==3.5.0\n' > "$REPO/requirements-dev.txt"

# A fixed environment for the stable cases.
unset DX_TEST_JOBS VITEST_MAX_THREADS NODE_ENV RAILS_ENV PYTHONPATH

# ── Output shape ──────────────────────────────────────────────────────────────
python3 "$SCRIPT" --repo "$REPO" > "$TMP_DIR/a.json"
[[ "$(jget "$TMP_DIR/a.json" 'd["schema_version"]')" == "1" ]] || assert_at $LINENO
FP_A="$(jget "$TMP_DIR/a.json" 'd["env_fingerprint"]')"
[[ "$FP_A" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
# The inputs are the audit trail: a reader can see why two hashes differ.
[[ "$(jget "$TMP_DIR/a.json" 'sorted(d["inputs"])')" == \
  "['env', 'manifests', 'path_sha256', 'platform', 'tools']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/a.json" 'sorted(d["inputs"]["manifests"])')" == \
  "['package.json', 'pnpm-lock.yaml', 'requirements-dev.txt', 'requirements.txt']" ]] \
  || assert_at $LINENO
[[ "$(jget "$TMP_DIR/a.json" 'd["inputs"]["platform"]')" == "$(uname -sm)" ]] || assert_at $LINENO
# python3 is on PATH, or this test could not be running; it is in the allowlist.
[[ "$(jget "$TMP_DIR/a.json" '"python3" in d["inputs"]["tools"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/a.json" 'd["inputs"]["env"]')" == "{}" ]] || assert_at $LINENO

# --hash-only prints the fingerprint alone, for a shell caller.
[[ "$(python3 "$SCRIPT" --repo "$REPO" --hash-only)" == "$FP_A" ]] || assert_at $LINENO

# ── Same inputs, same hash ────────────────────────────────────────────────────
python3 "$SCRIPT" --repo "$REPO" > "$TMP_DIR/b.json"
[[ "$(jget "$TMP_DIR/b.json" 'd["env_fingerprint"]')" == "$FP_A" ]] || assert_at $LINENO
# Running from inside the repo with no --repo reads the same root.
[[ "$(cd "$REPO" && python3 "$SCRIPT" --hash-only)" == "$FP_A" ]] || assert_at $LINENO

# ── The parallelism budget moves the hash ─────────────────────────────────────
FP_JOBS_2="$(DX_TEST_JOBS=2 python3 "$SCRIPT" --repo "$REPO" --hash-only)"
FP_JOBS_4="$(DX_TEST_JOBS=4 python3 "$SCRIPT" --repo "$REPO" --hash-only)"
[[ "$FP_JOBS_2" != "$FP_A" ]] || assert_at $LINENO
[[ "$FP_JOBS_2" != "$FP_JOBS_4" ]] || assert_at $LINENO
[[ "$(DX_TEST_JOBS=2 python3 "$SCRIPT" --repo "$REPO" --hash-only)" == "$FP_JOBS_2" ]] \
  || assert_at $LINENO
# A runner variable from the host budget counts too.
[[ "$(VITEST_MAX_THREADS=2 python3 "$SCRIPT" --repo "$REPO" --hash-only)" != "$FP_A" ]] \
  || assert_at $LINENO
# So does a framework mode switch.
[[ "$(NODE_ENV=production python3 "$SCRIPT" --repo "$REPO" --hash-only)" != "$FP_A" ]] \
  || assert_at $LINENO

# --set NAME=VALUE is how a caller binds the values it is about to export, so
# the fingerprint describes the gate's effective environment rather than the
# caller's own. It overrides the inherited value and is recorded under env.
python3 "$SCRIPT" --repo "$REPO" --set DX_TEST_JOBS=2 --set BUILD_WORKERS=2 > "$TMP_DIR/set.json"
[[ "$(jget "$TMP_DIR/set.json" 'd["inputs"]["env"]["DX_TEST_JOBS"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/set.json" 'd["inputs"]["env"]["BUILD_WORKERS"]')" == "2" ]] || assert_at $LINENO
[[ "$(DX_TEST_JOBS=9 python3 "$SCRIPT" --repo "$REPO" --set DX_TEST_JOBS=2 --hash-only)" == \
  "$(python3 "$SCRIPT" --repo "$REPO" --set DX_TEST_JOBS=2 --hash-only)" ]] || assert_at $LINENO
# The same value through --set or the environment is the same binding.
[[ "$(python3 "$SCRIPT" --repo "$REPO" --set DX_TEST_JOBS=2 --hash-only)" == "$FP_JOBS_2" ]] \
  || assert_at $LINENO

# ── A manifest's content moves the hash ───────────────────────────────────────
printf 'lockfileVersion: 9\nimporters: {}\n' > "$REPO/pnpm-lock.yaml"
FP_LOCK="$(python3 "$SCRIPT" --repo "$REPO" --hash-only)"
[[ "$FP_LOCK" != "$FP_A" ]] || assert_at $LINENO
printf 'lockfileVersion: 9\n' > "$REPO/pnpm-lock.yaml"
[[ "$(python3 "$SCRIPT" --repo "$REPO" --hash-only)" == "$FP_A" ]] || assert_at $LINENO
# A manifest that appears is a change; one that is not there is simply absent.
printf 'module fixture\n' > "$REPO/go.sum"
[[ "$(python3 "$SCRIPT" --repo "$REPO" --hash-only)" != "$FP_A" ]] || assert_at $LINENO
rm "$REPO/go.sum"
# A file the allowlist does not name is not a manifest.
printf 'notes\n' > "$REPO/README.md"
[[ "$(python3 "$SCRIPT" --repo "$REPO" --hash-only)" == "$FP_A" ]] || assert_at $LINENO

# ── PATH is bound by hash, not by content ─────────────────────────────────────
EXTRA_BIN="$TMP_DIR/extra-bin"
mkdir -p "$EXTRA_BIN"
[[ "$(PATH="$EXTRA_BIN:$PATH" python3 "$SCRIPT" --repo "$REPO" --hash-only)" != "$FP_A" ]] \
  || assert_at $LINENO
[[ "$(jget "$TMP_DIR/a.json" 'd["inputs"]["path_sha256"]')" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/a.json" '"PATH" in d["inputs"]["env"]')" == "False" ]] || assert_at $LINENO

# ── Arguments it will not act on ──────────────────────────────────────────────
if python3 "$SCRIPT" --repo "$TMP_DIR/does-not-exist" --hash-only >/dev/null 2>&1; then
  fail "a missing repo directory was accepted"
fi
if python3 "$SCRIPT" --repo "$REPO" --set 'not an env name=1' --hash-only >/dev/null 2>&1; then
  fail "an invalid --set name was accepted"
fi
if python3 "$SCRIPT" --bogus >/dev/null 2>&1; then
  fail "an unknown option was accepted"
fi

printf 'gate env fingerprint tests passed\n'
