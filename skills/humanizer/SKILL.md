---
name: humanizer
description: "Humanize AI-sounding prose while preserving meaning and technical accuracy. Use whenever writing or editing copy, docs, release notes, PR descriptions, ticket bodies, GitHub/issue/review comments, user-facing messages, or code comments. Apply before posting or publishing text and before finalizing comments in code."
---

# Skill: Humanizer

Edit prose so it sounds like a competent person wrote it. This skill is a final writing pass, not a license to add color, facts, sources, or opinions the draft did not support.

This skill is adapted from `blader/humanizer` (MIT), which is based on Wikipedia's "Signs of AI writing" guide maintained by WikiProject AI Cleanup.

## Workflow

1. Identify the surface: PR body, ticket text, reviewer reply, user-facing copy, documentation, or code comment.
2. Preserve the factual and technical payload exactly. Keep commands, paths, identifiers, checkboxes, tables, code blocks, and required template headings intact.
3. Rewrite only the prose around that payload.
4. Run a final audit: "What still makes this sound AI-generated?" Fix those tells before publishing.
5. Output the final text only unless the user asked to see the draft or audit.

## Surface Rules

**PR descriptions, ticket bodies, docs, and release notes**
- Be specific about what changed and why it matters.
- Prefer concrete nouns and active verbs.
- Keep structure useful for scanning, but do not pad sections to fill a template.
- Do not invent business impact, metrics, citations, or reviewer context.

**GitHub, tracker, and review comments**
- Be direct and calm. No praise filler.
- Lead with the answer or action taken.
- For disagreement, cite the code, pattern, or constraint that supports the decision.
- Keep replies short enough that the reviewer can act on them.

**Code comments and doc comments**
- Keep comments technical, plain, and short.
- Explain why the code exists, what invariant it protects, or what edge case it handles.
- Do not add personality, jokes, hype, or redundant "what the next line does" narration.
- Preserve required public API documentation and parameter/return detail.

**UI and product copy**
- Use the user's language where available.
- Prefer verbs over abstract nouns.
- Remove tutorial-script wording unless the interface genuinely teaches a workflow.
- Keep labels concise; do not make buttons or compact UI text conversational.

## AI Tells To Remove

- Chatbot artifacts: "Great question", "Of course", "I hope this helps", "let me know".
- Signposting: "Let's dive in", "Here's what you need to know", "without further ado".
- Inflated importance: "pivotal", "crucial", "groundbreaking", "transformative", "vital role", "evolving landscape".
- Promotional tone: "boasts", "seamless", "powerful", "rich", "vibrant", "breathtaking".
- Vague authority: "experts say", "observers note", "industry reports suggest" without a cited source.
- Superficial `-ing` clauses: "highlighting", "showcasing", "underscoring", "reflecting" when they add no fact.
- Copula avoidance: replace "serves as", "stands as", "features", or "boasts" with "is" or "has" when simpler.
- Negative parallelism: "not just X, but Y" when a direct sentence works.
- Forced threes, synonym cycling, false ranges, and generic upbeat conclusions.
- Excessive hedging: "could potentially possibly", "it may be argued", "based on available information".
- Filler: "in order to", "due to the fact that", "at this point in time", "it is important to note".
- Styling tells: unnecessary bold labels, title-case headings, emojis, curly quotes in ASCII files, and overused em dashes.
- Over-hyphenating common word pairs. Keep required technical compounds and ambiguity-preventing hyphens.

## Final Checks

- Would a senior engineer actually write this sentence?
- Does every sentence carry a fact, decision, instruction, or useful transition?
- Did the rewrite remove required nuance or precision? If so, restore it.
- Are code comments explaining why, not narrating what?
- Are all links, commands, paths, IDs, checkboxes, and markdown tables still valid?
