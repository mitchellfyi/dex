# shellcheck shell=bash
# Doyaken helpers for Codex CLI integration.

dk_codex_skills_dir() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills"
}

dk_count_doyaken_skills() {
  local count=0
  local skill_dir
  for skill_dir in "$DOYAKEN_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

dk_codex_skill_link_repairable() {
  local current="$1" skill_name="$2"
  case "$current" in
    */doyaken*/skills/"$skill_name"|*/doyaken*/skills/"$skill_name"/) return 0 ;;
    *) return 1 ;;
  esac
}

dk_install_codex_skills() {
  local codex_dir
  codex_dir=$(dk_codex_skills_dir)
  if ! mkdir -p "$codex_dir"; then
    dk_warn "Could not create ${codex_dir}; skipping Codex skill links"
    return 1
  fi

  local installed=0
  local expected=0
  local failed=0
  local repaired=0
  local skipped=0
  local skill_dir skill_name target current
  for skill_dir in "$DOYAKEN_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    expected=$((expected + 1))
    skill_name=$(basename "$skill_dir")
    target="$codex_dir/$skill_name"

    if [[ -L "$target" ]]; then
      current=$(readlink "$target")
      if [[ "$current" == "$skill_dir" ]]; then
        installed=$((installed + 1))
      elif dk_codex_skill_link_repairable "$current" "$skill_name"; then
        if rm "$target" && ln -s "$skill_dir" "$target"; then
          installed=$((installed + 1))
          repaired=$((repaired + 1))
        else
          failed=$((failed + 1))
        fi
      else
        dk_warn "${codex_dir}/${skill_name} is a symlink to ${current} — leaving it unchanged"
        skipped=$((skipped + 1))
      fi
    elif [[ -e "$target" ]]; then
      dk_warn "${codex_dir}/${skill_name} exists and is not a symlink — leaving it unchanged"
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
    dk_warn "Installed ${installed}/${expected} Codex skill link(s); repaired ${repaired}; skipped ${skipped}; failed ${failed}"
    return 1
  else
    dk_done "Installed ${installed}/${expected} Doyaken skill link(s) for Codex CLI"
  fi
}

dk_count_codex_doyaken_skills() {
  local codex_dir
  codex_dir=$(dk_codex_skills_dir)
  [[ -d "$codex_dir" ]] || {
    printf '%s\n' "0"
    return 0
  }

  local count=0
  local skill_dir skill_name target current
  for skill_dir in "$DOYAKEN_DIR"/skills/*; do
    [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
    skill_name=$(basename "$skill_dir")
    target="$codex_dir/$skill_name"
    if [[ -L "$target" ]]; then
      current=$(readlink "$target")
      [[ "$current" == "$skill_dir" ]] && count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

dk_codex_doyaken_skills_complete() {
  local expected installed
  expected=$(dk_count_doyaken_skills)
  installed=$(dk_count_codex_doyaken_skills)
  [[ "$expected" -gt 0 && "$installed" -eq "$expected" ]]
}

dk_uninstall_codex_skills() {
  local codex_dir
  codex_dir=$(dk_codex_skills_dir)
  [[ -d "$codex_dir" ]] || {
    dk_skip "${codex_dir} does not exist"
    return 0
  }

  local removed=0
  local failed=0
  local target current skill_name
  while IFS= read -r target; do
    current=$(readlink "$target")
    skill_name=$(basename "$target")
    if [[ "$current" == "$DOYAKEN_DIR"/skills/* ]] || dk_codex_skill_link_repairable "$current" "$skill_name"; then
      if [[ -e "$current" ]] && [[ ! -d "$current" ]]; then
        continue
      fi
        if rm "$target"; then
          removed=$((removed + 1))
        else
          dk_warn "Could not remove ${target}"
          failed=$((failed + 1))
        fi
    fi
  done < <(find "$codex_dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)

  if [[ $failed -gt 0 ]]; then
    dk_warn "Removed ${removed} Doyaken Codex skill link(s); failed ${failed}"
    return 1
  elif [[ $removed -gt 0 ]]; then
    dk_done "Removed ${removed} Doyaken Codex skill link(s)"
  else
    dk_skip "No Doyaken Codex skill links found"
  fi
}
