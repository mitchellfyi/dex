#!/usr/bin/env python3
"""Exercise the native Codex TUI against the local CCR provider fixture."""

import errno
import fcntl
import json
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
    compact = "--compact" in sys.argv[1:]
    prompt = "Remember the synthetic-compaction-fixture facts, then say hello." if compact else "Say hello."
    rollouts_before = set(Path(os.environ["CODEX_HOME"]).glob("sessions/**/*.jsonl"))

    def events():
        rollouts = set(Path(os.environ["CODEX_HOME"]).glob("sessions/**/*.jsonl")) - rollouts_before
        result = []
        for file in sorted(rollouts):
            for line in file.read_text().splitlines():
                try:
                    result.append(json.loads(line))
                except ValueError:
                    pass  # The writer may still be appending the last event.
        return result

    def compacted_and_continued(history):
        compacted = next((i for i, event in enumerate(history) if event.get("type") == "compacted"), None)
        if compacted is None:
            return False
        later = history[compacted + 1:]
        return (any(event.get("type") == "response_item" and event.get("payload", {}).get("role") == "assistant" for event in later)
                and any(event.get("payload", {}).get("type") == "task_complete" and not event["payload"].get("error") for event in later))

    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", str(wrapper), "session", prompt])
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    output = b""
    clean = b""
    answered = False
    continued = False
    followup_sent = False
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
            if compact and not answered:
                history = events()
                if not followup_sent and any(event.get("payload", {}).get("type") == "task_complete" for event in history):
                    os.write(terminal, b"\x1b[200~Say hello again.\x1b[201~")
                    time.sleep(0.2)
                    os.write(terminal, b"\r")
                    followup_sent = True
                ready = compacted_and_continued(history)
            else:
                ready = b"Claude answer" in clean
            if ready and not answered:
                answered = True
                os.write(terminal, b"\x03")
                time.sleep(0.3)
                os.write(terminal, b"\x03")
                deadline = time.monotonic() + 5
        if not answered:
            sys.exit("Native Codex did not receive the fixture response:\n" + (clean[:2000] + b"\n...\n" + clean[-3000:]).decode(errors="replace"))
        if compact:
            if not compacted_and_continued(events()):
                sys.exit("Native Codex did not automatically compact and continue the fixture conversation.")
            print("Native Codex automatically compacted and continued through CCR.")
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
