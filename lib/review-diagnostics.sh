# shellcheck shell=bash
# Failure copies are diagnostic evidence; they never authorize completion.

__dx_review_cleanup_pass() {
  local parent="$1" child="$2" reason="${3:-}" bundle
  if [[ -n "$reason" ]] \
    && { [[ -e "$(dx_review_result_file "$child")" ]] \
      || [[ -e "$(dx_review_context_file "$child")" ]] \
      || [[ -e "$(dx_review_evidence_file "$child")" ]]; }; then
    if ! bundle=$(python3 "$DEX_DIR/scripts/review_diagnostics.py" capture \
      "$DX_LOOP_DIR" "$parent" "$child" "$reason"); then
      dx_warn "Could not retain review diagnostics; child evidence remains under ${DX_LOOP_DIR}/${child}."
      return 1
    fi
    dx_warn "Review wave evidence retained at ${bundle}."
  fi
  dx_cleanup_session "$child"
}
