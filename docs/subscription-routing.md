# Optional subscription routing

Dex's direct Claude Code and Codex profiles work without Claude Code Router.
The optional routed profile uses the full `musistudio/claude-code-router` CLI
and a Dex extension. The initial compatibility target is CCR 3.1.0 with
`@the-next-ai/ai-gateway` 1.0.21.

Implementation is in progress. The extension owns independent OAuth accounts,
session policy, quota snapshots, and refresh coordination. CCR owns protocol
conversion and the optional local diagnostic dashboard. Runtime support must
pass the compatibility tests before release; real OAuth acceptance remains a
separate manual check.

## Verification strategy

Cover policy and state with Node's built-in test runner; cover command dispatch,
native login helpers, credential isolation, concurrent refresh, and process
recovery with isolated integration tests. A real pinned CCR process must pass
the local gateway smoke test with synthetic provider credentials. Direct
provider tests must continue to pass without installing the optional runtime.

Browser proof: N/A. This change adds terminal flows and reuses CCR's existing
dashboard without modifying its browser UI.
