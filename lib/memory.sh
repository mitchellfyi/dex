# shellcheck shell=bash
# The external memory store (scripts/memory_store.py): where observations go
# before `dx sync` promotes any of them into .dex/memory. One store per
# repository identity, outside the checkout, so a worktree and its main repo
# share it and two repositories never do. Loaded on demand like lib/mission.sh.

# dx_memory_store_dir [repo_root]
# ${DX_MEMORY_STORE_DIR} when set (experiment arms isolate through it); else
# ~/.claude/.dex-memory/<repo-key>, the key dx_session_repo_key derives from
# the repository's git common dir.
dx_memory_store_dir() {
  local repo_root="${1:-}" repo_key
  if [[ -n "${DX_MEMORY_STORE_DIR:-}" ]]; then
    printf '%s\n' "$DX_MEMORY_STORE_DIR"
    return 0
  fi
  if [[ -n "$repo_root" ]]; then
    repo_key=$(cd "$repo_root" 2>/dev/null && dx_session_repo_key) || return 1
  else
    repo_key=$(dx_session_repo_key) || return 1
  fi
  printf '%s/.claude/.dex-memory/%s\n' "$HOME" "$repo_key"
}

# dx_memory_store <repo_root> <command> [args…] — run the store CLI for a repo.
dx_memory_store() {
  local repo_root="$1" store_dir
  shift
  store_dir=$(dx_memory_store_dir "$repo_root") || return 1
  python3 "$DEX_DIR/scripts/memory_store.py" "$store_dir" "$@"
}

# dx_memory_retrieve <repo_root> <paths-csv> <session_id> <role> [phase]
# The scoped memory view for a session or helper, with its trace written.
dx_memory_retrieve() {
  local repo_root="$1" paths_csv="$2" session_id="$3" role="${4:-lead}" phase="${5:-}"
  local -a extra=()
  [[ -n "$phase" ]] && extra+=(--phase "$phase")
  # The guarded form: bash 3.2 reads "${extra[@]}" of an empty array as an
  # unbound variable under set -u, which failed every retrieval with no phase.
  dx_memory_store "$repo_root" retrieve --repo "$repo_root" --paths "$paths_csv" \
    --session "$session_id" --role "$role" ${extra[@]+"${extra[@]}"}
}

# dx_memory_ingest_mission <session_id> <repo_root>
# Feed the observations helpers left in the mission ledger directory into the
# store, from where the last ingest stopped (a byte cursor beside the file),
# so a session that ends twice does not ingest twice. Prints the summary.
dx_memory_ingest_mission() {
  local session_id="$1" repo_root="$2" ledger_dir observations cursor_file offset size chunk
  ledger_dir="${DX_STATE_DIR}/${session_id}.mission"
  observations="$ledger_dir/observations.jsonl"
  [[ -s "$observations" ]] || return 0
  cursor_file="$ledger_dir/observations.ingested"
  offset=0
  [[ -f "$cursor_file" ]] && offset=$(tr -dc '0-9' < "$cursor_file")
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  size=$(wc -c < "$observations" | tr -d ' ')
  [[ "$size" -gt "$offset" ]] || return 0
  chunk=$(mktemp "${TMPDIR:-/tmp}/dx-memory-chunk.XXXXXX") || return 1
  tail -c +"$((offset + 1))" "$observations" > "$chunk"
  if dx_memory_store "$repo_root" ingest --repo "$repo_root" --source "mission:${session_id}" "$chunk"; then
    printf '%s\n' "$size" > "$cursor_file"
    chmod 600 "$cursor_file" 2>/dev/null || true
  fi
  rm -f "$chunk"
}

# dx_memory_maintain <repo_root> [maintain args…]
# The deterministic pass: promote what independent sessions corroborate,
# retire what stayed stale, idle or unused past its window. No model call.
dx_memory_maintain() {
  local repo_root="$1"
  shift
  dx_memory_store "$repo_root" maintain --repo "$repo_root" "$@"
}

# dx_memory_curate_if_due <repo_root> [curate args…]
# The critical review, run as a fresh bounded model session by bin/memory.sh
# when the store changed enough since the last one. DEX_MEMORY_CURATE=0
# turns it off; maintenance still runs at session end.
dx_memory_curate_if_due() {
  local repo_root="$1"
  shift
  [[ "${DEX_MEMORY_CURATE:-1}" != 0 ]] || return 0
  bash "$DEX_DIR/bin/memory.sh" --repo "$repo_root" curate "$@"
}

# dx_memory_land <repo_root> [land args…]
# Curator-promoted entries become tracked .dex/memory entries on a
# dex/memory-* branch (bin/memory.sh land). DEX_MEMORY_LAND=0 turns it off.
dx_memory_land() {
  local repo_root="$1"
  shift
  [[ "${DEX_MEMORY_LAND:-1}" != 0 ]] || return 0
  bash "$DEX_DIR/bin/memory.sh" --repo "$repo_root" land "$@"
}

# dx_memory_harvest_session <session_id> <repo_root>
# Turn the lifecycle's own artifacts (review findings, override and waiver
# reasons, waived phases, failed gates, guard warnings) into store
# observations, once per session: a marker beside the session state stops a
# second completion or a cleanup sweep from ingesting them again. Runs before
# the state is removed; no model call. Prints the ingest summary.
dx_memory_harvest_session() {
  local session_id="$1" repo_root="$2" marker rows
  marker="${DX_STATE_DIR}/${session_id}.harvested"
  if [[ -f "$marker" ]]; then
    printf '{"skipped": "already harvested", "session": "%s"}\n' "$session_id"
    return 0
  fi
  rows=$(mktemp "${TMPDIR:-/tmp}/dx-harvest.XXXXXX") || return 1
  if ! python3 "$DEX_DIR/scripts/lifecycle_harvest.py" "$session_id" --repo "$repo_root" > "$rows"; then
    rm -f "$rows"
    return 1
  fi
  if [[ ! -s "$rows" ]]; then
    rm -f "$rows"
    mkdir -p "$DX_STATE_DIR" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker" 2>/dev/null || true
    printf '{"ingested": 0, "session": "%s"}\n' "$session_id"
    return 0
  fi
  if dx_memory_store "$repo_root" ingest --repo "$repo_root" --source "lifecycle:${session_id}" "$rows"; then
    mkdir -p "$DX_STATE_DIR" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$marker" 2>/dev/null || true
    chmod 600 "$marker" 2>/dev/null || true
  fi
  rm -f "$rows"
}
