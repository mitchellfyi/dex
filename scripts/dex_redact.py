"""Canonical secret redaction for Dex run logs, events, and artifacts.

The same patterns were copy-pasted into several inline heredocs in
lib/events.sh and a weaker variant in lib/factory.sh, and the copies had
already diverged — the factory one was missing the raw ghp_/sk-/xox token
patterns. Redaction is only as good as its weakest copy, so it lives here.

Imported by adding scripts/ to PYTHONPATH:

    PYTHONPATH="$DEX_DIR/scripts" python3 -c 'import dex_redact'

Standard library only, to match hooks/guard-handler.py.
"""

import re
from datetime import datetime, timezone

SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+"),
    re.compile(
        r"(?i)(\b(?!authorization\b)[A-Z0-9_]*"
        r"(?:TOKEN|SECRET|PASSWORD|PASS|API[_-]?KEY|AUTH)[A-Z0-9_]*\s*[=:]\s*)"
        r"([\"']?)[^\"'\s]+"
    ),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{16,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
]
SECRET_URL_RE = re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@")


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def redact(text):
    """Mask credentials in free text, preserving surrounding structure."""
    text = SECRET_URL_RE.sub(r"\1[REDACTED]@", text)
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1\2[REDACTED]", text)
    for pattern in SECRET_PATTERNS[2:]:
        text = pattern.sub("[REDACTED]", text)
    return text


def log_line(level, source, message):
    """Format one redacted run-log line."""
    return "[{ts}] [{level}] [{source}] {message}\n".format(
        ts=utc_now(),
        level=level or "info",
        source=source or "dex",
        message=redact(message or ""),
    )
