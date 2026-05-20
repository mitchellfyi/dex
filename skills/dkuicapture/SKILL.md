---
name: "dkuicapture"
description: "Capture UI screenshots, Playwright traces, videos, and browser error logs for UI-affecting changes."
---

# Skill: dkuicapture

Capture before/after visual evidence for browser-facing work.

## When to Use

- At the start of `/dkimplement`, before editing UI files, when the approved plan affects web UI, routes, components, styles, browser behavior, or user flows
- After `/dkimplement` finishes UI-affecting changes, before Phase 2 hands off to review
- During `/dkpr` when a UI change needs final after-capture evidence for PR handoff
- When a ticket asks for visual verification, screenshots, or video
- When debugging UI regressions with Playwright MCP or Chrome DevTools MCP

If the change does not affect UI, record `UI capture: N/A — no UI-affecting files changed` in the implementation evidence and stop.

## Artifact Rules

- Do **not** commit screenshots, videos, traces, generated flow scripts, logs, or visual evidence manifests.
- Store artifacts only under Doyaken's artifact directory:
  - default: `~/.claude/.doyaken-artifacts/ui/<session>/`
  - override: `DK_ARTIFACT_DIR`
- Keep a concise manifest at `$(dk_ui_capture_manifest_file "$session_id")`, usually `~/.claude/.doyaken-artifacts/ui/<session>/visual-evidence.md`.
- If `DK_ARTIFACT_DIR` is overridden to a path inside the repo, verify it is ignored before writing artifacts:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
artifact_root="$(dk_artifacts_dir)"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$repo_root" ]]; then
  case "$artifact_root" in
    "$repo_root"/*)
      git check-ignore -q "$artifact_root" || {
        printf 'UI artifact directory is inside the repo and is not ignored: %s\n' "$artifact_root" >&2
        exit 1
      }
      ;;
  esac
fi
```

- Local artifact links do not render for GitHub reviewers. Use them to hand the user upload-ready files; the user must upload the screenshots manually to the PR body or a PR comment.

## Steps

### 1. Ensure Tooling

Run the Doyaken bootstrap. It installs Playwright into Doyaken's tool cache and configures both Playwright MCP and Chrome DevTools MCP for Claude/Codex where the CLIs are available.

```bash
bash "${DOYAKEN_DIR:-$HOME/work/doyaken}/bin/ui-capture.sh" --install-only
```

If this fails because Node.js/npm/npx are missing or network install is blocked, stop and tell the user the exact prerequisite or command that failed. Otherwise, proceed without asking; Doyaken owns this tooling and keeps it outside the project repo.

### 2. Decide Whether UI Capture Is Required

Check the approved plan and changed files:

```bash
git diff --name-only
git diff --stat
```

Treat these as UI-affecting by default:

- Frontend source under directories such as `src/`, `app/`, `pages/`, `components/`, `routes/`, `views/`, `client/`, `web/`
- CSS, Sass, Tailwind, styled components, templates, Storybook stories
- Browser-side JS/TS/React/Vue/Svelte/Solid/Astro/Next/Remix changes
- API changes whose acceptance criteria include visible UI behavior

If only backend/CLI/docs/test-only files changed and no visible browser behavior is affected, record N/A.

### 3. Prepare Artifact Tracking

Create the session artifact directory outside the repo. `bin/ui-capture.sh` creates and appends to the manifest automatically on each capture run:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
session_id="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
capture_dir="$(dk_ui_capture_session_dir "$session_id")"
manifest="$(dk_ui_capture_manifest_file "$session_id")"
mkdir -p "$capture_dir"
printf '%s\n' "$manifest"
```

Manifest template:

```markdown
# Visual Evidence

Session: <session_id>
PR: <pending or PR URL>
Upload note: local files do not render in GitHub; upload before/after screenshots manually to the PR body or a PR comment.

## Before

- <label> desktop: [desktop.png](/absolute/path/to/desktop.png)
- <label> mobile: [mobile.png](/absolute/path/to/mobile.png)

## After

- <label> desktop: [desktop.png](/absolute/path/to/desktop.png)
- <label> mobile: [mobile.png](/absolute/path/to/mobile.png)

## Verification

- URL/flow parity: yes/no
- Console/page/network/http logs checked: yes/no
- Notes: <expected or unrelated log entries, unavailable captures, reviewer upload instructions>
```

Keep manual notes in the manifest short. It is a user handoff file, not a full implementation report.

### 4. Start the App

Use the project's existing commands. Prefer the package manager and scripts already in the repo:

- `npm run dev`, `pnpm dev`, `yarn dev`, `bun dev`
- `npm run start`, `pnpm start`, `yarn start`, `bun start`
- framework-specific scripts already present in `package.json`
- existing Storybook scripts if the changed UI is component-only

Run the server in the background, wait for the local URL to return a response, and stop the server after capture. Use a different port if the default is occupied.

### 5. Capture Before Evidence

When called at the start of Phase 2 for a UI-affecting plan, capture before editing UI surfaces. Use stable names so the later after capture can match them:

```bash
bash "${DOYAKEN_DIR:-$HOME/work/doyaken}/bin/ui-capture.sh" \
  --url "http://127.0.0.1:3000/path" \
  --name "before-route-name" \
  --desktop \
  --mobile \
  --trace
```

If UI files were already modified before the baseline could be captured, do not fake a before screenshot. Record this in the manifest and Phase 2 evidence:

```text
Before capture: unavailable — UI was already modified before capture.
```

### 6. Capture After Evidence

After implementation, capture the same representative routes, viewports, and flows as the before pass wherever possible. Use matching names:

```bash
bash "${DOYAKEN_DIR:-$HOME/work/doyaken}/bin/ui-capture.sh" \
  --url "http://127.0.0.1:3000/path" \
  --name "after-route-name" \
  --desktop \
  --mobile \
  --trace
```

Inspect the generated logs for every run:

- `console-errors.log`
- `page-errors.log`
- `network-errors.log`
- `http-errors.log`
- `metadata.json`

Fix real UI/runtime issues before Phase 2 completion. If a log entry is expected or unrelated, document why in the manifest and evidence.

### 7. Capture Video for Interactive Flows

For changed flows involving clicks, forms, navigation, drag/drop, modals, menus, uploads, checkout, auth, onboarding, or other interactions, record video and trace.

Create the flow file inside the artifact directory, never in the repo:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
session_id="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
flow_dir="$(dk_ui_capture_session_dir "$session_id")/flows"
mkdir -p "$flow_dir"
```

Flow file template:

```js
module.exports = async ({ page, screenshot }) => {
  await page.getByRole('button', { name: /open/i }).click();
  await screenshot('after-open');
  await page.getByRole('button', { name: /save/i }).click();
  await screenshot('after-save');
};
```

Then capture with video:

```bash
bash "${DOYAKEN_DIR:-$HOME/work/doyaken}/bin/ui-capture.sh" \
  --url "http://127.0.0.1:3000/path" \
  --name "after-flow-name" \
  --desktop \
  --mobile \
  --video \
  --trace \
  --flow "$flow_dir/flow-name.cjs"
```

The generated `.webm` files are the video evidence. The `.zip` traces can be opened with Playwright Trace Viewer.

### 8. Use MCP When Helpful

The bootstrap configures:

- Playwright MCP (`playwright`) for agent-controlled browser actions
- Chrome DevTools MCP (`chrome-devtools`) for console, network, performance, and live browser inspection

Use MCP tools when they are available in the session and they make debugging faster. The deterministic artifact command above remains the canonical evidence because it stores files in Doyaken's artifact directory.

### 9. Verify Evidence

Do not mark UI capture complete until:

- each referenced screenshot/video/trace exists and is non-empty
- before and after captures use the same URL, route, viewport, and flow where possible
- logs have been checked and real runtime issues are fixed
- the manifest lists before evidence, after evidence, or an explicit before-unavailable reason
- artifacts are outside the repo or the artifact directory is ignored

### 10. Report Evidence

Report artifacts as absolute markdown links:

```markdown
UI capture:
- Manifest: [visual-evidence.md](/absolute/path/to/visual-evidence.md)
- Before desktop: [desktop.png](/absolute/path/to/before/desktop.png)
- After desktop: [desktop.png](/absolute/path/to/after/desktop.png)
- Mobile screenshot: [mobile.png](/absolute/path/to/after/mobile.png)
- Video: [desktop video](/absolute/path/to/video.webm)
- Trace: [desktop trace](/absolute/path/to/desktop-trace.zip)
- Logs: [metadata.json](/absolute/path/to/metadata.json)
```

For PR handoff, tell the user that the manifest contains local upload-ready files and that GitHub requires manual upload for images to render to reviewers.
