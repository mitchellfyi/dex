#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

python3 - "$ROOT" <<'PY'
import errno
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from unittest import mock

root = Path(sys.argv[1])
supervisor = root / "tests/test-timeout.py"
spec = importlib.util.spec_from_file_location("test_timeout", supervisor)
timeout_runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timeout_runner)


def cleanup_result(error, failed_signal, returncode):
    child = mock.Mock(pid=4242, returncode=returncode)
    child.poll.return_value = returncode
    child.wait.return_value = returncode

    def signal_group(pid, signum):
        assert pid == child.pid, pid
        if signum == failed_signal:
            raise error

    with mock.patch.object(timeout_runner.subprocess, "Popen", return_value=child), \
            mock.patch.object(timeout_runner.os, "killpg", side_effect=signal_group) as killpg, \
            mock.patch.object(timeout_runner.signal, "signal"), \
            mock.patch.object(timeout_runner.time, "monotonic", side_effect=[0, 0, 0, 3]), \
            mock.patch.object(timeout_runner.time, "sleep"), \
            mock.patch.object(sys, "argv", [str(supervisor), "10", "fixture"]):
        result = timeout_runner.main()
    expected_signals = [signal.SIGTERM, 0, signal.SIGKILL]
    assert killpg.call_args_list == [mock.call(child.pid, signum) for signum in
                                    expected_signals[:expected_signals.index(failed_signal) + 1]]
    child.wait.assert_called_once_with()
    return result


# Cleanup races must not replace success, failure, or signal exit statuses.
for failure in (PermissionError(errno.EPERM, "not permitted"),
                ProcessLookupError(errno.ESRCH, "no such process")):
    for failed_signal in (signal.SIGTERM, 0, signal.SIGKILL):
        for returncode in (0, 37, -signal.SIGTERM):
            expected = returncode if returncode >= 0 else 128 - returncode
            assert cleanup_result(failure, failed_signal, returncode) == expected

# Permission failures for a live direct child and unrelated errors are real
# cleanup failures, not evidence that the process group has disappeared.
for failure, returncode in ((PermissionError(errno.EPERM, "not permitted"), None),
                            (OSError(errno.EIO, "injected IO failure"), 0)):
    for failed_signal in (signal.SIGTERM, 0, signal.SIGKILL):
        child = mock.Mock(pid=4242)
        child.poll.return_value = returncode

        def signal_group(pid, signum):
            assert pid == child.pid, pid
            if signum == failed_signal:
                raise failure

        with mock.patch.object(timeout_runner.os, "killpg", side_effect=signal_group), \
                mock.patch.object(timeout_runner.time, "monotonic", side_effect=[0, 0, 3]), \
                mock.patch.object(timeout_runner.time, "sleep"):
            try:
                timeout_runner.stop_group(child)
            except OSError as error:
                assert error is failure, error
            else:
                raise AssertionError(("cleanup swallowed an error", failure, failed_signal))


# Hold an unreaped zombie outside its process group, with an optional live
# sibling in the group. This needs no privileges or timing-sensitive orphaning.
zombie_holder = """import os
import signal
import sys

read_fd, write_fd = os.pipe()
zombie = os.fork()
if zombie == 0:
    os.close(read_fd)
    os.setpgid(0, 0)
    os.write(write_fd, b"1")
    os._exit(0)
os.close(write_fd)
assert os.read(read_fd, 1) == b"1"
os.close(read_fd)
live = 0
if sys.argv[1] == "mixed":
    read_fd, write_fd = os.pipe()
    live = os.fork()
    if live == 0:
        os.close(read_fd)
        os.setpgid(0, zombie)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.write(write_fd, b"1")
        os.close(write_fd)
        while True:
            signal.pause()
    os.close(write_fd)
    assert os.read(read_fd, 1) == b"1"
    os.close(read_fd)
print(zombie, live, flush=True)
try:
    sys.stdin.read()
finally:
    if live:
        try:
            os.kill(live, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(live, 0)
    os.waitpid(zombie, 0)
"""

