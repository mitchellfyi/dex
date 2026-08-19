# shellcheck shell=bash
# Dex shared library — formatted output helpers

dx_done()  { printf '[done]  %s\n' "$*"; }
dx_ok()    { printf '[ok]    %s\n' "$*"; }
dx_warn()  { printf '[warn]  %s\n' "$*" >&2; }
dx_skip()  { printf '[skip]  %s\n' "$*"; }
dx_info()  { printf '[info]  %s\n' "$*"; }
dx_error() { printf '[error] %s\n' "$*" >&2; }

# dx_format_duration <seconds> — the one duration formatter. Prints "Ys" below
# a minute, "Xm Ys" below an hour, and "Xh Ym" above one, dropping the unit
# that has stopped carrying information. Anything that is not a whole number of
# seconds is passed through unchanged, so a caller can hand over a value it
# never resolved rather than have it reported as zero.
dx_format_duration() {
  local seconds="$1"
  if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$seconds"
    return 0
  fi
  # Force base 10: a value like `090` from a config file is a valid duration,
  # but shell arithmetic and printf both read a leading zero as octal.
  seconds=$((10#$seconds))

  if [[ "$seconds" -lt 60 ]]; then
    printf '%ds\n' "$seconds"
  elif [[ "$seconds" -lt 3600 ]]; then
    printf '%dm %ds\n' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%dh %dm\n' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  fi
}

# dx_progress_filter — parse Claude Code CLI stream-json output and display
# human-readable progress lines showing which tools are being invoked.
#
# Claude's stream-json format emits one JSON object per line. Each "assistant"
# message contains content blocks: tool_use (with name/input), text, thinking.
# This filter watches for new tool_use blocks and prints a formatted line:
#   [....]  Reading src/foo.ts
#   [done]  Writing .dex/rules/backend.md
#   [....]  Thinking...
#
# Uses \r\033[K (carriage return + clear line) to overwrite ephemeral lines.
# The --include-partial-messages flag on Claude CLI is required for real-time
# progress — without it, tool blocks only appear after the full response.
#
# Usage: claude -p --verbose --output-format stream-json --include-partial-messages "..." | dx_progress_filter
dx_progress_filter() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  # Inline Python parses Claude's stream-json output format. Each line is a JSON object.
  # We track tool_use blocks by their unique ID (seen_tool_ids) to avoid duplicate output.
  # Tool blocks arrive incrementally via --include-partial-messages: the first appearance
  # may lack 'input', so we skip until input is populated. Between tools, text content
  # without new tools triggers a 'Thinking...' indicator. Terminal escapes (\r\033[K)
  # overwrite ephemeral lines for a clean progress display.
  # See: Claude Code CLI --output-format stream-json documentation.
  python3 -c "
import json, sys

repo_root = sys.argv[1] if len(sys.argv) > 1 else ''
showing_thinking = False
seen_tool_ids = set()

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get('type') != 'assistant':
        continue

    content = msg.get('message', {}).get('content', [])
    found_new_tool = False

    for block in content:
        block_type = block.get('type', '')

        if block_type == 'tool_use':
            tool_id = block.get('id', '')
            if tool_id in seen_tool_ids:
                continue
            # Need input to display — partial messages may arrive before
            # input is populated, so skip until we have something to show.
            inp = block.get('input', {})
            detail = inp.get('file_path') or inp.get('pattern') or inp.get('command', '')
            if not detail:
                continue
            seen_tool_ids.add(tool_id)
            found_new_tool = True
            showing_thinking = False

            if repo_root and detail.startswith(repo_root + '/'):
                detail = detail[len(repo_root) + 1:]
            if len(detail) > 72:
                detail = detail[:69] + '...'

            name = block.get('name', '')
            # \\r\\033[K clears any ephemeral 'Thinking...' line
            prefix = '\r\033[K'
            if name in ('Write', 'Edit') and '.dex/' in (inp.get('file_path') or ''):
                print(f'{prefix}[done]  Writing {detail}')
            elif name == 'Read':
                print(f'{prefix}[....]  Reading {detail}')
            elif name == 'Glob':
                print(f'{prefix}[....]  Scanning {detail}')
            elif name == 'Grep':
                print(f'{prefix}[....]  Searching for {detail}')
            elif name == 'Bash':
                print(f'{prefix}[....]  Running {detail}')
            elif name == 'Edit':
                print(f'{prefix}[....]  Editing {detail}')
            elif name == 'Write':
                print(f'{prefix}[....]  Writing {detail}')
            else:
                print(f'{prefix}[....]  {name} {detail}')
            sys.stdout.flush()

    # Text content with no new tool = Claude is thinking
    if not found_new_tool and not showing_thinking:
        has_text = any(
            b.get('type') == 'text' and b.get('text', '').strip()
            for b in content
        )
        if has_text:
            print('\r\033[K[....]  Thinking...', end='', flush=True)
            showing_thinking = True

# The thinking indicator is written without a newline so the next line can
# overwrite it. If the stream ends while it is showing, clear it so it does not
# stay on screen as the final output.
if showing_thinking:
    print('\r\033[K', end='', flush=True)
" "$repo_root"
}
