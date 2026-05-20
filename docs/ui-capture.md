# UI Capture

Doyaken can capture visual evidence for browser-facing changes. The default path is automatic: if Phase 2 changes UI code, `/dkimplement` invokes `/dkuicapture` before UI edits for baseline evidence and again after implementation before review. Phase 5 (`/dkpr`) refreshes after evidence when needed and hands the user upload-ready files for the PR.

## What It Captures

- Desktop and mobile screenshots
- Playwright trace ZIPs
- WebM video for interactive flows
- Console, page, network, and HTTP error logs
- Metadata linking each artifact to the captured URL
- `visual-evidence.md`, a concise before/after manifest for PR upload handoff

Artifacts are written outside the repo:

```text
~/.claude/.doyaken-artifacts/ui/<session>/
```

Override with `DK_ARTIFACT_DIR`. These files are evidence, not source, and should not be committed. If the capture output path is inside the repo, `ui-capture.sh` refuses to write unless that path is gitignored.

GitHub does not render local artifact paths as images. Doyaken gives the user the manifest and local file paths, then the user uploads before/after screenshots manually to the PR body or a PR comment.

## Setup

`dk install`, `dk init`, `dk sync`, and `dk tools bootstrap` install or repair the browser tooling:

- Playwright in `~/.claude/.doyaken-tools/ui-capture/`
- Playwright MCP for Claude and Codex when those CLIs are installed
- Chrome DevTools MCP for Claude and Codex when those CLIs are installed

Check status:

```bash
dk status
```

Repair manually:

```bash
bash "$DOYAKEN_DIR/bin/ui-capture.sh" --install-only
```

## Before/After Workflow

For UI-affecting tasks:

1. Phase 2 captures `before-*` routes or flows before UI files are edited.
2. Phase 2 captures matching `after-*` routes or flows once implementation is complete.
3. Phase 5 refreshes after evidence if UI code changed after the last capture.
4. The user uploads the local before/after screenshots from `visual-evidence.md` after the draft PR exists.

If a before capture is impossible because UI files were already modified, the manifest records:

```text
Before capture: unavailable — UI was already modified before capture.
```

## Manual Capture

Start the app with the repo's normal dev command, then run:

```bash
bash "$DOYAKEN_DIR/bin/ui-capture.sh" \
  --url "http://127.0.0.1:3000" \
  --name "before-home-page" \
  --desktop \
  --mobile \
  --trace
```

For interactions, add `--video` and a flow file stored outside the repo:

```js
module.exports = async ({ page, screenshot }) => {
  await page.getByRole('button', { name: /open/i }).click();
  await screenshot('opened');
  await page.getByRole('button', { name: /save/i }).click();
  await screenshot('saved');
};
```

```bash
bash "$DOYAKEN_DIR/bin/ui-capture.sh" \
  --url "http://127.0.0.1:3000/settings" \
  --name "settings-flow" \
  --desktop \
  --mobile \
  --video \
  --trace \
  --flow "$HOME/.claude/.doyaken-artifacts/ui/manual/settings-flow.cjs"
```

The command prints absolute paths for the screenshots, traces, videos, metadata, logs, and session manifest. It also appends the capture run to `visual-evidence.md`. Use those paths as markdown links in the Phase 2 evidence.

## Logs

Each run writes:

| File | Meaning |
|------|---------|
| `console-errors.log` | Browser console warnings/errors |
| `page-errors.log` | Unhandled page exceptions |
| `network-errors.log` | Failed requests |
| `http-errors.log` | HTTP responses with status 400+ |
| `metadata.json` | URLs, viewport names, and artifact paths |
| `visual-evidence.md` | Session-level before/after manifest for the user to upload screenshots to the PR |

Fix real runtime issues before Phase 2 completes. If an entry is expected or unrelated, note why in the evidence.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Node.js, npm, and npx are required` | Install Node.js, then rerun `dk install` |
| MCP servers are incomplete | Run `bash "$DOYAKEN_DIR/bin/ui-capture.sh" --install-only` |
| App is not reachable | Start the dev server first and use the printed local URL |
| Video is missing | Pass `--video`; video files are written after the browser context closes |
| Trace will not open | Use Playwright Trace Viewer, or rerun with `--trace` if the ZIP is missing |
