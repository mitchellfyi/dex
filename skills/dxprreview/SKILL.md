---
name: "dxprreview"
description: "Critically evaluate PR review comments, fix valid issues, push back when appropriate, and prepare reviewer replies."
---

# Skill: dxprreview

Critically evaluate PR review comments — fix what should be fixed, push back on what should not, and escalate what needs human judgement. In autonomous Phase 6/watch mode, use inline replies without asking; standalone invocations may ask how the user wants replies delivered.

## When to Use

- Invoked by `/dxwatchpr` when new review comments are detected
- Invoked directly to address all outstanding PR comments in one pass
- After receiving review feedback on a PR

## Arguments

Optional: a PR number (e.g., `/dxprreview 456`). If omitted, operates on the current branch's open PR.

Optional reply-mode override (skips the user prompt in Step 5.5):
- `--reply=inline` — post a reply to each comment on the PR (default behaviour)
- `--reply=terminal` — print proposed replies in the terminal report only; do not touch the PR

The same overrides can be set via `DEX_PRREVIEW_REPLY_MODE=inline|terminal` in the environment.

## Steps

### 0. Codebase Context (mandatory)

Before evaluating any reviewer comment, gather the project context that lets you tell a substantive concern from a personal preference. Skipping this step means you risk fixing things that contradict the project's own conventions.

Read in this order — stop when you have enough:

1. `AGENTS.md` and `CLAUDE.md` compatibility pointers (root and any nested) — language boundaries, naming, error-handling, architecture rules
2. `.dex/rules/*.md` referenced from those files
3. `.dex/memory/index.md` and only active scoped memory entries relevant to the PR files or review phase; treat memory as context to verify, not proof
4. `.dex/dex.md § Reviewers` — the configured reviewers; mention-type bots' substantive feedback IS actionable (we deliberately invited them)
5. `prompts/review.md` — the 12-pass criteria; use it to classify the comment's underlying concern (Pass A correctness, Pass C security, etc.)
6. The plan file or ticket — establishes scope and out-of-scope. Comments asking for out-of-scope changes are Tier 3 (escalate).
7. Similar code in the repo: when a comment says "do X instead", `Grep` for whether the codebase already does X or Y. If Y is the established pattern in 3+ places, "do X" is likely a personal preference and goes to Tier 2 evaluation, not Tier 1.

Every "fix" or "do not fix" decision in Step 3 must reference one of these artefacts in the reply (e.g., "Keeping current approach: matches the pattern in `auth/middleware.ts:42` and `auth/session.ts:91`").

### 1. Gather Context

```bash
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Use provided PR number, or detect from current branch
if [[ -n "$1" ]]; then
  PR_NUM="$1"
else
  PR_NUM=$(gh pr view --json number -q .number)
fi
```

If a PR number was provided, inspect the PR provenance before checkout. Do not
check out fork PR heads in a privileged session unless the repo explicitly
configured that trust boundary. Prefer the immutable head SHA over a mutable
branch ref:

```bash
git diff --quiet && git diff --cached --quiet || {
  echo "Working tree has local changes; stop before checking out PR #$PR_NUM."
  exit 1
}
if [[ -n "$(git status --porcelain=v1 -uall)" ]]; then
  echo "Working tree has untracked or local changes; stop before checking out PR #$PR_NUM."
  exit 1
fi
IS_CROSS_REPO=$(gh pr view "$PR_NUM" --json isCrossRepository -q .isCrossRepository)
PR_BRANCH=$(gh pr view "$PR_NUM" --json headRefName -q .headRefName)
PR_HEAD_SHA=$(gh pr view "$PR_NUM" --json headRefOid -q .headRefOid)
if [[ "$IS_CROSS_REPO" == "true" && "${DX_ALLOW_FORK_PR_CHECKOUT:-0}" != "1" ]]; then
  echo "PR #$PR_NUM is from another repository; stop before privileged checkout."
  exit 1
fi
git fetch origin "$PR_BRANCH"
FETCHED_SHA=$(git rev-parse FETCH_HEAD)
if [[ "$FETCHED_SHA" != "$PR_HEAD_SHA" ]]; then
  echo "PR #$PR_NUM moved during checkout; stop and re-run after rechecking provenance."
  exit 1
fi
git checkout -B "$PR_BRANCH" "$PR_HEAD_SHA"
```

