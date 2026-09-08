#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/review-check-cache-test.py"
