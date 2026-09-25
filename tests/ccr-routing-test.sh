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
# These suites drive the same modules that own the developer's live router
# state and native client settings. run-all.sh hands every test a fake HOME, so
# `~/.dex/router`, `~/.claude` and `~/.codex` already resolve inside a sandbox
# there. Run standalone — which AGENTS.md tells agents to do for one surface —
# they would reach the real ones, protected only by each suite remembering to
# set DEX_ROUTER_HOME. Pin the sandbox here so the wrapper is safe either way.
if [[ -z "${DEX_ROUTER_HOME:-}" ]]; then
  DEX_CCR_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/dex-ccr-suite.XXXXXX")
  trap 'rm -rf "$DEX_CCR_SANDBOX"' EXIT
  export DEX_ROUTER_HOME="$DEX_CCR_SANDBOX/router"
  export CLAUDE_CONFIG_DIR="$DEX_CCR_SANDBOX/claude"
  export CODEX_HOME="$DEX_CCR_SANDBOX/codex"
  mkdir -p "$DEX_ROUTER_HOME" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"
fi

node --test tests/ccr-accounts.test.cjs tests/ccr-policy.test.cjs tests/ccr-cli.test.cjs tests/ccr-context.test.cjs tests/ccr-mcp.test.cjs tests/ccr-metrics.test.cjs tests/ccr-service.test.cjs tests/ccr-reload.test.cjs tests/ccr-core-plugin.test.cjs tests/ccr-history.test.cjs tests/ccr-native.test.cjs tests/ccr-runtime.test.cjs
