---
name: "dxuicapture"
description: "Decide whether a UI change needs visual proof, then capture and produce a short, editable browser walkthrough when it adds reviewer value."
---

# Skill: dxuicapture

Treat visual proof as a review artifact, not ceremony. Make an explicit decision, produce a concise walkthrough when it helps, and surface the result while it is still useful.

## 1. Make the decision

Read the task, approved plan, and changed files. Choose one outcome:

- **Capture** when seeing the change would materially help a reviewer: new or changed interactions, navigation, scrolling, state transitions, responsive behavior, layout, styling, validation, onboarding, checkout, uploads, menus, modals, or a visual regression.
- **Skip** when browser behavior changed but a video would add little or cost more than it clarifies. Examples include a tiny copy or icon adjustment, an environment that cannot safely reproduce the flow, or an existing focused artifact that proves the same thing better.
- **N/A** when there is no browser-rendered impact.

The agent owns this judgment. A ticket can ask for visual proof explicitly; that makes capture the default unless it is unsafe or impossible. Otherwise, use the smallest artifact that raises reviewer confidence. Do not record N/A for a visible change, and do not make a token video just to satisfy a checklist.

Record a non-capture decision immediately:

```bash
dx ui-capture skip --reason "<why a walkthrough would not improve this review>"
dx ui-capture not-applicable --reason "<why there is no browser UI impact>"
```

Dex surfaces `READY`, `NEEDS_REVIEW`, `SKIPPED`, `N/A`, or `MISSING` in lifecycle headers and `dx status`. These states are advisory: `SKIPPED` does not fail a phase, but `MISSING` means no decision has been recorded.

## 2. Choose the proof

When capture is worthwhile, prefer one representative flow over a tour of the whole product. The default is a matched before/after walkthrough. Use `after_only` when the feature had no meaningful baseline or the old state cannot be reproduced; put the reason in `baseline_reason`.

The agent may choose:

- the route and seeded state that best explain the change
- desktop only or desktop plus mobile
- the shortest useful set of clicks, form input, navigation, and scrolling
- local narration or captions only
- the structured recorder below, an existing safe Playwright flow, or browser MCP tools

The structured recorder is preferred for PR proof because it creates an editable storyboard, transcript, captions, video, screenshots, trace, browser logs, and manifest in one bundle. MCP tools remain useful for exploration and debugging.

If an existing project recorder or browser tool produces the clearest artifact, register it without forcing it through the structured producer:

```bash
dx ui-capture ready \
  --manifest /absolute/path/to/visual-evidence.md \
  --video-file /absolute/path/to/walkthrough.mp4 \
  --poster-file /absolute/path/to/poster.png \
  --reason "The project recorder preserves its native interaction markers."
```

Only the manifest is required. Dex copies supplied files into the temporary session bundle, surfaces them, and attaches them to the active run. This is the escape hatch for sound agent judgment, not a way to label unreviewed footage `READY`.

## 3. Write the storyboard before capture

