# UI proof workflow

Create visual proof for the browser-facing changes in the current checkout. The
proof must reflect the full diff from its comparison base, including committed,
staged, unstaged, and untracked work.

## Invocation mode

The calling skill selects one mode:

- **Manual proof mode** (`/dxproof` or `/dxcapture`): the user asked for the
  artifact. Capture it unless there is no browser-visible change or the flow
  cannot be reproduced safely. Do not replace the request with a discretionary
  `SKIPPED` decision. If capture is blocked, keep the state `NEEDS_REVIEW` and
  report the concrete blocker.
- **Lifecycle decision mode** (`/dxuicapture` or a Dex lifecycle): decide
  whether a walkthrough would help. `READY`, a reasoned `SKIPPED`, and a
  reasoned `N/A` are valid outcomes.

User-provided routes, flows, viewports, base refs, startup commands, and test
accounts take precedence over inferred values.

## Read the capture contract

Read `docs/ui-capture.md` before acting. It is the source of truth for the
storyboard schema, structured actions, capture commands, output bundle,
production limits, revision workflow, retention, and troubleshooting.

Keep all generated evidence under Dex's artifact directory. Never stage or
commit it. Use local or explicitly authorized test data, keep credentials out of
storyboards and media, and do not point the recorder at production unless the
user explicitly requested and authorized that environment.

## Establish the comparison

Work from the repository root and preserve the current checkout exactly as it
is. Inspect its branch, worktree status, and complete change set:

```bash
repo_root=$(git rev-parse --show-toplevel) || exit 1
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
default_branch=$(dx_default_branch "$repo_root")
base_ref=$(dx_default_branch_base_ref "$repo_root" "$default_branch") || exit 1
baseline_commit=$(git -C "$repo_root" merge-base HEAD "$base_ref") || exit 1

git -C "$repo_root" status --short
git -C "$repo_root" diff --name-status "$baseline_commit"
git -C "$repo_root" ls-files --others --exclude-standard
```

When the user names a base ref, or the current branch has a PR targeting a
different base, resolve that ref instead of the default branch. The baseline is
the merge base with that ref, not the current tip of the base branch. This keeps
the proof aligned with the branch or Dex worktree's actual change set.

Read the changed UI code and nearby routes, tests, fixtures, screenshots, and
project instructions. Identify every material user-visible change, then map
each one to a reproducible route, starting state, viewport, interaction, and
observable result. Include working-tree-only and untracked UI work.

Use the smallest set of focused storyboards that covers the material UI/UX
diff. One storyboard may contain several related chapters. Split unrelated
flows rather than exceeding the 90-second limit or making the comparison hard
to follow.

## Reconstruct the before state

If a matching, reviewed baseline capture already exists for the same baseline
commit, route, data, viewport, and storyboard actions, it may be reused.
During a lifecycle invocation made before UI edits, the unchanged current
checkout may be captured directly as the baseline. Otherwise, reproduce the
baseline from Git even when implementation is already complete:

```bash
proof_temp_root=$(mktemp -d "${TMPDIR:-/tmp}/dex-ui-proof.XXXXXX") || exit 1
baseline_checkout="$proof_temp_root/baseline"
git -C "$repo_root" worktree add --detach "$baseline_checkout" "$baseline_commit"
```

Install dependencies and start the baseline app from `baseline_checkout` using
the project's documented development setup. Do not edit, stash, reset, or
switch the user's current checkout to obtain the old state. Use an isolated
local database or deterministic fixture data when the two revisions are not
schema-compatible.

Run the before and after applications sequentially on the same port when that
is simplest, or on separate ports when both need to remain live. Either way,
use equivalent data, authentication, route, viewport, and actions. Record every
process you start so it can be stopped at handoff.

Use `after_only` only when no meaningful baseline exists or the old revision
cannot be reproduced safely. In manual proof mode, explain this limitation to
the user; never silently substitute it for the requested before/after proof.

## Storyboard and capture

Build the storyboard from the diff and observed product behavior, not from file
names alone. The normal comparison is `before_after`. Give the before and after
chapters matching actions wherever parity is possible, and make the captions
describe the visible difference without narrating code trivia.

Prepare the tools and the session storyboard:

```bash
dx ui-capture install
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
session_id="${DEX_SESSION_ID:-$(dx_session_id)}"
storyboard=$(dx_ui_capture_storyboard_file "$session_id")
mkdir -p "$(dirname "$storyboard")"
dx ui-capture validate --script "$storyboard"
```

For unrelated flows that need separate videos, give each proof a distinct,
valid `--session` value and use that session's storyboard path. Do not overwrite
one completed bundle with another.

Start the baseline app, wait until it is healthy, and capture its complete
representative flow:

```bash
dx ui-capture capture \
  --stage before \
  --script "$storyboard" \
  --url "$before_url"
```

Stop the baseline server. Start the current checkout without altering its Git
state, wait until it is healthy, then replay the matched flow:

```bash
dx ui-capture capture \
  --stage after \
  --script "$storyboard" \
  --url "$after_url"
```

Pass `--mobile` to both stages when responsive behavior is in scope. The final
bundle must include recorded before and after footage, visible stage/chapter
labels, `walkthrough.mp4`, `poster.png`, `captions.vtt`, `transcript.md`, the
editable storyboard, screenshots, traces, and reviewed browser logs. Narration
is optional; captions are not. The combined MP4 should make the comparison
clear on its first viewing.

For a non-browser UI or a project-native recorder, produce equivalent before
and after footage with captions, review it to the same standard, then register
the finished MP4, poster, and manifest with `dx ui-capture ready` as described
in `docs/ui-capture.md`.

## Review and revise

Run `dx ui-capture show`, play the entire MP4, and inspect both raw stage
captures. Confirm that:

- every material visible change found in the diff is covered or explicitly
  listed as out of scope with a reason
- before and after use equivalent routes, data, actions, and viewports
- the visible result, stage labels, and captions are readable and synchronized
- the media contains no secrets, personal data, notifications, or unrelated UI
- console, page, request, and HTTP logs contain no unexplained errors
- the final video is at most 90 seconds and preferably under 10 MiB
- `git status --short` contains no generated proof artifact

Edit `walkthrough.json` and use `dx ui-capture revise` until the bundle meets
that bar. Do not mark custom footage `READY` before watching it.

## Clean up and report

Stop all servers and processes started for capture. Remove only the temporary
baseline worktree created by this run:

```bash
if [[ -n "${proof_temp_root:-}" && -n "${baseline_checkout:-}" \
  && "$baseline_checkout" == "$proof_temp_root/baseline" ]]; then
  git -C "$repo_root" worktree remove --force "$baseline_checkout"
  rmdir "$proof_temp_root" 2>/dev/null || true
fi
```

Do not remove a pre-existing worktree or any user-owned checkout. If cleanup
fails, report the exact retained path.

Finish with the proof state, comparison base and commit, covered flows and
viewports, and clickable absolute paths to `walkthrough.mp4`, `poster.png`,
`captions.vtt`, `transcript.md`, `walkthrough.json`, and
`visual-evidence.md`. Mention any `after_only` limitation or uncovered change.
