# shellcheck shell=bash
# Dex helpers for RTK (Rust Token Killer) token-reduction tooling.

DX_RTK_REPO="rtk-ai/rtk"
DX_RTK_MARKER_START="<!-- dex-rtk-instructions v1 -->"
DX_RTK_MARKER_END="<!-- /dex-rtk-instructions -->"

dx_rtk_enabled() {
  [[ "${DX_RTK_ENABLED:-1}" != "0" ]]
}

dx_rtk_install_dir() {
  printf '%s\n' "${DX_RTK_INSTALL_DIR:-$(dx_tools_dir)/rtk/bin}"
}

dx_rtk_managed_binary() {
  printf '%s\n' "$(dx_rtk_install_dir)/rtk"
}

dx_rtk_codex_dir() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
}

dx_rtk_binary_is_token_killer() {
  local binary="$1" rewritten
  [[ -n "$binary" ]] || return 1
  rewritten=$("$binary" rewrite "git status" 2>/dev/null || true)
  [[ "$rewritten" == "rtk git status" ]]
}

dx_rtk_resolved_binary() {
  local candidate managed

  if [[ -n "${DX_RTK_BIN:-}" ]]; then
    if dx_rtk_binary_is_token_killer "$DX_RTK_BIN"; then
      printf '%s\n' "$DX_RTK_BIN"
      return 0
    fi
    return 1
  fi

  candidate=$(command -v rtk 2>/dev/null || true)
  if [[ -n "$candidate" ]] && dx_rtk_binary_is_token_killer "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  managed=$(dx_rtk_managed_binary)
  if [[ -x "$managed" ]] && dx_rtk_binary_is_token_killer "$managed"; then
    printf '%s\n' "$managed"
    return 0
  fi

  return 1
}

dx_rtk_command_for_agents() {
  local candidate
  candidate=$(command -v rtk 2>/dev/null || true)
  if [[ -n "$candidate" ]] && dx_rtk_binary_is_token_killer "$candidate"; then
    printf '%s\n' "rtk"
    return 0
  fi

  if candidate=$(dx_rtk_resolved_binary 2>/dev/null); then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "rtk"
}

dx_rtk_target_triple() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)

  case "$os:$arch" in
    Linux:x86_64|Linux:amd64) printf '%s\n' "x86_64-unknown-linux-musl" ;;
    Linux:arm64|Linux:aarch64) printf '%s\n' "aarch64-unknown-linux-gnu" ;;
    Darwin:x86_64|Darwin:amd64) printf '%s\n' "x86_64-apple-darwin" ;;
    Darwin:arm64|Darwin:aarch64) printf '%s\n' "aarch64-apple-darwin" ;;
    *) return 1 ;;
  esac
}

