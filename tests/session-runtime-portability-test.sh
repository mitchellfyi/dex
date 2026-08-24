#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-runtime-portability.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck source=lib/session.sh
source "$ROOT/lib/session.sh"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"

PS_STUB="$TMP_DIR/ps-stub"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ "$1" == "-o" && "$2" == "lstart=" && "$3" == "-p" && "$4" =~ ^[0-9]+$ ]] || exit 90' \
  '[[ "${LC_ALL:-}" == "C" && "${LANG:-}" == "C" && "${TZ:-}" == "UTC" ]] || exit 91' \
  '[[ -n "${DX_TEST_PS_LSTART:-}" ]] || exit 1' \
  'printf "  %s  \\n" "$DX_TEST_PS_LSTART"' \
  > "$PS_STUB"
chmod +x "$PS_STUB"
export DX_SESSION_RUNTIME_PS_BIN="$PS_STUB"

PROC_ROOT="$TMP_DIR/proc"
mkdir -p "$PROC_ROOT/$$" "$PROC_ROOT/sys/kernel/random"
export DX_SESSION_RUNTIME_PROC_ROOT="$PROC_ROOT"
printf '%s\n' 'fedcba98-7654-3210-fedc-ba9876543210' \
  > "$PROC_ROOT/sys/kernel/random/boot_id"
printf '%s\n' \
  "$$ (name with ) parenthesis) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777777 20" \
  > "$PROC_ROOT/$$/stat"
assert_eq "linux:fedcba98-7654-3210-fedc-ba9876543210:777777" \
  "$(dx_session_runtime_process_identity "$$")" "Linux process identity"

printf 'malformed\n' > "$PROC_ROOT/$$/stat"
export DX_TEST_PS_LSTART="Mon Aug 24 10:11:12 2026"
assert_eq "ps:Mon Aug 24 10:11:12 2026" \
  "$(dx_session_runtime_process_identity "$$")" "diagnostic ps fallback"

export DX_SESSION_RUNTIME_PROC_ROOT="$TMP_DIR/no-proc"
export DX_TEST_PS_LSTART="Tue Aug 25   01:02:03   2026"
assert_eq "ps:Tue Aug 25 01:02:03 2026" \
  "$(dx_session_runtime_process_identity "$$")" "normalized ps diagnostic"
PS_ONLY_SID="$(dx_scoped_session_id worktree-ps-only)"
PS_ONLY_WORKSPACE="$TMP_DIR/repo/.dex/worktrees/ps-only"
mkdir -p "$PS_ONLY_WORKSPACE"
if dx_session_runtime_start "$PS_ONLY_SID" codex "$PS_ONLY_WORKSPACE" "$$" >/dev/null 2>&1; then
  fail "runtime lease authorized a diagnostic-only ps identity"
else
  assert_eq "3" "$?" "ps-only lease result"
fi

unset DX_TEST_PS_LSTART
if dx_session_runtime_process_identity "$$" >/dev/null 2>&1; then
  fail "process identity succeeded without stable or diagnostic evidence"
fi
if dx_session_runtime_process_identity not-a-pid >/dev/null 2>&1; then
  fail "process identity accepted a non-numeric PID"
else
  assert_eq "3" "$?" "invalid PID result"
fi

FIFO_PROC_ROOT="$TMP_DIR/fifo-proc"
mkdir -p "$FIFO_PROC_ROOT/$$" "$FIFO_PROC_ROOT/sys/kernel/random"
printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' \
  > "$FIFO_PROC_ROOT/sys/kernel/random/boot_id"
mkfifo "$FIFO_PROC_ROOT/$$/stat"
FIFO_RESULT="$TMP_DIR/fifo-proc.result"
(
  set +e
  DX_SESSION_RUNTIME_PROC_ROOT="$FIFO_PROC_ROOT" \
    dx_session_runtime_process_identity "$$" >/dev/null 2>&1
  printf '%s\n' "$?" > "$FIFO_RESULT"
) &
FIFO_PID=$!
fifo_attempt=0
while [[ ! -s "$FIFO_RESULT" && "$fifo_attempt" -lt 30 ]]; do
  sleep 0.1
  fifo_attempt=$((fifo_attempt + 1))
