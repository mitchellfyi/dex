#!/usr/bin/env bash
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/helpers.sh"
cd "$TEST_DIR/.."
if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then
  printf '%s\n' 'SKIP: optional CCR tests require Node 22+'
  exit 0
fi
node --test tests/ccr-accounts.test.cjs tests/ccr-policy.test.cjs tests/ccr-cli.test.cjs tests/ccr-runtime.test.cjs
