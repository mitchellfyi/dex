---
name: dxmodel
description: Select the model for the next request in the current Dex routed Claude Code session.
---

Read `bash "$DEX_DIR/bin/router.sh" route status` and
`bash "$DEX_DIR/bin/router.sh" model list`.

If the user supplied a model, resolve it to exactly one listed provider/model
identifier and run `bash "$DEX_DIR/bin/router.sh" route use <provider/model>`.
Use `--scope phase` only when requested; the default override lasts for this
session. For `auto`, run `route use auto` to restore the configured phase policy.
If the name is ambiguous or absent, show the available choices and ask the
user to choose. Pass arguments as quoted values, never as shell source.

The change applies to the next model request. It cannot replace a response
that is already streaming. Keep the same Claude Code conversation and Dex
lifecycle. Do not change authentication variables or edit provider tokens.
