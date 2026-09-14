#!/usr/bin/env python3
"""Exercise the native Codex TUI against the local CCR provider fixture."""

import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def run():
    wrapper = Path(__file__).resolve().parents[1] / "bin" / "dxcodex.sh"
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", str(wrapper), "session", "Say hello."])
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    output = b""
    answered = False
    continued = False
    deadline = time.monotonic() + 50
    try:
        while time.monotonic() < deadline:
            if select.select([terminal], [], [], 0.2)[0]:
                try:
                    chunk = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output += chunk
                if b"\x1b[6n" in chunk:
                    os.write(terminal, b"\x1b[1;1R")
                clean = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", output)
                if b"press enter" in clean.lower() and not continued:
                    continued = True
                    os.write(terminal, b"\r")
                if b"Claude answer" in clean and not answered:
                    answered = True
                    os.write(terminal, b"\x03")
                    time.sleep(0.3)
                    os.write(terminal, b"\x03")
                    deadline = time.monotonic() + 5
        if not answered:
            sys.exit("Native Codex did not receive the fixture response:\n" + (clean[:2000] + b"\n...\n" + clean[-3000:]).decode(errors="replace"))
        print("Native Codex received the Anthropic fixture response through CCR.")
    finally:
        os.close(terminal)
        if os.waitpid(pid, os.WNOHANG)[0] == 0:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)


if __name__ == "__main__":
    run()
