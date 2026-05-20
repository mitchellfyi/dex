# Humanizer

Humanizer is a Dex skill for tightening AI-sounding writing without changing
the underlying meaning. It is meant for PR descriptions, issue and tracker
comments, docs, user-facing copy, review replies, and code comments.

The skill removes common AI tells: inflated wording, vague authority,
signposting, filler, promotional tone, forced lists of three, excessive hedging,
and redundant code comments. It keeps technical details intact: commands, file
paths, identifiers, markdown tables, checkboxes, code blocks, ticket IDs, and
required attribution footers.

## Usage

Invoke it directly when you want to rewrite a draft:

```text
/humanizer

Humanize this PR description:
<paste draft>
```

Or ask for a specific surface:

```text
Use humanizer on this code comment. Keep it technical and short:
<paste comment>
```

Dex also references this skill from its lifecycle prompts so agents apply it
before publishing PR bodies, ticket updates, review replies, maintenance
reports, and other public copy.

## Source

This skill is a compact Dex adaptation of
[`blader/humanizer`](https://github.com/blader/humanizer), which is distributed
under the MIT license and based on Wikipedia's "Signs of AI writing" guide.
