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
SECRET_KEY_RE = re.compile(r"(?i)(token|secret|password|passwd|api[_-]?key|credential)")

# Usage counters are named like secrets but carry no credential.
TOKEN_COUNT_KEYS = {
    "total_input_tokens",
    "total_output_tokens",
    "total_cache_read_tokens",
    "total_cache_write_tokens",
}

# Patterns for credentials that are recognizable on their own, with no
# surrounding key or header to anchor them.
RAW_TOKEN_PATTERNS = SECRET_PATTERNS[2:]


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


def redact_raw_tokens(text, marker="[REDACTED]"):
    """Mask self-identifying credentials only.

    For callers that already redact keyed fields their own way and just need
    the raw token classes covered, with their own marker casing.
    """
    for pattern in RAW_TOKEN_PATTERNS:
        text = pattern.sub(marker, text)
    return text


def redact_value(value, key=""):
    """Recursively redact a JSON-like structure by key name and by content."""
    normalized_key = str(key).lower().replace("-", "_")
    auth_key = (
        normalized_key in {"auth", "authorization"}
        or normalized_key.startswith("auth_")
        or normalized_key.endswith("_auth")
        or "_auth_" in normalized_key
    )
    if normalized_key in TOKEN_COUNT_KEYS:
        return value
    if SECRET_KEY_RE.search(str(key)) or auth_key:
        return "[REDACTED]" if value else value
    if isinstance(value, dict):
        return {item_key: redact_value(item_value, item_key) for item_key, item_value in value.items()}
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, str):
        return redact(value)
    return value


def log_line(level, source, message):
    """Format one redacted run-log line."""
    return "[{ts}] [{level}] [{source}] {message}\n".format(
        ts=utc_now(),
        level=level or "info",
        source=source or "dex",
        message=redact(message or ""),
    )
