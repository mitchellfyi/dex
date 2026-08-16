# shellcheck shell=bash
# Dex helpers for Codex CLI integration, plus the per-skill symlink
# management shared with the Claude install path in lib/agent-tools.sh.

dx_codex_skills_dir() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills"
}

dx_count_dex_skills() {
  local count=0
  local skill_dir
  for skill_dir in "$DEX_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# __dx_install_skill_links <skills_dir> <label>
# Link every Dex skill into <skills_dir>, refusing to disturb anything that
# is not a Dex-owned symlink. <label> names the consumer in messages.
__dx_install_skill_links() {
  local skills_dir="$1" label="$2"
  if ! mkdir -p "$skills_dir"; then
    dx_warn "Could not create ${skills_dir}; skipping ${label} skill links"
    return 1
  fi

  local installed=0
  local expected=0
  local failed=0
  local skipped=0
  local skill_dir skill_name target current
  for skill_dir in "$DEX_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    expected=$((expected + 1))
    skill_name=$(basename "$skill_dir")
    target="$skills_dir/$skill_name"

    if [[ -L "$target" ]]; then
      current=$(readlink "$target")
      if [[ "$current" == "$skill_dir" ]]; then
        installed=$((installed + 1))
      else
        dx_warn "${skills_dir}/${skill_name} is a symlink to ${current} — leaving it unchanged"
        skipped=$((skipped + 1))
      fi
    elif [[ -e "$target" ]]; then
      dx_warn "${skills_dir}/${skill_name} exists and is not a symlink — leaving it unchanged"
      skipped=$((skipped + 1))
    else
      if ln -s "$skill_dir" "$target"; then
        installed=$((installed + 1))
      else
        failed=$((failed + 1))
      fi
    fi
  done

  if [[ $failed -gt 0 || $skipped -gt 0 || $installed -ne $expected ]]; then
    dx_warn "Installed ${installed}/${expected} ${label} skill link(s); skipped ${skipped}; failed ${failed}"
    return 1
  fi

  dx_done "Installed ${installed}/${expected} Dex skill link(s) for ${label}"
}

# __dx_count_dex_skill_links <skills_dir>
# Count how many Dex skills are correctly linked into <skills_dir>.
__dx_count_dex_skill_links() {
  local skills_dir="$1"
  [[ -d "$skills_dir" ]] || {
    printf '%s\n' "0"
    return 0
  }

  local count=0
  local skill_dir skill_name target current
  for skill_dir in "$DEX_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    skill_name=$(basename "$skill_dir")
    target="$skills_dir/$skill_name"
    if [[ -L "$target" ]]; then
      current=$(readlink "$target")
      [[ "$current" == "$skill_dir" ]] && count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

dx_install_codex_skills() {
  __dx_install_skill_links "$(dx_codex_skills_dir)" "Codex CLI"
}

dx_count_codex_dex_skills() {
  __dx_count_dex_skill_links "$(dx_codex_skills_dir)"
}

dx_codex_dex_skills_complete() {
  local expected installed
  expected=$(dx_count_dex_skills)
  installed=$(dx_count_codex_dex_skills)
  [[ "$expected" -gt 0 && "$installed" -eq "$expected" ]]
}

dx_uninstall_codex_skills() {
  local codex_dir
  codex_dir=$(dx_codex_skills_dir)
  [[ -d "$codex_dir" ]] || {
    dx_skip "${codex_dir} does not exist"
    return 0
  }

  local removed=0
  local failed=0
  local target current
  while IFS= read -r target; do
    current=$(readlink "$target")
    if [[ "$current" == "$DEX_DIR"/skills/* ]]; then
      if [[ -e "$current" ]] && [[ ! -d "$current" ]]; then
        continue
      fi
      if rm "$target"; then
        removed=$((removed + 1))
      else
        dx_warn "Could not remove ${target}"
        failed=$((failed + 1))
      fi
    fi
  done < <(find "$codex_dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)

  if [[ $failed -gt 0 ]]; then
    dx_warn "Removed ${removed} Dex Codex skill link(s); failed ${failed}"
    return 1
  elif [[ $removed -gt 0 ]]; then
    dx_done "Removed ${removed} Dex Codex skill link(s)"
  else
    dx_skip "No Dex Codex skill links found"
  fi
}