Fetch all review data:

```bash
# Reviews (approve/request-changes/comment verdicts)
gh api repos/$REPO/pulls/$PR_NUM/reviews

# Inline comments (the actual feedback)
gh api repos/$REPO/pulls/$PR_NUM/comments

# General PR-level comments (issue-style, not inline)
gh api repos/$REPO/issues/$PR_NUM/comments
```

Identify **unaddressed comments**: comments with no reply from the PR author. Filter out:
- Your own prior replies (from earlier `/dxprreview` or `/dxwatchpr` runs)
- Approval comments with no actionable content
- Bot comments that are purely informational (CI status, coverage reports, deploy previews)

**Important — `mention`-type reviewers from `.dex/dex.md § Reviewers`**: any reviewer whose Type is `mention` was deliberately invited (we posted an `@<handle>` comment requesting their review). Their substantive feedback IS actionable, even though they're a bot — do NOT classify them as "purely informational". Treat their `mention`-handle responses the same as a human reviewer's. The "purely informational" filter still applies to other bots not listed in the Reviewers section (CI bots, deploy preview bots, etc.).

If there are no unaddressed comments, report that and exit immediately.

### 2. Understand the Full Change

Before evaluating any comment, build context on the PR's scope and intent:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
DEFAULT_BRANCH=$(dx_default_branch)

# If reviewing a different PR, use its branch; otherwise use HEAD
if [[ -n "$PR_BRANCH" ]]; then
  DIFF_REF="origin/$PR_BRANCH"
else
  DIFF_REF="HEAD"
fi

git diff origin/$DEFAULT_BRANCH...$DIFF_REF --stat
git log origin/$DEFAULT_BRANCH..$DIFF_REF --oneline
```

Read the PR description (`gh pr view $PR_NUM --json body -q .body`). This establishes what the change is trying to accomplish — essential for judging whether reviewer suggestions are in-scope.

### 3. Critically Evaluate Each Comment

For each unaddressed comment, classify it and decide on the action.

#### 3.1 Classification

| Type | Indicators |
|------|-----------|
| **Bug report** | Points to a specific failure mode, incorrect output, or broken edge case |
| **Security concern** | Identifies a vulnerability, missing validation, or data exposure |
| **Request-change** | Explicitly asks for a modification with a clear rationale |
| **Question** | Asks why something was done a certain way, or what a piece of code does |
| **Suggestion** | Proposes an alternative approach, naming change, or refactor |
| **Nitpick** | Minor style, formatting, or preference comment |
| **Approval** | Positive feedback, LGTM, acknowledgement |

#### 3.2 Decision Framework

**Tier 1 — Always fix (no evaluation needed):**
- Bug reports with evidence (specific input that fails, incorrect output, missing edge case)
- Security vulnerabilities (missing auth, injection, data exposure)
- Missing error handling the reviewer identified in new code
- Broken types or tests the reviewer found
- Factual errors in documentation or comments

**Tier 2 — Evaluate then decide:**

For each Tier 2 comment, assess four criteria:

1. **Correctness impact** — Does this fix an actual bug or prevent a real failure? If yes, lean toward fixing.
2. **Codebase consistency** — Does the suggestion align with existing patterns in this repo? Read nearby files, scoped memory, and the project's conventions (AGENTS.md, `.dex/rules/`). If the suggestion contradicts established patterns, lean toward not fixing.
3. **Scope alignment** — Is the change within this PR's scope? If it requires touching files outside the PR or changing the architectural approach, lean toward not fixing (or escalating).
4. **Effort-to-value ratio** — Trivial fix (< 5 min) with clear value: fix. Significant refactor with debatable benefit: do not fix.

Tier 2 applies to: style/naming preferences that conflict with codebase patterns, alternative implementations, performance concerns without evidence of actual impact, "use library X instead of Y" suggestions, refactoring suggestions that expand scope.

The decision is binary: **fix** or **do not fix**. Do not partially fix. If you would fix it differently than the reviewer suggests, fix it your way and explain the deviation in the reply.

**Tier 3 — Always escalate (never decide autonomously):**
- Architectural changes (affects the approach, multiple files outside PR scope, changes data model)
- Disagreements about requirements or acceptance criteria
- Unclear comments that could mean different things
- Requests that conflict with the approved plan or ticket scope

### 4. Implement Fixes

For all comments decided as "fix":

1. **Read the referenced code** — read the full file, not just the diff hunk. Understand the surrounding context.
2. **Implement the fix** — follow existing patterns. Keep the fix minimal and focused on what the reviewer raised.
3. **Run targeted verification** — run the project's quality checks (format, lint, typecheck, test) scoped to the affected files. Fix any issues introduced by the fix.
4. **Do not commit yet** — accumulate fixes, commit in Step 5.

If a fix introduces a new issue (breaks a test, causes a type error), resolve it before moving to the next comment. If the fix turns out to be complex enough to qualify as an architectural change, reclassify the comment to Tier 3 and escalate instead.

### 5. Commit and Push

After all fixes are implemented and verified:

If this is running under `dx maintain respond` and the invocation provides
`response.md` / `inline-replies.jsonl` artifact paths, do not push and do not
post GitHub replies directly. Commit local fixes when useful so the DX maintain
wrapper can detect the new HEAD, then write the publishable response artifacts:

- `response.md`: PR-level sections using `## Fixed`, `## Answered`,
  `## Not Fixed`, `## Escalated`, `## Verification`, and
  `## Reviewer Replies`.
