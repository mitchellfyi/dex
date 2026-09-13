#!/usr/bin/env python3
"""Run one test with a deadline and clean up its process group before returning."""

import argparse
import os
import signal
import subprocess
import time


def stop_group(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        child.poll()
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)

    # A child may ignore TERM even after the test shell has exited.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.seconds <= 0 or not args.command:
        parser.error("a positive timeout and a command are required")

    interrupted = 0

    def request_stop(signum, _frame):
        nonlocal interrupted
        interrupted = signum

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, request_stop)

    try:
        child = subprocess.Popen(args.command, start_new_session=True)
    except OSError as error:
        parser.exit(2, f"could not start test: {error}\n")

    deadline = time.monotonic() + args.seconds
    try:
        while child.poll() is None:
            if interrupted:
                return 128 + interrupted
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print(f"test exceeded its {args.seconds}s timeout; stopping its process group", flush=True)
                return 124
            try:
                child.wait(timeout=min(remaining, 0.1))
            except subprocess.TimeoutExpired:
                pass
        if interrupted:
            return 128 + interrupted
        return child.returncode if child.returncode >= 0 else 128 - child.returncode
    finally:
        stop_group(child)
        child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
