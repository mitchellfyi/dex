#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-public-command-args.XXXXXX")"

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
export TEST_REPO="$TMP_DIR/repo"
mkdir -p "$HOME" "$TEST_REPO"
git -C "$TEST_REPO" init -q

zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"

  __dx_refresh_provider() {
    print -u2 -- "provider resolution ran during argument validation"
    return 97
  }

  for command_name in dxloop dxrefine dxcomplete dxreviewloop dxrm dxls dxcd dxclean; do
    "$command_name" --help > "$TEST_REPO/$command_name-help.out"
    grep -Fq "Usage:" "$TEST_REPO/$command_name-help.out"
  done

  invalid_cases=(
    "dxcomplete unexpected"
    "dxreviewloop unexpected"
    "dxls unexpected"
    "dxcd first second"
    "dxclean unexpected"
  )
  for invalid_case in "${invalid_cases[@]}"; do
    words=("${(z)invalid_case}")
    if "${words[@]}" > /dev/null 2> "$TEST_REPO/invalid.out"; then
      print -u2 -- "public command accepted invalid arguments: $invalid_case"
      exit 1
    fi
    if grep -Fq "provider resolution ran" "$TEST_REPO/invalid.out"; then
      print -u2 -- "provider resolution ran before rejecting: $invalid_case"
      exit 1
    fi
  done
'

printf 'public command argument tests passed\n'
