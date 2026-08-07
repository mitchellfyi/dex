#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-rtk-install-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_RTK_INSTALL_DIR="$TMP_DIR/managed/bin"
export DX_RTK_VERSION="v-test.1"
export LC_ALL=C
mkdir -p "$HOME/.local/bin" "$TMP_DIR/bin" "$TMP_DIR/fixtures"

real_python="$(command -v python3)"
ln -s "$real_python" "$TMP_DIR/bin/python3"
export PATH="$TMP_DIR/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

target="$(dx_rtk_target_triple)"
archive_name="rtk-${target}.tar.gz"
fixture_root="$TMP_DIR/fixtures/archive"
mkdir -p "$fixture_root"
cat > "$fixture_root/rtk" <<'RTK'
#!/usr/bin/env bash
if [[ "${1:-}" == "rewrite" && "${2:-}" == "git status" ]]; then
  printf 'rtk git status\n'
  exit 0
fi
exit 1
RTK
chmod +x "$fixture_root/rtk"
tar -czf "$TMP_DIR/fixtures/$archive_name" -C "$fixture_root" rtk

python3 - "$TMP_DIR/fixtures/$archive_name" "$TMP_DIR/fixtures/checksums.txt" <<'PY'
import hashlib
import sys
from pathlib import Path

archive = Path(sys.argv[1])
checksum_file = Path(sys.argv[2])
checksum_file.write_text(
    f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n",
    encoding="utf-8",
)
PY

cat > "$TMP_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DX_TEST_CURL_LOG"
[[ "${1:-}" == "-q" ]] || exit 90
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 91
case "$url" in
  */checksums.txt) cp "$DX_TEST_FIXTURES/checksums.txt" "$output" ;;
  *.tar.gz) cp "$DX_TEST_FIXTURES/${url##*/}" "$output" ;;
  *) exit 92 ;;
esac
CURL
chmod +x "$TMP_DIR/bin/curl"

export DX_TEST_CURL_LOG="$TMP_DIR/curl.log"
export DX_TEST_FIXTURES="$TMP_DIR/fixtures"
printf 'location-trusted\n' > "$HOME/.curlrc"

dx_install_rtk_binary > "$TMP_DIR/install.out"
[[ -x "$DX_RTK_INSTALL_DIR/rtk" ]] || {
  printf 'verified RTK fixture was not installed\n' >&2
  exit 1
}
[[ "$("$DX_RTK_INSTALL_DIR/rtk" rewrite "git status")" == "rtk git status" ]] || {
  printf 'installed RTK fixture failed its behavior check\n' >&2
  exit 1
}
[[ "$(wc -l < "$DX_TEST_CURL_LOG" | tr -d '[:space:]')" == "2" ]] || {
  printf 'RTK install did not fetch exactly one archive and checksum file\n' >&2
  exit 1
}
if grep -Ev '^-q ' "$DX_TEST_CURL_LOG" | grep -q .; then
  printf 'RTK download did not disable curl configuration first\n' >&2
  exit 1
fi

cp "$TMP_DIR/fixtures/checksums.txt" "$TMP_DIR/fixtures/checksums.valid"
printf '%064d  %s\n' 0 "$archive_name" > "$TMP_DIR/fixtures/checksums.txt"
if dx_rtk_verify_archive_checksum \
  "$TMP_DIR/fixtures/$archive_name" "$TMP_DIR/fixtures/checksums.txt" "$archive_name"; then
  printf 'mismatched RTK checksum unexpectedly passed\n' >&2
  exit 1
fi

cp "$TMP_DIR/fixtures/checksums.valid" "$TMP_DIR/fixtures/checksums.txt"
cat "$TMP_DIR/fixtures/checksums.valid" >> "$TMP_DIR/fixtures/checksums.txt"
if dx_rtk_verify_archive_checksum \
  "$TMP_DIR/fixtures/$archive_name" "$TMP_DIR/fixtures/checksums.txt" "$archive_name"; then
  printf 'duplicate RTK checksum unexpectedly passed\n' >&2
  exit 1
fi

rm -f "$DX_RTK_INSTALL_DIR/rtk" "$HOME/.local/bin/rtk"
if DX_RTK_VERSION='../unsafe' dx_install_rtk_binary > "$TMP_DIR/version.out" 2>&1; then
  printf 'unsafe RTK version unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'DX_RTK_VERSION must be a release tag' "$TMP_DIR/version.out"

printf 'rtk install tests passed\n'