done
if [[ ! -s "$FIFO_RESULT" ]]; then
  kill "$FIFO_PID" 2>/dev/null || true
  wait "$FIFO_PID" 2>/dev/null || true
  fail "process identity blocked while inspecting a proc FIFO"
fi
wait "$FIFO_PID"
assert_eq "1" "$(<"$FIFO_RESULT")" "proc FIFO identity result"

# Exercise the Darwin ctypes layout with a stubbed libproc call on every CI host.
python3 - "$ROOT/lib/session-runtime.sh" <<'PY'
import ctypes
import os
import pathlib
import types
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
embedded = source.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
definitions = embedded.split("\noperation = sys.argv[1]", 1)[0]
namespace = {}
exec(compile(definitions, sys.argv[1], "exec"), namespace)
namespace["sys"] = types.SimpleNamespace(platform="darwin")
os.environ.pop("DX_SESSION_RUNTIME_PROC_ROOT", None)


class StubProcPidInfo:
    argtypes = None
    restype = None

    def __call__(self, pid, flavor, argument, buffer, size):
        assert flavor == 3
        assert argument == 0
        process_info = ctypes.cast(
            buffer, ctypes.POINTER(namespace["ProcBSDInfo"])
        ).contents
        process_info.pbi_pid = pid
        process_info.pbi_status = 2
        process_info.pbi_start_tvsec = 123456789
        process_info.pbi_start_tvusec = 654321
        return size


stub_call = StubProcPidInfo()
namespace["ctypes"].util.find_library = lambda _name: "stub-libproc"
namespace["ctypes"].CDLL = lambda *_args, **_kwargs: types.SimpleNamespace(
    proc_pidinfo=stub_call
)
probe = namespace["darwin_process_probe"](4321)
if probe != {
    "health": "live",
    "identity": "darwin:123456789:654321",
    "diagnostic": None,
}:
    raise SystemExit(f"unexpected Darwin live probe: {probe!r}")

original_call = stub_call.__call__


class ZombieProcPidInfo(StubProcPidInfo):
    def __call__(self, pid, flavor, argument, buffer, size):
        result = original_call(pid, flavor, argument, buffer, size)
        process_info = ctypes.cast(
            buffer, ctypes.POINTER(namespace["ProcBSDInfo"])
        ).contents
        process_info.pbi_status = 5
        return result


namespace["ctypes"].CDLL = lambda *_args, **_kwargs: types.SimpleNamespace(
    proc_pidinfo=ZombieProcPidInfo()
)
probe = namespace["darwin_process_probe"](4321)
if probe["health"] != "dead":
    raise SystemExit(f"unexpected Darwin zombie probe: {probe!r}")
PY

# A timezone change cannot change or replace a stable live lease.
unset DX_SESSION_RUNTIME_PROC_ROOT DX_SESSION_RUNTIME_PS_BIN
NATIVE_IDENTITY="$(dx_session_runtime_process_identity "$$")"
case "$(uname -s)" in
  Darwin) [[ "$NATIVE_IDENTITY" =~ ^darwin:[0-9]+:[0-9]+$ ]] || assert_at $LINENO ;;
  Linux) [[ "$NATIVE_IDENTITY" =~ ^linux:[0-9a-f-]+:[0-9]+$ ]] || assert_at $LINENO ;;
esac
TZ_SID="$(dx_scoped_session_id worktree-timezone)"
TZ_WORKSPACE="$TMP_DIR/repo/.dex/worktrees/timezone"
mkdir -p "$TZ_WORKSPACE"
TZ=Pacific/Auckland TZ_TOKEN="$(TZ=Pacific/Auckland \
  dx_session_runtime_start "$TZ_SID" codex "$TZ_WORKSPACE" "$$")"
[[ "$TZ_TOKEN" =~ ^[0-9a-f]{64}$ ]] || assert_at $LINENO
if TZ=America/Los_Angeles \
  dx_session_runtime_start "$TZ_SID" codex "$TZ_WORKSPACE" "$$" >/dev/null 2>&1; then
  fail "timezone change replaced a live runtime lease"
else
  assert_eq "2" "$?" "timezone-stable lease result"
fi
assert_eq "live" "$(TZ=UTC dx_session_runtime_health "$TZ_SID" "$TZ_TOKEN")" \
  "timezone-stable lease health"

printf 'session runtime portability tests passed\n'
