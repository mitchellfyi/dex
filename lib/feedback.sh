# shellcheck shell=bash
# The feedback outbox (scripts/feedback_outbox.py): where a mission leaves a
# bounded, sanitised candidate for the Dex research consumer
# (research/consume.sh). Loaded on demand like lib/mission.sh.

# dx_feedback_dir — ${DX_FEEDBACK_DIR} or ~/.dex/feedback.
dx_feedback_dir() {
  printf '%s\n' "${DX_FEEDBACK_DIR:-$HOME/.dex/feedback}"
}

# dx_feedback_outbox <command> [args…] — run the outbox CLI.
dx_feedback_outbox() {
  python3 "$DEX_DIR/scripts/feedback_outbox.py" "$(dx_feedback_dir)" "$@"
}

# dx_feedback_consume_due [report_file]
# Run the research consumer over this machine's outbox when it holds anything
# to decide (captured or eligible candidates), with the caps that make it
# bounded. Nightly maintenance calls this so the feedback loop closes without
# anyone invoking it. DEX_MAINTAIN_CONSUME=0 turns it off; DX_FEEDBACK_CONSUMER
# substitutes the consumer (tests use a stub). Prints the summary line and
# appends it to the report when one is given. Never fails the caller.
dx_feedback_consume_due() {
  local report_file="${1:-}" consumer="${DX_FEEDBACK_CONSUMER:-$DEX_DIR/research/consume.sh}" pending summary
  [[ "${DEX_MAINTAIN_CONSUME:-1}" != 0 ]] || return 0
  [[ -f "$consumer" ]] || return 0
  [[ -d "$(dx_feedback_dir)" ]] || return 0
  pending=$(dx_feedback_outbox list 2>/dev/null | python3 -c 'import json,sys
rows = json.load(sys.stdin)
print(sum(1 for r in rows if r.get("state") in ("captured", "eligible")))' 2>/dev/null || echo 0)
  if [[ "$pending" == 0 ]]; then
    dx_info "Feedback outbox: nothing to decide."
    return 0
  fi
  dx_info "Feedback outbox: ${pending} candidate(s) to decide; running the research consumer."
  summary=$(bash "$consumer" \
    --max-candidates "${DEX_MAINTAIN_CONSUME_MAX_CANDIDATES:-5}" \
    --max-minutes "${DEX_MAINTAIN_CONSUME_MAX_MINUTES:-20}" \
    --max-iterations 3 2>&1 | tail -1) || true
  [[ -n "$summary" ]] || summary='{"error": "the consumer produced no summary"}'
  dx_info "Feedback consumer: ${summary}"
  if [[ -n "$report_file" ]]; then
    printf '\n## Feedback consumer\n\n```json\n%s\n```\n' "$summary" >> "$report_file" 2>/dev/null || true
  fi
  return 0
}
