#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/tests/helpers.sh"
python3 -m unittest discover -s "$ROOT/tests/maintenance-intake" -p '*_test.py' -v
