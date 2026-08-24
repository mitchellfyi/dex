#!/usr/bin/env bash

test_command_write_common() {
  local install_root="$1"
  mkdir -p "$install_root/lib"
  cat > "$install_root/lib/common.sh" <<'EOF'
dx_error() { printf 'ERROR: %s\n' "$*" >&2; }
dx_info() { printf 'INFO: %s\n' "$*"; }
dx_done() { printf 'DONE: %s\n' "$*"; }

dx_provider_apply() {
  printf 'apply\n' >> "${TEST_PROVIDER_LOG:?}"
  DX_PROVIDER_PROFILE_RESOLVED="test-profile"
  DX_PROVIDER_ENGINE="claude"
  return "${TEST_PROVIDER_APPLY_EXIT:-0}"
}

dx_provider_agent_ready_check() {
  printf 'ready\n' >> "${TEST_PROVIDER_LOG:?}"
  return "${TEST_PROVIDER_READY_EXIT:-0}"
}

dx_provider_prompt() {
  printf '\nProvider profile guidance.\n'
}

dx_provider_claude() {
  printf 'launch:%s\n' "$PWD" >> "${TEST_PROVIDER_LOG:?}"
  printf '%s\n' "$@" > "${TEST_PROVIDER_ARGS_LOG:?}"
  if [[ "${1:-}" == "-p" && -n "${2:-}" ]]; then
    printf '%s\n' "$2" > "${TEST_PROVIDER_PROMPT_LOG:?}"
  fi
  return "${TEST_PROVIDER_LAUNCH_EXIT:-0}"
}
EOF
}

test_command_make_install() {
  local install_root="$1"
  test_command_write_common "$install_root"
  mkdir -p "$install_root/tests" "$install_root/src"
  git -C "$install_root" init -q
  cat > "$install_root/tests/check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'check:%s\n' "$PWD" >> "${TEST_DEX_LOG:?}"
exit "${TEST_CHECK_EXIT:-0}"
EOF
  cat > "$install_root/tests/run-all.sh" <<'EOF'
#!/usr/bin/env bash
printf 'suite:%s\n' "$PWD" >> "${TEST_DEX_LOG:?}"
printf 'filter:%s\n' "$@" >> "${TEST_DEX_LOG:?}"
exit "${TEST_SUITE_EXIT:-0}"
EOF
}

test_command_make_project() {
  local project_root="$1"
  mkdir -p "$project_root/.dex" "$project_root/src"
  git -C "$project_root" init -q
  cat > "$project_root/.dex/dex.md" <<'EOF'
# Test project

## Quality Gates

- Run the project checks.
EOF
}
