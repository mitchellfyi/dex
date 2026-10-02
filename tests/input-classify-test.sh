#!/usr/bin/env bash
set -euo pipefail

# `dx <anything>`: the input is classified before anything starts. A ticket
# key or number is a ticket. A GitHub issue URL on this repository's origin,
# or a Linear issue URL, is that ticket. A Linear or GitHub project URL, any
# other URL, or an existing document is a source the workflow resolves in
# Phase 0. Everything else is a free-form prompt, as before. The workspace
# slug for a source comes from the part that identifies it, not the scheme
# and host.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-input-classify-test.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export DEX_DIR="$ROOT"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/docs"
git init -q -b main "$REPO"
git -C "$REPO" remote add origin "git@github.com:acme/widgets.git"
printf '# Spec\n' > "$REPO/docs/payments spec.md"
printf '# Notes\n' > "$REPO/notes.md"

kind() { dx_input_kind "$1" "$REPO"; }
ticket() { dx_input_ticket "$1" "$REPO"; }

# ── tickets ────────────────────────────────────────────────────────────────
[[ "$(kind "84")" == "ticket" ]] || assert_at $LINENO
[[ "$(kind " ENG-123 ")" == "ticket" ]] || assert_at $LINENO
[[ "$(ticket " ENG-123 ")" == "ENG-123" ]] || assert_at $LINENO

# ── tracker issue URLs become the ticket ───────────────────────────────────
[[ "$(kind "https://github.com/acme/widgets/issues/84")" == "github-issue" ]] || assert_at $LINENO
[[ "$(ticket "https://github.com/acme/widgets/issues/84")" == "84" ]] || assert_at $LINENO
[[ "$(kind "HTTPS://GitHub.com/acme/widgets/issues/84#issuecomment-1")" == "github-issue" ]] || assert_at $LINENO
[[ "$(kind "https://github.com/acme/widgets/pull/85")" == "github-pr" ]] || assert_at $LINENO
[[ "$(ticket "https://github.com/acme/widgets/pull/85")" == "85" ]] || assert_at $LINENO
# Another repository's issue is not this repository's ticket.
[[ "$(kind "https://github.com/other/repo/issues/84")" == "url" ]] || assert_at $LINENO
[[ "$(kind "https://linear.app/acme/issue/ENG-123/payments-revamp")" == "linear-issue" ]] || assert_at $LINENO
[[ "$(ticket "https://linear.app/acme/issue/ENG-123/payments-revamp")" == "ENG-123" ]] || assert_at $LINENO
[[ "$(kind "https://linear.app/acme/issue/ENG-123")" == "linear-issue" ]] || assert_at $LINENO

# ── projects and other sources ─────────────────────────────────────────────
[[ "$(kind "https://linear.app/acme/project/payments-revamp-7f3a2b1c0d9e/overview")" == "linear-project" ]] || assert_at $LINENO
[[ "$(kind "https://github.com/orgs/acme/projects/12")" == "github-project" ]] || assert_at $LINENO
[[ "$(kind "https://github.com/orgs/acme/projects/12/views/3?filterQuery=x")" == "github-project" ]] || assert_at $LINENO
[[ "$(kind "https://github.com/users/jo/projects/2")" == "github-project" ]] || assert_at $LINENO
[[ "$(kind "https://github.com/acme/widgets/projects/4")" == "github-project" ]] || assert_at $LINENO
[[ "$(kind "https://docs.example.com/specs/payments?v=2")" == "url" ]] || assert_at $LINENO
[[ "$(kind "http://example.com/")" == "url" ]] || assert_at $LINENO
# A URL followed by instructions is still a source; the words travel with it.
[[ "$(kind "https://linear.app/acme/project/payments-7f3a and keep the old API working")" == "linear-project" ]] || assert_at $LINENO
# Documents: an existing file, including one with spaces in its name.
[[ "$(kind "$REPO/notes.md")" == "document" ]] || assert_at $LINENO
[[ "$(kind "$REPO/docs/payments spec.md")" == "document" ]] || assert_at $LINENO
[[ "$(cd "$REPO" && dx_input_kind "docs/payments spec.md" "$REPO")" == "document" ]] || assert_at $LINENO
[[ "$(cd "$REPO" && dx_input_kind "./notes.md" "$REPO")" == "document" ]] || assert_at $LINENO
# A file with spaces in its name, followed by instructions.
[[ "$(cd "$REPO" && dx_input_kind "docs/payments spec.md only the refunds part" "$REPO")" == "document" ]] || assert_at $LINENO
[[ "$(cd "$REPO" && dx_input_slug "docs/payments spec.md only the refunds part" document)" == "payments-spec" ]] || assert_at $LINENO
# A path that does not exist, a directory, or ordinary words are a prompt.
[[ "$(kind "$REPO/missing.md")" == "prompt" ]] || assert_at $LINENO
[[ "$(kind "$REPO/docs")" == "prompt" ]] || assert_at $LINENO
[[ "$(kind "fix the login bug")" == "prompt" ]] || assert_at $LINENO
[[ "$(kind "see https://example.com/spec for details")" == "prompt" ]] || assert_at $LINENO
[[ "$(kind "")" == "prompt" ]] || assert_at $LINENO
# Only http(s) counts as a source URL.
[[ "$(kind "ftp://example.com/spec")" == "prompt" ]] || assert_at $LINENO
[[ "$(kind "mailto:someone@example.com")" == "prompt" ]] || assert_at $LINENO

# ── slugs name the thing, not the scheme and host ──────────────────────────
[[ "$(dx_input_slug "https://linear.app/acme/project/payments-revamp-7f3a2b1c0d9e/overview" linear-project)" == "project-payments-revamp-7f3a2b1c0d9e" ]] || assert_at $LINENO
[[ "$(dx_input_slug "https://github.com/orgs/acme/projects/12/views/3?filterQuery=x" github-project)" == "acme-projects-12" ]] || assert_at $LINENO
[[ "$(dx_input_slug "https://docs.example.com/specs/payments?v=2" url)" == "docs-example-com-specs-payments" ]] || assert_at $LINENO
[[ "$(dx_input_slug "http://example.com/" url)" == "example-com" ]] || assert_at $LINENO
[[ "$(dx_input_slug "$REPO/docs/payments spec.md" document)" == "payments-spec" ]] || assert_at $LINENO
[[ "$(dx_input_slug "fix the login bug" prompt)" == "fix-the-login-bug" ]] || assert_at $LINENO
SLUG="$(dx_input_slug "https://docs.example.com/a-very-long-path/that-goes-on-and-on/for-quite-a-while/and-more/and-more-still" url)"
[[ "${#SLUG}" -le 48 ]] || assert_at $LINENO
[[ "$SLUG" != *-- && "$SLUG" != -* && "$SLUG" != *- ]] || assert_at $LINENO

# ── the origin remote is read in both common forms ─────────────────────────
git -C "$REPO" remote set-url origin "https://github.com/acme/widgets"
[[ "$(kind "https://github.com/acme/widgets/issues/9")" == "github-issue" ]] || assert_at $LINENO
git -C "$REPO" remote set-url origin "https://github.com/acme/widgets.git"
[[ "$(kind "https://github.com/acme/widgets/issues/9")" == "github-issue" ]] || assert_at $LINENO
git -C "$REPO" remote remove origin
[[ "$(kind "https://github.com/acme/widgets/issues/9")" == "url" ]] || assert_at $LINENO

printf 'input classify tests passed\n'
