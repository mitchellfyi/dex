#!/usr/bin/env python3
"""Recognize a provider's compaction-thrashing stop without exposing its text."""
import json
import os
import stat
import sys


def thrashing(payload):
    text = payload.get('last_assistant_message')
    if isinstance(text, str) and text.strip():
        return text.lstrip().startswith('Autocompact is thrashing:')
    file = payload.get('transcript_path')
    if not isinstance(file, str) or not file:
        return False
    descriptor = os.open(file, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return False
        handle.seek(max(0, info.st_size - 512 * 1024))
        lines = handle.read().splitlines()
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get('type') == 'user':
            return False
        if row.get('type') != 'assistant':
            continue
        if payload.get('session_id') and row.get('sessionId') != payload['session_id']:
            return False
        message = row.get('message', {})
        return message.get('model') == '<synthetic>' and any(
            isinstance(block, dict) and isinstance(block.get('text'), str)
            and block['text'].lstrip().startswith('Autocompact is thrashing:')
            for block in message.get('content', []) if isinstance(message.get('content'), list))
    return False


if __name__ == '__main__':
    try:
        payload = json.loads(sys.stdin.read(1024 * 1024))
        detected = isinstance(payload, dict) and thrashing(payload)
    except (OSError, ValueError, TypeError, AttributeError):
        print('Dex context check could not read the stop evidence; normal lifecycle checks remain active.', file=sys.stderr)
        detected = False
    sys.exit(0 if detected else 1)
