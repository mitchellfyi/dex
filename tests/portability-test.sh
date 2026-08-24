#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-portability-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$TMP_DIR/bin"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

fixture="$TMP_DIR/fixture"
printf 'fixture\n' > "$fixture"
chmod 640 "$fixture"
expected_mtime="$(python3 - "$fixture" <<'PY'
import os
import sys

print(int(os.lstat(sys.argv[1]).st_mtime))
PY
)"

# GNU stat accepts -f as a filesystem-report option and exits successfully.
# A BSD-first fallback therefore returns prose on Linux instead of metadata.
cat > "$TMP_DIR/bin/stat" <<'SH'
#!/usr/bin/env bash
printf 'GNU filesystem report\n'
SH
chmod +x "$TMP_DIR/bin/stat"
export PATH="$TMP_DIR/bin:$PATH"

assert_eq "640" "$(dx_path_mode "$fixture")" "portable file mode"
assert_eq "$expected_mtime" "$(dx_path_mtime "$fixture")" "portable file mtime"
assert_eq "$expected_mtime" "$(__dx_lifecycle_path_mtime "$fixture")" \
  "lifecycle lock mtime uses the portable helper"
assert_rejected "$LINENO" dx_path_mode "$TMP_DIR/missing"
assert_rejected "$LINENO" dx_path_mtime "$TMP_DIR/missing"

printf 'portability tests passed\n'