- `inline-replies.jsonl`: one JSON object per inline review-comment reply with
  `comment_id` and `body`.

Then skip the direct push/reply commands in the rest of this skill; the wrapper
pushes, posts bounded replies, and re-requests reviewers after the provider
exits.

Otherwise, for normal Phase 6/manual `/dxprreview` runs:

1. **Group fixes logically** — if all fixes are small and related, use a single commit. If fixes address different concerns (e.g., one is a bug fix, another is a naming change), use separate commits.
2. **Commit format:** `fix(review): <description>`
   - Single fix: `fix(review): handle nil check in user lookup`
   - Multiple related fixes: `fix(review): address review feedback — nil check, error message, naming`
   - Include `Co-Authored-By: Dex <noreply@dexcode.ai>` and do not include Claude attribution.
3. **Push once:**
   ```bash
   git push
   ```

### 5.5. Resolve Reply Mode

Before posting anything to GitHub, resolve how replies should be delivered. Do not ask in autonomous watch mode.

**Resolution order:**

1. **`--reply=` argument** — if the invocation included `--reply=inline` or `--reply=terminal`, use that and skip the question.
2. **`DEX_PRREVIEW_REPLY_MODE` env var** — if set to `inline` or `terminal`, use that and skip the question.
3. **Autonomous Phase 6/watch mode** — if invoked by `/dxwatchpr`, `/dxcomplete`, or another unattended loop, default to `inline` and skip the question.
4. **Otherwise, ask via `AskUserQuestion`:**

   Question: "How should I deliver replies to these review comments?"
   - **Inline on the PR (per comment)** — post a reply to each comment via `gh api repos/.../comments/<id>/replies` and `gh api repos/.../issues/<n>/comments`. Each reviewer sees a thread under their own comment. (Recommended)
   - **Terminal only (summary)** — print the proposed replies in the terminal report (Step 8). Do not touch the PR. The user can copy-paste any replies they want to post manually.

If the answer is **terminal**, skip Step 6 entirely and expand Step 8's report to include each comment with the proposed reply text in a quote-block beneath it.

If the answer is **inline**, proceed to Step 6 as written.

### 6. Reply to Comments

(Skip this step if the user chose `terminal` mode in Step 5.5.)

Also skip this step when running under `dx maintain respond`; write
`response.md` and `inline-replies.jsonl` instead so the wrapper can publish
safely after rechecking PR provenance.

After pushing (so commit SHAs are available), reply to every unaddressed comment. Use the appropriate API endpoint based on comment type:

**Inline comments (from pull request review):**
```bash
gh api repos/$REPO/pulls/$PR_NUM/comments/<comment-id>/replies \
  -f body="<reply>"
```

**PR-level comments (issue-style):**
```bash
gh api repos/$REPO/issues/$PR_NUM/comments \
  -f body="<reply>"
```

**Reply format by decision:**

| Decision | Format |
|----------|--------|
| **Fixed** | `Fixed in <short-sha>. <1-2 sentence explanation of the change.>` |
| **Not fixing** | `Keeping current approach: <concise reason referencing specific code or pattern>. Open to discussion if you see something I'm missing.` |
| **Question answered** | `<Direct answer referencing specific code context.>` |
| **Nitpick fixed** | `Fixed in <short-sha>.` |
| **Escalated** | No reply — handled in Step 7. |

**Reply rules:**
- Keep replies factual and concise. No filler ("Great catch!", "Thanks for the review!").
- Always reference specific code, files, or patterns when explaining a decision not to fix.
- Never dismiss a comment without reasoning. Even nitpicks get a reply.
- Before posting or printing reply text, invoke the `humanizer` skill. Preserve short SHAs, file paths, API names, and the required reply format while removing filler and servile tone.

### 7. Handle Escalations

If any comments were classified as Tier 3 (escalate):

**When invoked standalone (user ran `/dxprreview`):**
- Present each escalation to the user with:
  - The reviewer's comment (quoted)
  - The referenced code
  - Why this needs human judgement
  - 2-3 options for how to respond (if applicable)
- Wait for user direction before replying.

**When invoked from `/dxwatchpr` loop:**
- Return the escalation list. `/dxwatchpr` handles cancelling loops and reporting to the user.

### 8. Report

Print a summary. The summary table is the same regardless of reply mode; in `terminal` mode, append a "Proposed replies" section with the full reply text per comment so the user can post them manually.

Invoke the `humanizer` skill on any prose in the terminal report. Preserve tables, counts, comment numbers, reviewer handles, paths, and reply blocks exactly.

```
## PR Review Comments Addressed

Reply mode: <inline | terminal>

| # | Reviewer | Type | Decision | Detail |
|---|----------|------|----------|--------|
| 1 | @reviewer | Bug report | Fixed | <short-sha> — nil check in user lookup |
| 2 | @reviewer | Suggestion | Not fixing | Existing pattern uses X, not Y |
| 3 | @reviewer | Question | Answered | Explained caching strategy |
| 4 | @reviewer | Architectural | Escalated | Requires user decision |

**Fixed:** N comments (M commits pushed)
**Not fixing:** N comments (all replied with reasoning)
**Answered:** N questions
**Escalated:** N comments (awaiting user direction)
```

**Additional `terminal`-mode section** (only when reply mode = terminal):

```
## Proposed Replies (not posted to PR)

### Comment #1 — @reviewer (Bug report)
> "<original comment text, quoted>"
on `path/to/file.ts:42`

**Reply:**
> Fixed in <short-sha>. <1-2 sentence explanation.>

---

### Comment #2 — @reviewer (Suggestion)
> "<original comment text>"
on `path/to/file.ts:91`

**Reply:**
> Keeping current approach: matches the pattern in `auth/middleware.ts:42` and `auth/session.ts:91`. Open to discussion if you see something I'm missing.

---

(... etc)
```

This block lets the user copy any individual reply into the GitHub UI, or skip them entirely.

## Notes

- This skill critically evaluates comments. It does NOT blindly fix everything. Reviewers can be wrong, suggest personal preferences, or request changes that would make the code worse. The agent's job is to use judgement, not compliance.
- When not fixing a comment, the reasoning must be substantive — reference specific code, patterns, or constraints. "I disagree" is not sufficient.
- Do not resolve review threads — only GitHub's web UI or the reviewer should resolve threads.
- Do not dismiss reviews — reply and let the reviewer re-review.
- When invoked from `/dxwatchpr`, the comment fetching in Step 1 may duplicate what the caller already fetched. The skill re-fetches anyway for freshness and standalone compatibility.