for mode in ("zombie", "mixed"):
    holder = subprocess.Popen([sys.executable, "-c", zombie_holder, mode],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        group_pid, live_pid = map(int, holder.stdout.readline().split())
        deadline = time.monotonic() + 10
        while True:
            state = subprocess.check_output(["ps", "-o", "stat=", "-p", str(group_pid)],
                                            text=True).strip()
            if state.startswith("Z"):
                break
            assert time.monotonic() < deadline, ("fixture did not become a zombie", state)
            time.sleep(0.02)
        if mode == "zombie" and sys.platform == "darwin":
            try:
                os.killpg(group_pid, 0)
            except PermissionError as error:
                assert error.errno == errno.EPERM, error
            else:
                raise AssertionError("Darwin zombie-only group did not reproduce EPERM")
        child = mock.Mock(pid=group_pid)
        child.poll.return_value = 0
        timeout_runner.stop_group(child)
        if live_pid:
            deadline = time.monotonic() + 10
            while True:
                state = subprocess.check_output(["ps", "-o", "stat=", "-p", str(live_pid)],
                                                text=True).strip()
                if state.startswith("Z"):
                    break
                assert time.monotonic() < deadline, ("signalable sibling survived cleanup", state)
                time.sleep(0.02)
    finally:
        _, errors = holder.communicate(timeout=10)
        assert holder.returncode == 0, (holder.returncode, errors)

with tempfile.TemporaryDirectory(prefix="dex-test-timeout-") as temporary:
    directory = Path(temporary)
    fixture = directory / "fixture.py"
    fixture.write_text('''import os
from pathlib import Path
import signal
import subprocess
import sys
import time

report = Path(sys.argv[1])
if sys.argv[2] == "child":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (report / "child.pid").write_text(str(os.getpid()))
    time.sleep(60)
else:
    child = subprocess.Popen([sys.executable, __file__, str(report), "child"])
    while not (report / "child.pid").exists():
        if child.poll() is not None:
            raise SystemExit("fixture child exited before publishing its PID")
        time.sleep(0.01)
    print("fixture ready", flush=True)
    if sys.argv[2] == "exit":
        raise SystemExit(37)
    child.wait()
''')

    def assert_child_stopped(report):
        pid_file = report / "child.pid"
        pid = int(pid_file.read_text())
        result = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                capture_output=True, text=True, check=False)
        assert result.returncode != 0 or result.stdout.strip().startswith("Z"), (
            "fixture child survived the supervisor", pid, result.stdout)
        pid_file.unlink()

    def wait_ready(report, process):
        deadline = time.monotonic() + 15
        while not (report / "child.pid").exists():
            assert process.poll() is None, "supervisor exited before fixture readiness"
            assert time.monotonic() < deadline, "fixture did not publish its child PID"
            time.sleep(0.02)

    active = None
    try:
        report = directory / "timeout"
        report.mkdir()
        suite = directory / "suite"
        suite.mkdir()
        (suite / "timeout-test.sh").write_text(
            '#!/bin/bash\nset -euo pipefail\n'
            'exec python3 "$DX_TEST_REPORT_DIR/../fixture.py" "$DX_TEST_REPORT_DIR" wait\n')
        (suite / "manifest.tsv").write_text("timeout-test.sh\tfast\tall\t1\thermetic\n")
        logs = directory / "logs"
        environment = dict(os.environ, DX_TEST_SUITE_DIR=str(suite),
                           DX_TEST_MANIFEST=str(suite / "manifest.tsv"),
                           DX_TEST_LOG_DIR=str(logs), DX_TEST_REPORT_DIR=str(report),
                           DX_TEST_LANES="all", DX_TEST_SHARD="1/1", DX_TEST_TIMEOUT="")
        result = subprocess.run(["bash", str(root / "tests/run-all.sh")],
                                env=environment, capture_output=True, text=True, timeout=30)
        assert result.returncode == 1, result
        assert (logs / "timeout-test.sh.rc").read_text().strip() == "124", result.stdout
        assert "stopping its process group" in (logs / "timeout-test.sh.log").read_text()
        assert "Directory not empty" not in result.stderr, result.stderr
        assert_child_stopped(report)

        # Background children must also stop when the test exits on its own.
        report = directory / "exit"
        report.mkdir()
        result = subprocess.run([sys.executable, str(supervisor), "10", sys.executable,
                                 str(fixture), str(report), "exit"],
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 37, result
        assert "fixture ready" in result.stdout, result
        assert_child_stopped(report)

        for stop_signal in (signal.SIGTERM, signal.SIGINT):
            report = directory / f"signal-{stop_signal}"
            report.mkdir()
            with (report / "output").open("w") as output:
                active = subprocess.Popen([sys.executable, str(supervisor), "60",
                                           sys.executable, str(fixture), str(report), "wait"],
                                          stdout=output, stderr=subprocess.STDOUT)
                wait_ready(report, active)
                active.send_signal(stop_signal)
                assert active.wait(timeout=15) == 128 + stop_signal
                active = None
            assert_child_stopped(report)
    finally:
        if active is not None and active.poll() is None:
            active.terminate()
            active.wait(timeout=15)
        for pid_file in directory.glob("*/child.pid"):
            try:
                os.kill(int(pid_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

print("test timeout cleanup passed")
PY