Store the JSON outside the repository:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
session_id="${DEX_SESSION_ID:-$(dx_session_id)}"
storyboard="$(dx_ui_capture_storyboard_file "$session_id")"
mkdir -p "$(dirname "$storyboard")"
printf '%s\n' "$storyboard"
```

Use this shape:

```json
{
  "version": 1,
  "name": "settings-save",
  "title": "Save notification settings",
  "summary": "Shows the clearer saved-state confirmation.",
  "product_context": "People need confidence that their preference was saved.",
  "technical_summary": "The form now persists the request and renders its successful state.",
  "how_to_test": "Open settings, change email notifications, save, and confirm the saved state.",
  "comparison": "before_after",
  "target_seconds": 55,
  "max_seconds": 90,
  "chapters": [
    {
      "stage": "before",
      "title": "Before",
      "narration": "Before this change, saving gave no clear confirmation.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}}
      ]
    },
    {
      "stage": "after",
      "title": "After",
      "narration": "Now the same flow confirms the saved preference and stays ready for another edit.",
      "actions": [
        {"action": "goto", "path": "/settings"},
        {"action": "scroll", "locator": {"by": "label", "name": "Email notifications"}},
        {"action": "click", "locator": {"by": "label", "name": "Email notifications"}},
        {"action": "click", "locator": {"by": "role", "role": "button", "name": "Save"}},
        {"action": "assert", "locator": {"by": "text", "name": "Settings saved"}}
      ]
    }
  ]
}
```

For `after_only`, remove the before chapters and add:

```json
"comparison": "after_only",
"baseline_reason": "The user flow did not exist before this change."
```

Allowed actions are `goto`, `click`, `fill`, `press`, `hover`, `scroll`, `wait`, `assert`, and `screenshot`. Locators may use accessible role, label, visible text, or test ID. Use `env` instead of `text` for sensitive form values. Arbitrary browser evaluation is deliberately unavailable in structured storyboards.

Validate before starting the app:

```bash
dx ui-capture validate --script "$storyboard"
```

## 4. Meet the production bar

Aim for 30–75 seconds; 90 seconds is the hard limit. A strong walkthrough usually has two to five short chapters and fewer than 190 spoken words.

The final cut should:

- establish the user problem in one sentence
- show the relevant before state when it adds context
- navigate and scroll naturally instead of jumping between unexplained screens
- visibly point to the control before interacting with it
- show the resulting state long enough to understand it
- explain product impact, the technical change, and how to test it in the transcript and manifest
- avoid unrelated setup, loading time, editor windows, terminals, notifications, secrets, and personal data

Use seeded local data and the project's normal development command. Keep the window stable. Do not rush clicks, shake the pointer, or narrate implementation trivia that a reviewer can read in the diff.

## 5. Capture and produce

Install the pinned browser, media, and optional local narration tools when needed:

```bash
dx ui-capture install
```

Start the baseline version of the app, then capture before changing UI files:

```bash
dx ui-capture capture \
  --stage before \
  --script "$storyboard" \
  --url "http://127.0.0.1:3000"
```

Run `dx ui-capture show` immediately and share the printed evidence path in your progress update. Then implement the change, start the updated app, and capture the matching flow:

```bash
dx ui-capture capture \
  --stage after \
  --script "$storyboard" \
  --url "http://127.0.0.1:3000"
```

For `after_only`, run only the after command. Add `--mobile` when responsive behavior matters. Add `--no-narration` when captions are the better fit or local voice generation is unavailable.

The after pass renders `walkthrough.mp4`. Local Kokoro narration is attempted by default; if model loading or synthesis fails, the captioned video remains valid proof. No cloud speech service or API key is required.

## 6. Review, revise, and verify

Play the MP4 from beginning to end. Check the poster, transcript, captions, screenshots, trace, and four browser logs. Fix real console, page, request, or HTTP errors before handoff.

The editable sources are:

- `walkthrough.json` for coverage, actions, chapter titles, and narration
- `transcript.md` for the human-readable product, technical, test, and narration copy
- `captions.vtt` for accessibility and manual caption edits

Treat `walkthrough.json` as the source of truth. Edit it and rerender:

```bash
dx ui-capture revise \
  --script "$storyboard" \
  --before-url "http://127.0.0.1:3000" \
  --after-url "http://127.0.0.1:3001"
```

Omit a URL when that stage's actions and on-screen copy did not change. For `after_only`, only `--after-url` can be needed. Repeat until the first viewing is clear without extra explanation.

Before reporting `READY`, confirm:

- the final duration is no more than the storyboard's `max_seconds`
- the file is preferably under 10 MiB
- captions are readable and synchronized closely enough to follow
- before/after routes and data match, or the after-only reason is accurate
- the changed behavior and final state are visible
- browser logs were reviewed
- no generated artifact is staged or committed

## 7. Surface and hand off

Run:

```bash
dx ui-capture show
dx ui-capture show --open
```

Report absolute links to `walkthrough.mp4`, `poster.png`, `transcript.md`, `walkthrough.json`, and `visual-evidence.md`. During an active Dex run, the compact bundle is also registered as run artifacts and uploaded to DexCode when that connection is enabled. GitHub cannot render local paths, so tell the human to drag the MP4 and poster into the PR body or a comment.

Artifacts live under `~/.claude/.dex-artifacts/ui/<session>/`, or `DX_ARTIFACT_DIR`, and must never be committed. Dex marks them completed with the lifecycle and removes completed bundles after 30 days by default. Inspect or retire them explicitly with:

```bash
dx ui-capture show --json
dx ui-capture clean --older-than 30
```
