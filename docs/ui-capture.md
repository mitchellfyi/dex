# UI Proof

Dex can turn a browser-facing change into a short, editable PR walkthrough. It also lets the implementation agent decide that a recording would not help. The important contract is an explicit, visible decision—not a video made for its own sake.

Run `/dxproof` whenever you want the full visual artifact on demand. `/dxcapture` is an alias. Both commands inspect committed and working-tree changes against the branch's comparison base, reconstruct the old revision in a temporary Git worktree, and capture matched before and after flows. The final bundle includes the combined MP4, captions, poster, editable storyboard, screenshots, traces, and browser logs. The older `/dxuicapture` entrypoint remains available for lifecycle capture decisions and uses the same shared workflow.

Manual proof is different from the lifecycle decision below: an explicit `/dxproof` or `/dxcapture` request captures the artifact unless the diff has no browser-visible effect or the flow cannot be reproduced safely. A blocked manual capture stays `NEEDS_REVIEW` with the reason; it is not converted into a discretionary skip.

## Decision states

Every lifecycle can carry one UI proof state:

| State | Meaning |
|---|---|
| `READY` | A reviewed walkthrough bundle is ready for handoff. |
| `NEEDS_REVIEW` | Capture was selected, but the bundle is incomplete or missed a production check. |
| `SKIPPED` | Browser UI changed, but the agent judged that a walkthrough would not improve the review and recorded why. |
| `N/A` | The change has no browser-rendered impact. |
| `MISSING` | No decision has been recorded. |

These states are advisory. A reasoned `SKIPPED` decision is valid and does not fail a phase. UI proof also does not replace automated tests or the manual smoke test.

Use capture for interactions, navigation, scrolling, state changes, responsive behavior, visual regressions, or anything a reviewer understands faster by seeing. Skip it for a trivial visual adjustment, an unsafe or irreproducible environment, or a case where a different focused artifact is clearer. Use N/A only when nothing changes in the browser.

Record and inspect decisions:

```bash
dx ui-capture skip --reason "The one-word label change is clearer in the focused screenshot and test."
dx ui-capture not-applicable --reason "This change only affects the CLI parser."
dx ui-capture show
dx ui-capture show --json
```

Dex prints the state in Phase 2 and later lifecycle headers. `dx status` shows the current checkout's state. This keeps the artifact visible after capture instead of burying its path in an agent session.

## Output

The structured producer writes a compact bundle:

```text
~/.claude/.dex-artifacts/ui/<session>/
  evidence.json
  walkthrough.json
  walkthrough.mp4
  poster.png
  transcript.md
  captions.vtt
  visual-evidence.md
  bundle.json
  <timestamp>-<pid>-before-*/
  <timestamp>-<pid>-after-*/
```

Each raw run contains its screenshot, Playwright trace, WebM source video, metadata, and console, page, network, and HTTP error logs. Set `DX_ARTIFACT_DIR` to move the root. Dex refuses an output directory inside the repository unless Git ignores it.

Generated files are temporary evidence and must not be committed. During an active lifecycle, the compact bundle is also registered in the run journal. Each artifact carries its capture session and role, so DexCode can pair the walkthrough with its poster and captions. If DexCode sync is connected, normal run-artifact sync uploads the bundle and DexCode shows supported images and videos on the session page. Local paths still do not render on GitHub; the author drags the MP4 and poster into the PR body or a comment.

An agent can use an existing project recorder, MCP browser, or another suitable tool and still join the evidence workflow:

```bash
dx ui-capture ready \
  --manifest /absolute/path/to/visual-evidence.md \
  --video-file /absolute/path/to/walkthrough.mp4 \
  --poster-file /absolute/path/to/poster.png \
  --reason "The project recorder produces the clearest native walkthrough."
```

The manifest is required; the MP4 and poster are optional. Dex copies supplied files into the temporary session bundle, records `READY`, and registers them with the active run. The agent should review those files to the same quality bar as a structured capture.

## Tooling

Dex installs pinned packages into `~/.claude/.dex-tools/ui-capture/`:

- Playwright and Chromium for deterministic capture
- `ffmpeg-static` for MP4 production and compression
- `kokoro-js` with Kokoro-82M for optional local narration

It also configures Playwright MCP and Chrome DevTools MCP for installed Claude and Codex CLIs. MCP is useful for exploration and debugging; the structured command remains the simplest repeatable artifact path.

Install or repair the tools:

```bash
dx ui-capture install
dx status
```

The speech model is loaded locally and does not need a cloud API key. When narration is disabled or synthesis fails, Dex keeps a captioned MP4 and can still report `READY` if the other production checks pass.

## Storyboard

`walkthrough.json` is the editable source for both browser actions and narration. It also carries the context a PR reviewer needs:

- product problem and impact
- technical summary
- how to test the change
- target and maximum duration
- before and after chapters
- narration and deterministic browser actions

The structured action vocabulary is deliberately small: `goto`, `click`, `fill`, `press`, `hover`, `scroll`, `wait`, `assert`, and `screenshot`. Locators use accessible roles, labels, visible text, or test IDs. This covers normal user flows without allowing arbitrary JavaScript in a generated storyboard. Existing explicit `--flow` modules remain available for unstructured and unusual flows.

A minimal storyboard looks like this:

```json
{
  "version": 1,
  "name": "settings-save",
  "title": "Save notification settings",
  "summary": "Shows the clearer saved-state confirmation.",
  "product_context": "People need confidence that their preference was saved.",
  "technical_summary": "The form persists the request and renders its successful state.",
  "how_to_test": "Open settings, change email notifications, save, and confirm the saved state.",
  "comparison": "before_after",
  "target_seconds": 55,
  "max_seconds": 90,
  "chapters": [
    {
      "stage": "before",
      "title": "Before",
      "narration": "Saving previously gave no clear confirmation.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}}
      ]
    },
    {
      "stage": "after",
      "title": "After",
      "narration": "The same flow now confirms the saved preference.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "scroll", "locator": {"by": "label", "name": "Email notifications"}},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}},
        {"action": "assert", "locator": {"by": "text", "name": "Settings saved"}}
      ]
    }
  ]
}
```

Use `"comparison": "after_only"` with a non-empty `baseline_reason` when a before state did not exist or cannot truthfully be reproduced. The validator still requires an after chapter.

Validate the script before capture:

```bash
dx ui-capture validate --script /absolute/path/to/walkthrough.json
```

Validation rejects unknown actions, unsafe locator keys, a transcript whose estimated reading time exceeds the maximum, or a maximum above 90 seconds.

## Capture workflow

Start the baseline app using the repository's normal development command. Capture before implementation when it adds useful comparison:

```bash
dx ui-capture capture \
  --stage before \
  --script /absolute/path/to/walkthrough.json \
  --url http://127.0.0.1:3000
```

The recorder draws a stable stage badge, chapter caption, pointer, and focus highlight. Storyboard actions can navigate, scroll, and interact with the UI. Playwright captures the final screenshot, source video, trace, and browser logs.

Run `dx ui-capture show` after the baseline. This gives the author the evidence file immediately, while the after pass is still pending.

After implementation, start the changed app and run the same script:

```bash
dx ui-capture capture \
  --stage after \
  --script /absolute/path/to/walkthrough.json \
  --url http://127.0.0.1:3000
```

The after pass produces the final MP4, poster, transcript, captions, and manifest. Add `--mobile` when responsive behavior matters. Add `--no-narration` for an intentional captions-only cut.

Aim for 30–75 seconds. Ninety seconds is a hard limit. The final producer checks real media duration and tries a second compression pass above 10 MiB. It reports `NEEDS_REVIEW` when duration, size, missing source footage, or media tooling prevents a clean handoff.

## Revision

The agent or human can edit `walkthrough.json` after the first render. Reproduce only stages whose actions or on-screen script changed, then render again:

```bash
dx ui-capture revise \
  --script /absolute/path/to/walkthrough.json \
  --before-url http://127.0.0.1:3000 \
  --after-url http://127.0.0.1:3001
```

Omit a URL when that stage still matches the current storyboard. An after-only script never needs `--before-url`. Review the complete MP4 after every revision; generated transcripts and captions are outputs, while the storyboard remains the source of truth.

## Quality bar

A PR walkthrough should be understandable on its first viewing:

- open with the user problem, not the development setup
- show one representative route and state
- navigate and scroll naturally
- highlight a control before interacting with it
- hold on the result long enough to read it
- keep unrelated screens, terminals, delays, secrets, and personal data out
- explain product impact, the technical change, and how to test it in the transcript and manifest
- inspect the console, page, request, and HTTP logs
- play the final MP4 from beginning to end

The video is proof that a flow was exercised and observed. It is not proof that every acceptance criterion passed.

## Raw capture compatibility

The original free-form command still works:

```bash
dx ui-capture capture \
  --url http://127.0.0.1:3000/settings \
  --name settings-flow \
  --desktop --mobile --video --trace \
  --flow /absolute/path/to/flow.cjs
```

Raw captures append to `visual-evidence.md` and report `NEEDS_REVIEW` until the agent reviews them and either produces a concise walkthrough or records a reasoned skip. A flow module runs trusted local JavaScript, so use it only when the structured action vocabulary cannot express the path.

## Retention

Dex marks the evidence state completed when the lifecycle reaches terminal completion. `dxclean` and the dedicated command remove completed bundles after 30 days by default:

```bash
dx ui-capture clean
dx ui-capture clean --older-than 14
```

Set `DX_UI_CAPTURE_RETENTION_DAYS` to an integer from 1 through 3650. Active bundles are never removed by age. Cleanup examines only direct, non-symlinked session directories with valid completed evidence metadata.

## Troubleshooting

| Symptom | Action |
|---|---|
| UI tools are incomplete | Run `dx ui-capture install`, then `dx status`. |
| The app is unreachable | Start its normal dev server and pass the printed HTTP(S) URL. |
| Narration fails | Keep the captions-only result or rerun with `--no-narration`. |
| The MP4 is too long | Remove setup steps or split the storyboard into a more focused proof. |
| The MP4 is too large | Shorten the flow; Dex already attempts a higher-compression pass. |
| A locator is ambiguous | Prefer an accessible role and exact name, then a label or stable test ID. |
| The final state changed after capture | Edit the storyboard and run `dx ui-capture revise` with the affected URL. |
| GitHub shows broken local links | Drag the MP4 and poster into the PR body or comment. |
