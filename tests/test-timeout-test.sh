#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
supervisor = root / "tests/test-timeout.py"

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
