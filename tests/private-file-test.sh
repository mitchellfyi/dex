#!/usr/bin/env bash
set -euo pipefail

# scripts/private_file.py is what stands between the review ledger and a file
# somebody else wrote. Its rejections are the whole point, so they are what this
# tests: each one, individually, on a file that differs from a good one in
# exactly that way.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-private-file-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"

# read <path> [maximum] [strict] — prints the content, or fails.
read_private() {
  DX_PRIVATE_FILE_DIR="$ROOT/scripts" python3 - "$1" "${2:-4096}" "${3:-lax}" <<'PY'
import os
import sys

sys.path.insert(0, os.environ["DX_PRIVATE_FILE_DIR"])
from private_file import PrivateFileError, read_private_file  # noqa: E402

try:
    content = read_private_file(
        sys.argv[1], int(sys.argv[2]), require_text_lines=sys.argv[3] == "strict"
    )
except PrivateFileError:
    raise SystemExit(1)
sys.stdout.buffer.write(content)
PY
}

accepts() {
  local label="$1" path="$2"
  shift 2
  if ! read_private "$path" "$@" > "$TMP_DIR/out"; then
    printf 'private_file rejected a file it should accept: %s\n' "$label" >&2
    exit 1
  fi
}

rejects() {
  local label="$1" path="$2"
  shift 2
  if read_private "$path" "$@" > /dev/null 2>&1; then
    printf 'private_file accepted a file it should reject: %s\n' "$label" >&2
    exit 1
  fi
}

good="$TMP_DIR/good"
printf 'ledger line\n' > "$good"
chmod 600 "$good"
accepts "an ordinary 0600 record" "$good"
assert_eq "ledger line" "$(cat "$TMP_DIR/out")" "content read back"

# Mode: anything a second party can write is not a private record.
for mode in 644 640 604 700 666; do
  variant="$TMP_DIR/mode-$mode"
  printf 'ledger line\n' > "$variant"
  chmod "$mode" "$variant"
  rejects "mode $mode" "$variant"
done

# A symlink is not the file it points at, however good that file is.
ln -s "$good" "$TMP_DIR/symlink"
rejects "a symlink to a valid record" "$TMP_DIR/symlink"

# Not a regular file.
mkdir "$TMP_DIR/adir"
chmod 700 "$TMP_DIR/adir"
rejects "a directory" "$TMP_DIR/adir"
rejects "a path that does not exist" "$TMP_DIR/absent"

# Size bounds, at both ends.
: > "$TMP_DIR/empty"
chmod 600 "$TMP_DIR/empty"
rejects "an empty file" "$TMP_DIR/empty"

printf '%s\n' "$(python3 -c 'print("z" * 200)')" > "$TMP_DIR/oversize"
chmod 600 "$TMP_DIR/oversize"
rejects "a file past the maximum" "$TMP_DIR/oversize" 64
accepts "the same file within a larger maximum" "$TMP_DIR/oversize" 4096

# Exactly at the bound is inside it; one byte over is not.
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"a" * 64)' "$TMP_DIR/exact"
chmod 600 "$TMP_DIR/exact"
accepts "a file exactly at the maximum" "$TMP_DIR/exact" 64
rejects "a file one byte over the maximum" "$TMP_DIR/exact" 63

# The strict content rules, which only the record reader asks for.
printf 'no trailing newline' > "$TMP_DIR/unterminated"
chmod 600 "$TMP_DIR/unterminated"
accepts "an unterminated file when not strict" "$TMP_DIR/unterminated"
rejects "an unterminated file when strict" "$TMP_DIR/unterminated" 4096 strict

printf 'has\r\na carriage return\n' > "$TMP_DIR/carriage"
chmod 600 "$TMP_DIR/carriage"
accepts "a carriage return when not strict" "$TMP_DIR/carriage"
rejects "a carriage return when strict" "$TMP_DIR/carriage" 4096 strict

# Bytes are returned unchanged — a hash over them has to be a hash of the file.
printf 'tab\there\nunicode ✓\n' > "$TMP_DIR/bytes"
chmod 600 "$TMP_DIR/bytes"
accepts "a record with tabs and unicode" "$TMP_DIR/bytes"
if ! cmp -s "$TMP_DIR/bytes" "$TMP_DIR/out"; then
  printf 'private_file altered the bytes it returned\n' >&2
  exit 1
fi

printf 'private file tests passed\n'