dx_rtk_latest_release() {
  local version

  version=$(command curl -q -sI "https://github.com/${DX_RTK_REPO}/releases/latest" \
    | grep -i '^location:' \
    | sed -E 's|.*/tag/([^[:space:]]+).*|\1|' \
    | tr -d '\r' \
    | tail -n 1)

  if [[ -z "$version" ]]; then
    version=$(command curl -q -fsSL "https://api.github.com/repos/${DX_RTK_REPO}/releases/latest" \
      | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -n 1)
  fi

  [[ -n "$version" ]] || return 1
  [[ ${#version} -le 100 && "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s\n' "$version"
}

dx_rtk_verify_archive_checksum() {
  local archive="$1" checksums_file="$2" archive_name="$3"
  [[ -f "$archive" && -f "$checksums_file" && -n "$archive_name" ]] || return 1

  DX_RTK_ARCHIVE="$archive" \
  DX_RTK_CHECKSUMS_FILE="$checksums_file" \
  DX_RTK_ARCHIVE_NAME="$archive_name" \
  python3 - <<'PY'
import hashlib
import os
import re
from pathlib import Path

archive = Path(os.environ["DX_RTK_ARCHIVE"])
checksums = Path(os.environ["DX_RTK_CHECKSUMS_FILE"])
archive_name = os.environ["DX_RTK_ARCHIVE_NAME"]
matches = []
try:
    for line in checksums.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == archive_name:
            matches.append(parts[0].lower())
except (OSError, UnicodeDecodeError):
    raise SystemExit(1)

if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{64}", matches[0]):
    raise SystemExit(1)

digest = hashlib.sha256()
try:
    with archive.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if digest.hexdigest() == matches[0] else 1)
PY
}

dx_rtk_archive_safe() {
  local archive="$1"
  [[ -f "$archive" ]] || return 1

  DX_RTK_ARCHIVE="$archive" python3 - <<'PY'
import os
import tarfile
from pathlib import Path, PurePosixPath

archive = Path(os.environ["DX_RTK_ARCHIVE"])
member_count = 0
uncompressed_bytes = 0
try:
    with tarfile.open(archive, mode="r:gz") as bundle:
        for member in bundle:
            member_count += 1
            if member_count > 1000:
                raise SystemExit(1)
            path = PurePosixPath(member.name)
            if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
                raise SystemExit(1)
            if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                raise SystemExit(1)
            if member.isfile():
                uncompressed_bytes += member.size
                if member.size > 128 * 1024 * 1024 or uncompressed_bytes > 256 * 1024 * 1024:
                    raise SystemExit(1)
except (OSError, tarfile.TarError, UnicodeError):
    raise SystemExit(1)
PY
}

dx_install_rtk_user_path_link() {
  local managed local_bin target current path_entry

  managed=$(dx_rtk_managed_binary)
  [[ -x "$managed" ]] || return 0

  if command -v rtk >/dev/null 2>&1; then
    return 0
  fi

  local_bin="$HOME/.local/bin"
  target="$local_bin/rtk"
  mkdir -p "$local_bin"

  if [[ -L "$target" ]]; then
    current=$(readlink "$target")
    if [[ "$current" == "$managed" ]]; then
      dx_ok "RTK linked at ${target}"
    else
      dx_warn "${target} points to ${current}; leaving it unchanged"
      return 1
    fi
  elif [[ -e "$target" ]]; then
    dx_warn "${target} exists and is not a symlink; leaving it unchanged"
    return 1
  elif ln -s "$managed" "$target"; then
    dx_done "Linked RTK into ${target}"
  else
    dx_warn "Could not link RTK into ${target}"
    return 1
  fi

  path_entry=":${PATH:-}:"
  if [[ "$path_entry" != *":$local_bin:"* ]]; then
    dx_warn "${local_bin} is not on PATH; Claude hooks use RTK by absolute path, but shell sessions may not find 'rtk'"
  fi
}

dx_install_rtk_binary() {
  local existing existing_path managed target version install_dir temp_dir archive archive_name
  local checksums_file checksums_url url binary

  if ! dx_rtk_enabled; then
    dx_skip "RTK token-reduction tooling disabled (DX_RTK_ENABLED=0)"
    return 0
  fi

  managed=$(dx_rtk_managed_binary)
  if existing_path=$(dx_rtk_resolved_binary 2>/dev/null); then
    dx_ok "RTK available at ${existing_path}"
    if [[ -n "${DX_RTK_BIN:-}" ]] || [[ "$existing_path" == "$managed" ]]; then
      dx_install_rtk_user_path_link || return 1
      return 0
    fi
    if [[ -x "$managed" ]] && dx_rtk_binary_is_token_killer "$managed"; then
      dx_install_rtk_user_path_link || return 1
      return 0
    fi
    dx_info "Installing Dex-managed RTK fallback for hooks"
  fi

  existing=$(command -v rtk 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    dx_warn "Found '${existing}', but 'rtk rewrite' did not verify Rust Token Killer; installing a Dex-managed RTK binary"
  fi

  command -v curl >/dev/null 2>&1 || {
    dx_warn "curl is required to install RTK"
    return 1
  }
  command -v tar >/dev/null 2>&1 || {
    dx_warn "tar is required to install RTK"
    return 1
  }

  if ! target=$(dx_rtk_target_triple); then
    dx_warn "RTK binary install is not supported on $(uname -s) $(uname -m)"
    return 1
  fi

  version="${DX_RTK_VERSION:-}"
  if [[ -z "$version" ]]; then
    if ! version=$(dx_rtk_latest_release); then
      dx_warn "Could not resolve latest RTK release"
      return 1
    fi
  fi
  if [[ ${#version} -gt 100 || ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    dx_warn "DX_RTK_VERSION must be a release tag using letters, numbers, '.', '_', or '-'"
    return 1
  fi

  install_dir=$(dx_rtk_install_dir)
  temp_dir=$(mktemp -d)
  archive_name="rtk-${target}.tar.gz"
  archive="$temp_dir/$archive_name"
  checksums_file="$temp_dir/checksums.txt"
  url="https://github.com/${DX_RTK_REPO}/releases/download/${version}/${archive_name}"
  checksums_url="https://github.com/${DX_RTK_REPO}/releases/download/${version}/checksums.txt"

  dx_info "Installing RTK ${version} into ${install_dir}"
  if ! command curl -q -fsSL "$url" -o "$archive"; then
    rm -rf "$temp_dir"
    dx_warn "Could not download RTK from ${url}"
    return 1
  fi
  if ! command curl -q -fsSL "$checksums_url" -o "$checksums_file"; then
    rm -rf "$temp_dir"
    dx_warn "Could not download RTK checksums for ${version}"
    return 1
  fi
  if ! dx_rtk_verify_archive_checksum "$archive" "$checksums_file" "$archive_name"; then
    rm -rf "$temp_dir"
    dx_warn "RTK archive checksum verification failed"
    return 1
  fi

  if ! dx_rtk_archive_safe "$archive"; then
    rm -rf "$temp_dir"
    dx_warn "RTK archive contains unsafe entries; refusing to extract"
    return 1
  fi

  if ! tar -xzf "$archive" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    dx_warn "Could not extract RTK archive"
    return 1
  fi

  binary="$temp_dir/rtk"
  if [[ ! -f "$binary" || -L "$binary" ]]; then
    binary=$(find "$temp_dir" -type f -name rtk -print -quit 2>/dev/null || true)
  fi
  if [[ -z "$binary" || ! -f "$binary" || -L "$binary" ]]; then
    rm -rf "$temp_dir"
    dx_warn "RTK archive did not contain an rtk binary"
    return 1
  fi

  mkdir -p "$install_dir"
  if ! install -m 0755 "$binary" "$install_dir/rtk"; then
    rm -rf "$temp_dir"
    dx_warn "Could not install RTK binary into ${install_dir}"
    return 1
  fi
  rm -rf "$temp_dir"

  if ! dx_rtk_binary_is_token_killer "$install_dir/rtk"; then
    dx_warn "Installed RTK binary failed verification via 'rtk rewrite'"
    return 1
  fi

  dx_done "Installed RTK ${version}"
  dx_install_rtk_user_path_link || return 1
}

dx_rtk_codex_markdown_block() {
  local rtk_cmd="$1"
  cat <<EOF
${DX_RTK_MARKER_START}
# RTK - Rust Token Killer

Use RTK for shell commands when compact output is enough. Prefer:

\`\`\`bash
${rtk_cmd} git status
${rtk_cmd} git diff
${rtk_cmd} rg pattern src/
${rtk_cmd} npm test
${rtk_cmd} pytest -q
\`\`\`

Use raw commands when exact output matters, or run \`${rtk_cmd} proxy <cmd>\` to bypass filtering while still tracking the command.

Useful checks:

\`\`\`bash
${rtk_cmd} --version
${rtk_cmd} rewrite "git status"
\`\`\`

If the rewrite check fails, the \`rtk\` command on PATH may be the unrelated Rust Type Kit package. Use the command path shown above or reinstall RTK from https://github.com/rtk-ai/rtk.
${DX_RTK_MARKER_END}
EOF
}

dx_rtk_markers_valid() {
  local path="$1"

  [[ -f "$path" ]] || return 1
  awk -v start="$DX_RTK_MARKER_START" -v finish="$DX_RTK_MARKER_END" '
    $0 == start {
      starts++
      if (starts > 1 || open) invalid = 1
      open = 1
      next
    }
    $0 == finish {
      finishes++
      if (!open || finishes > 1) invalid = 1
      open = 0
    }
    END {
      if (starts != 1 || finishes != 1 || open || invalid) exit 1
    }
  ' "$path"
}

dx_write_rtk_codex_markdown() {
  local path="$1" rtk_cmd="$2" tmp block_tmp

  tmp="${path}.tmp.$$"
  block_tmp="${path}.block.$$"
  dx_rtk_codex_markdown_block "$rtk_cmd" > "$block_tmp"

  if [[ -f "$path" ]]; then
    if ! dx_rtk_markers_valid "$path"; then
      rm -f "$tmp" "$block_tmp" 2>/dev/null || true
      return 1
    fi

    if ! _DX_RTK_BLOCK="$block_tmp" awk -v start="$DX_RTK_MARKER_START" -v finish="$DX_RTK_MARKER_END" '
      function emit_block(  line) {
        while ((getline line < ENVIRON["_DX_RTK_BLOCK"]) > 0) print line
        close(ENVIRON["_DX_RTK_BLOCK"])
      }
      $0 == start {
        if (!inserted) { emit_block(); inserted = 1 }
        skipping = 1
        next
      }
      skipping && $0 == finish { skipping = 0; next }
      !skipping { print }
    ' "$path" > "$tmp"; then
      rm -f "$tmp" "$block_tmp" 2>/dev/null || true
      return 1
    fi
  else
    if ! mv "$block_tmp" "$tmp"; then
      rm -f "$tmp" "$block_tmp" 2>/dev/null || true
      return 1
    fi
    block_tmp=""
  fi

  if mv "$tmp" "$path"; then
    [[ -z "$block_tmp" ]] || rm -f "$block_tmp" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp" "$block_tmp" 2>/dev/null || true
  return 1
}

dx_uninstall_rtk_codex_instructions() {
  local codex_dir rtk_md agents_md rtk_ref tmp managed_link managed_binary failed=0

  codex_dir=$(dx_rtk_codex_dir)
  rtk_md="$codex_dir/RTK.md"
  agents_md="$codex_dir/AGENTS.md"
  rtk_ref="@${rtk_md}"

  if [[ -f "$rtk_md" ]] && grep -Fq -e "$DX_RTK_MARKER_START" -e "$DX_RTK_MARKER_END" "$rtk_md" 2>/dev/null; then
    if ! dx_rtk_markers_valid "$rtk_md"; then
      dx_warn "Could not remove Dex RTK instructions from ${rtk_md}: managed markers are malformed"
      failed=1
    else
      tmp="${rtk_md}.tmp.$$"
      if awk -v start="$DX_RTK_MARKER_START" -v finish="$DX_RTK_MARKER_END" '
      $0 == start { skipping = 1; next }
      skipping && $0 == finish { skipping = 0; next }
      !skipping { print }
      ' "$rtk_md" > "$tmp"; then
        if grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then
          if mv "$tmp" "$rtk_md"; then
            dx_done "Removed Dex RTK instructions from ${rtk_md}"
          else
            rm -f "$tmp" 2>/dev/null || true
            dx_warn "Could not update ${rtk_md}"
            failed=1
          fi
        elif rm -f "$tmp" && rm -f "$rtk_md"; then
          dx_done "Removed Dex RTK instructions from ${rtk_md}"
        else
          rm -f "$tmp" 2>/dev/null || true
          dx_warn "Could not remove ${rtk_md}"
          failed=1
        fi
      else
        rm -f "$tmp" 2>/dev/null || true
        dx_warn "Could not remove Dex RTK instructions from ${rtk_md}"
        failed=1
      fi
    fi
  fi

  if [[ -f "$agents_md" ]] && grep -Fxq "$rtk_ref" "$agents_md" 2>/dev/null; then
    tmp="${agents_md}.tmp.$$"
    if awk -v managed_import="$rtk_ref" '$0 != managed_import { print }' "$agents_md" > "$tmp"; then
      if grep -q '[^[:space:]]' "$tmp" 2>/dev/null; then
        if mv "$tmp" "$agents_md"; then
          dx_done "Removed the Dex RTK import from ${agents_md}"
        else
          rm -f "$tmp" 2>/dev/null || true
          dx_warn "Could not update ${agents_md}"
          failed=1
        fi
      elif rm -f "$tmp" && rm -f "$agents_md"; then
        dx_done "Removed the Dex RTK import from ${agents_md}"
      else
        rm -f "$tmp" 2>/dev/null || true
        dx_warn "Could not remove ${agents_md}"
        failed=1
      fi
    else
      rm -f "$tmp" 2>/dev/null || true
      dx_warn "Could not remove the Dex RTK import from ${agents_md}"
      failed=1
    fi
  fi

  managed_binary=$(dx_rtk_managed_binary)
  managed_link="$HOME/.local/bin/rtk"
  if [[ -L "$managed_link" ]] && [[ "$(readlink "$managed_link")" == "$managed_binary" ]]; then
    if rm -f "$managed_link"; then
      dx_done "Removed the Dex-managed RTK path link"
    else
      dx_warn "Could not remove ${managed_link}"
      failed=1
    fi
  fi

  return "$failed"
}

dx_install_rtk_codex_instructions() {
  local codex_dir rtk_md agents_md rtk_ref rtk_cmd tmp existing

  if ! dx_rtk_enabled; then
    return 0
  fi

  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex RTK instructions"
    return 0
  fi

  codex_dir=$(dx_rtk_codex_dir)
  mkdir -p "$codex_dir"
  rtk_md="$codex_dir/RTK.md"
  agents_md="$codex_dir/AGENTS.md"
  rtk_ref="@${rtk_md}"
  rtk_cmd=$(dx_rtk_command_for_agents)

  if [[ -f "$rtk_md" ]]; then
    existing=$(<"$rtk_md")
    if [[ "$existing" == *"$DX_RTK_MARKER_START"* ]]; then
      dx_write_rtk_codex_markdown "$rtk_md" "$rtk_cmd" || {
        dx_warn "Could not update ${rtk_md}"
        return 1
      }
      dx_ok "Codex RTK instructions already managed"
    else
      dx_warn "${rtk_md} exists and is not Dex-managed; leaving it unchanged"
    fi
  else
    dx_write_rtk_codex_markdown "$rtk_md" "$rtk_cmd" || {
      dx_warn "Could not write ${rtk_md}"
      return 1
    }
    dx_done "Installed Codex RTK instructions"
  fi

  if [[ -f "$agents_md" ]] && grep -Fxq "$rtk_ref" "$agents_md" 2>/dev/null; then
    dx_ok "Codex AGENTS.md already imports RTK.md"
    return 0
  fi

  tmp="${agents_md}.tmp.$$"
  if [[ -f "$agents_md" ]]; then
    { sed '${/^$/d;}' "$agents_md"; printf '\n\n%s\n' "$rtk_ref"; } > "$tmp"
  else
    printf '%s\n' "$rtk_ref" > "$tmp"
  fi

  if mv "$tmp" "$agents_md"; then
    dx_done "Added RTK import to Codex AGENTS.md"
    return 0
  fi

  rm -f "$tmp" 2>/dev/null || true
  dx_warn "Could not update ${agents_md}"
  return 1
}

dx_check_rtk_binary() {
  local binary

  if ! dx_rtk_enabled; then
    dx_skip "RTK token-reduction tooling disabled (DX_RTK_ENABLED=0)"
    return 0
  fi

  if binary=$(dx_rtk_resolved_binary 2>/dev/null); then
    dx_ok "RTK available at ${binary}"
    return 0
  fi

  dx_warn "RTK is not installed or 'rtk rewrite' did not verify Rust Token Killer"
  return 1
}

dx_check_rtk_claude_hook() {
  local settings_file="$HOME/.claude/settings.json"

  if ! dx_rtk_enabled; then
    return 0
  fi

  if [[ -f "$settings_file" ]] && grep -Fq "rtk-claude-hook.sh" "$settings_file" 2>/dev/null; then
    dx_ok "Claude RTK hook configured"
    return 0
  fi

  dx_warn "Claude RTK hook is not configured"
  return 1
}

dx_check_rtk_codex_instructions() {
  local codex_dir rtk_md agents_md rtk_ref

  if ! dx_rtk_enabled; then
    return 0
  fi

  if ! command -v codex >/dev/null 2>&1; then
    dx_skip "Codex CLI not found; skipping Codex RTK instruction check"
    return 0
  fi

  codex_dir=$(dx_rtk_codex_dir)
  rtk_md="$codex_dir/RTK.md"
  agents_md="$codex_dir/AGENTS.md"
  rtk_ref="@${rtk_md}"

  if [[ -f "$rtk_md" ]] && [[ -f "$agents_md" ]] && grep -Fxq "$rtk_ref" "$agents_md" 2>/dev/null; then
    dx_ok "Codex RTK instructions configured"
    return 0
  fi

  dx_warn "Codex RTK instructions are not configured"
  return 1
}

dx_install_rtk_tooling() {
  local failed=0

  dx_install_rtk_binary || failed=1
  dx_install_rtk_codex_instructions || failed=1

  return "$failed"
}

dx_check_rtk_tooling() {
  local failed=0

  dx_check_rtk_binary || failed=1
  dx_check_rtk_claude_hook || failed=1
  dx_check_rtk_codex_instructions || failed=1

  return "$failed"
}
