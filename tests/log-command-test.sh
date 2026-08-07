#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-log-command.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$DX_STATE_DIR"

bash "$ROOT/bin/log.sh" --help > "$TMP_DIR/help.out"
grep -Fq 'Usage: dx log [session_id]' "$TMP_DIR/help.out"
zsh -fc 'source "$DEX_DIR/dx.sh"; dx log --help' > "$TMP_DIR/cli-help.out"
grep -Fq 'Usage: dx log [session_id]' "$TMP_DIR/cli-help.out"

if bash "$ROOT/bin/log.sh" --unknown > "$TMP_DIR/unknown.out" 2>&1; then
  printf 'dx log accepted an unknown option\n' >&2
  exit 1
fi
grep -Fq 'Unknown dx log option: --unknown' "$TMP_DIR/unknown.out"

if bash "$ROOT/bin/log.sh" first second > "$TMP_DIR/extra.out" 2>&1; then
  printf 'dx log accepted multiple session filters\n' >&2
  exit 1
fi
grep -Fq 'accepts at most one session ID' "$TMP_DIR/extra.out"

{
  printf 'session_id\tphase\tphase_name\tstart_epoch\tend_epoch\tduration_s\titerations\tstatus\texit_code\n'
  printf 'repo-worktree-task\t1\tPlan\t100\t165\t65\t2\tadvance\t0\n'
  printf 'repo-worktree-task\t2\tImplement\t165\t3725\t3560\t3\tmax-iter\t1\n'
} > "$DX_STATE_DIR/repo-worktree-task.log"

bash "$ROOT/bin/log.sh" task > "$TMP_DIR/log.out"
grep -Fq 'Session: repo-worktree-task' "$TMP_DIR/log.out"
grep -Fq '1m 5s' "$TMP_DIR/log.out"
grep -Fq 'MAX-ITER' "$TMP_DIR/log.out"
grep -Fq 'Total: 1h 0m' "$TMP_DIR/log.out"

bash "$ROOT/bin/log.sh" missing > "$TMP_DIR/missing.out"
grep -Fq "No logs found matching 'missing'." "$TMP_DIR/missing.out"

printf 'log command tests passed\n'
