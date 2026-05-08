# shellcheck shell=bash
# Doyaken shared library — formatted output helpers

dk_done()  { printf '[done]  %s\n' "$*"; }
dk_ok()    { printf '[ok]    %s\n' "$*"; }
dk_warn()  { printf '[warn]  %s\n' "$*" >&2; }
dk_skip()  { printf '[skip]  %s\n' "$*"; }
dk_info()  { printf '[info]  %s\n' "$*"; }
dk_error() { printf '[error] %s\n' "$*" >&2; }

# dk_format_duration <seconds> — format a numeric duration as "Xm Ys".
dk_format_duration() {
  local seconds="$1" minutes remainder
  if [[ ! "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$seconds"
    return 0
  fi

  minutes=$((seconds / 60))
  remainder=$((seconds % 60))
  printf '%dm %ds\n' "$minutes" "$remainder"
}

# dk_progress_filter — parse Claude Code CLI stream-json output and display
# human-readable progress lines showing which tools are being invoked.
#
# Claude's stream-json format emits one JSON object per line. Each "assistant"
# message contains content blocks: tool_use (with name/input), text, thinking.
# This filter watches for new tool_use blocks and prints a formatted line:
#   [....]  Reading src/foo.ts
#   [done]  Writing .doyaken/rules/backend.md
#   [....]  Thinking...
#
# Uses \r\033[K (carriage return + clear line) to overwrite ephemeral lines.
# The --include-partial-messages flag on Claude CLI is required for real-time
# progress — without it, tool blocks only appear after the full response.
#
# Usage: claude -p --verbose --output-format stream-json --include-partial-messages "..." | dk_progress_filter
dk_progress_filter() {
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
first = True
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
            first = False
            if name in ('Write', 'Edit') and '.doyaken/' in (inp.get('file_path') or ''):
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
            first = False
            print('\r\033[K[....]  Thinking...', end='', flush=True)
            showing_thinking = True
" "$repo_root"
}
