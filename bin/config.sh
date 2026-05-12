#!/usr/bin/env bash
# doyaken config — configure integrations for the current project
# Asks which integrations to use and writes the config to .doyaken/doyaken.md.
# Called by `doyaken init` after codebase analysis, and standalone via `doyaken config`.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
  repo_root=""
fi
if [[ -z "$repo_root" ]]; then
  echo "ERROR: Not in a git repository."
  exit 1
fi

doyaken_md="$repo_root/.doyaken/doyaken.md"
if [[ ! -f "$doyaken_md" ]]; then
  echo "ERROR: .doyaken/doyaken.md not found. Run 'dk init' first."
  exit 1
fi

# Clean up temp files on exit (normal or interrupt). The awk sections below
# write to .integrations.tmp / .reviewers.tmp files that must not be left behind.
trap 'rm -f "${doyaken_md}.integrations.tmp" "${doyaken_md}.reviewers.tmp" "${doyaken_md}.tmp" 2>/dev/null' EXIT

echo "Configuring integrations..."
echo ""

# ── Ticket tracker ───────────────────────────────────────────────────────

echo "Ticket tracker:"
echo "  [1] Linear (MCP)"
echo "  [2] GitHub Issues (gh CLI)"
echo "  [3] None"

# Default to GitHub Issues if gh is available, otherwise None
default_tracker=3
if command -v gh &>/dev/null; then
  default_tracker=2
fi

while true; do
  printf "Choice [%s]: " "$default_tracker"
  read -r tracker_choice
  tracker_choice="${tracker_choice:-$default_tracker}"
  case "$tracker_choice" in
    1) TRACKER_TOOL="Linear MCP"; TRACKER_STATUS="enabled"; break ;;
    2) TRACKER_TOOL="GitHub Issues (\`gh\`)"; TRACKER_STATUS="enabled"; break ;;
    3) TRACKER_TOOL="none"; TRACKER_STATUS="not configured"; break ;;
    *) echo "Invalid choice. Enter 1, 2, or 3." ;;
  esac
done

# ── Optional integrations ────────────────────────────────────────────────

ask_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  printf "%s %s: " "$prompt" "$suffix"
  read -r answer
  answer="${answer:-$default}"
  [[ "${answer:0:1}" == "y" || "${answer:0:1}" == "Y" ]]
}

FIGMA_STATUS="not configured"
SENTRY_STATUS="not configured"
HONEYBADGER_STATUS="not configured"
VERCEL_STATUS="not configured"
GRAFANA_STATUS="not configured"
DATADOG_STATUS="not configured"

echo ""
ask_yn "Figma (design context)?" "n" && FIGMA_STATUS="enabled"
ask_yn "Sentry (error monitoring)?" "n" && SENTRY_STATUS="enabled"
ask_yn "Honeybadger (error monitoring)?" "n" && HONEYBADGER_STATUS="enabled"
ask_yn "Vercel (deployments)?" "n" && VERCEL_STATUS="enabled"
ask_yn "Grafana (observability)?" "n" && GRAFANA_STATUS="enabled"
ask_yn "Datadog (observability + APM)?" "n" && DATADOG_STATUS="enabled"

# ── Reviewers ───────────────────────────────────────────────────────────
#
# Phase 6 (Complete) marks the PR ready and assigns these reviewers.
# Two assignment types:
#   request — gh pr edit --add-reviewer <handle>  (humans, Copilot, anything GitHub supports)
#   mention — @<handle> posted as a PR comment   (for AI agents that watch mentions)
#
# Defaults: current authenticated GitHub user + Copilot (both request type).

echo ""
echo "Reviewers (assigned in Phase 6 when PR is marked ready):"

# Auto-detect the current authenticated GitHub user
CURRENT_GH_USER=""
if command -v gh &>/dev/null; then
  CURRENT_GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")
fi

REVIEWER_ROWS=""
if [[ -n "$CURRENT_GH_USER" ]]; then
  echo "  Detected GitHub user: @${CURRENT_GH_USER}"
  if ask_yn "Add @${CURRENT_GH_USER} as a reviewer (request)?" "y"; then
    REVIEWER_ROWS+="| @${CURRENT_GH_USER} | request | Authenticated GitHub user |"$'\n'
  fi
else
  echo "  (Could not auto-detect GitHub user — install/auth gh to enable.)"
fi

if ask_yn "Add Copilot as a reviewer (request)?" "y"; then
  REVIEWER_ROWS+="| Copilot | request | GitHub Copilot review |"$'\n'
fi

echo ""
echo "Add additional reviewers? Enter '<handle> <type>' (type = request|mention),"
echo "or empty to finish. Example: '@dependabot mention' or 'octocat request'"
while true; do
  printf "Reviewer: "
  read -r reviewer_line
  [[ -z "$reviewer_line" ]] && break
  rev_handle=$(echo "$reviewer_line" | awk '{print $1}')
  rev_type=$(echo "$reviewer_line" | awk '{print $2}')
  case "$rev_type" in
    request|mention) ;;
    *) echo "  Invalid type '$rev_type' — must be 'request' or 'mention'. Try again."; continue ;;
  esac
  if [[ -z "$rev_handle" ]]; then
    echo "  Empty handle — skipping."
    continue
  fi
  REVIEWER_ROWS+="| ${rev_handle} | ${rev_type} | Added via dk config |"$'\n'
  echo "  Added: ${rev_handle} (${rev_type})"
done

if [[ -z "$REVIEWER_ROWS" ]]; then
  REVIEWER_ROWS="| _none_ | _none_ | No reviewers configured — Phase 6 will skip review-request and mention steps |"$'\n'
fi

REVIEWERS="## Reviewers

Reviewers assigned when the PR is marked ready for review (Phase 6). Two types:
- \`request\` — \`gh pr edit --add-reviewer <handle>\` (humans, Copilot, anything GitHub supports)
- \`mention\` — \`@<handle>\` posted as a PR comment (for AI agents that watch mentions)

| Handle | Type | Notes |
|--------|------|-------|
${REVIEWER_ROWS}
Edit rows directly or rerun \`dk config\`. Remove a row to skip a reviewer."

# ── Write to doyaken.md ──────────────────────────────────────────────────

INTEGRATIONS="## Integrations

| Integration | Tool | Status |
|-------------|------|--------|
| Ticket tracker | ${TRACKER_TOOL} | ${TRACKER_STATUS} |
| Design | Figma MCP | ${FIGMA_STATUS} |
| Error monitoring (Sentry) | Sentry MCP | ${SENTRY_STATUS} |
| Error monitoring (Honeybadger) | Honeybadger MCP | ${HONEYBADGER_STATUS} |
| Deployments | Vercel MCP | ${VERCEL_STATUS} |
| Observability (Grafana) | Grafana MCP | ${GRAFANA_STATUS} |
| Observability (Datadog) | Datadog MCP | ${DATADOG_STATUS} |

When an integration is \"not configured\", skip any workflow steps that reference it.
For ticket tracking: use the enabled tracker for all status updates, context gathering, and ticket lifecycle management."

# Write integrations content to a temp file (avoids BSD awk multiline -v bug)
INTEGRATIONS_TMP="${doyaken_md}.integrations.tmp"
printf '%s\n' "$INTEGRATIONS" > "$INTEGRATIONS_TMP"

# Replace existing Integrations section, or append before ## Workflow (or at end)
if grep -q '^## Integrations' "$doyaken_md" 2>/dev/null; then
  # Remove from ## Integrations to the next ## heading (or EOF), insert replacement.
  # Pass the temp file path via env var to avoid awk program string injection.
  _DKTMP="$INTEGRATIONS_TMP" awk '
    /^## Integrations/ { skip=1; while ((getline line < ENVIRON["_DKTMP"]) > 0) print line; next }
    skip && /^## / { skip=0 }
    !skip { print }
  ' "$doyaken_md" > "${doyaken_md}.tmp" && mv "${doyaken_md}.tmp" "$doyaken_md"
elif grep -q '^## Workflow' "$doyaken_md" 2>/dev/null; then
  # Insert before ## Workflow
  _DKTMP="$INTEGRATIONS_TMP" awk '
    /^## Workflow/ { while ((getline line < ENVIRON["_DKTMP"]) > 0) print line; print "" }
    { print }
  ' "$doyaken_md" > "${doyaken_md}.tmp" && mv "${doyaken_md}.tmp" "$doyaken_md"
else
  # Append to end
  printf '\n%s\n' "$INTEGRATIONS" >> "$doyaken_md"
fi
rm -f "$INTEGRATIONS_TMP"

# Write Reviewers section using the same temp+awk pattern
REVIEWERS_TMP="${doyaken_md}.reviewers.tmp"
printf '%s\n' "$REVIEWERS" > "$REVIEWERS_TMP"

if grep -q '^## Reviewers' "$doyaken_md" 2>/dev/null; then
  _DKTMP="$REVIEWERS_TMP" awk '
    /^## Reviewers/ { skip=1; while ((getline line < ENVIRON["_DKTMP"]) > 0) print line; next }
    skip && /^## / { skip=0 }
    !skip { print }
  ' "$doyaken_md" > "${doyaken_md}.tmp" && mv "${doyaken_md}.tmp" "$doyaken_md"
elif grep -q '^## Workflow' "$doyaken_md" 2>/dev/null; then
  _DKTMP="$REVIEWERS_TMP" awk '
    /^## Workflow/ { while ((getline line < ENVIRON["_DKTMP"]) > 0) print line; print "" }
    { print }
  ' "$doyaken_md" > "${doyaken_md}.tmp" && mv "${doyaken_md}.tmp" "$doyaken_md"
else
  printf '\n%s\n' "$REVIEWERS" >> "$doyaken_md"
fi
rm -f "$REVIEWERS_TMP"

echo ""
echo "Integrations configured:"
echo "  Ticket tracker: ${TRACKER_TOOL} (${TRACKER_STATUS})"
[[ "$FIGMA_STATUS" == "enabled" ]] && echo "  Figma: enabled"
[[ "$SENTRY_STATUS" == "enabled" ]] && echo "  Sentry: enabled"
[[ "$HONEYBADGER_STATUS" == "enabled" ]] && echo "  Honeybadger: enabled"
[[ "$VERCEL_STATUS" == "enabled" ]] && echo "  Vercel: enabled"
[[ "$GRAFANA_STATUS" == "enabled" ]] && echo "  Grafana: enabled"
[[ "$DATADOG_STATUS" == "enabled" ]] && echo "  Datadog: enabled"
echo ""
echo "Reviewers configured:"
printf '%s' "$REVIEWER_ROWS" | sed 's/^| /  - /; s/ |.*//' | grep -v '^$'

# ── MCP setup hints for newly-enabled integrations ────────────────────────
#
# Print the JSON snippet the user needs to add to .mcp.json or
# ~/.claude/settings.json for each enabled integration. Doyaken does not
# write these for the user — they require API keys/tokens and the user
# may want to manage MCP config themselves.

if [[ "$DATADOG_STATUS" == "enabled" ]] || [[ "$HONEYBADGER_STATUS" == "enabled" ]]; then
  echo ""
  echo "─── MCP setup ─────────────────────────────────────────────────────────"
  echo "Add the following to your .mcp.json (project) or ~/.claude/settings.json"
  echo "(global). Replace placeholders with your real keys/tokens."
fi

if [[ "$DATADOG_STATUS" == "enabled" ]]; then
  cat <<'DDEOF'

Datadog MCP (remote, HTTP transport):

  {
    "mcpServers": {
      "datadog": {
        "type": "http",
        "url": "https://mcp.datadoghq.com",
        "headers": {
          "DD_API_KEY": "<your-api-key>",
          "DD_APPLICATION_KEY": "<your-application-key>"
        }
      }
    }
  }

  Replace the URL with your regional endpoint if you are not on US1:
    US1  https://mcp.datadoghq.com
    US3  https://mcp.us3.datadoghq.com
    US5  https://mcp.us5.datadoghq.com
    EU   https://mcp.datadoghq.eu
    AP1  https://mcp.ap1.datadoghq.com
    AP2  https://mcp.ap2.datadoghq.com

  API key:    https://app.datadoghq.com/organization-settings/api-keys
  App key:    https://app.datadoghq.com/organization-settings/application-keys
  Docs:       https://docs.datadoghq.com/bits_ai/mcp_server/setup/
DDEOF
fi

if [[ "$HONEYBADGER_STATUS" == "enabled" ]]; then
  cat <<'HBEOF'

Honeybadger MCP (local, Docker transport — read-only by default):

  {
    "mcpServers": {
      "honeybadger": {
        "command": "docker",
        "args": [
          "run", "-i", "--rm",
          "-e", "HONEYBADGER_PERSONAL_AUTH_TOKEN",
          "ghcr.io/honeybadger-io/honeybadger-mcp-server"
        ],
        "env": {
          "HONEYBADGER_PERSONAL_AUTH_TOKEN": "<your-personal-auth-token>"
        }
      }
    }
  }

  Optional env vars:
    HONEYBADGER_READ_ONLY  default true; set "false" to enable write ops
    HONEYBADGER_API_URL    default https://app.honeybadger.io

  Auth token: https://app.honeybadger.io (User Settings → Authentication)
  Repo:       https://github.com/honeybadger-io/honeybadger-mcp-server
HBEOF
fi

if [[ "$DATADOG_STATUS" == "enabled" ]] || [[ "$HONEYBADGER_STATUS" == "enabled" ]]; then
  echo ""
  echo "After saving the snippet to .mcp.json, rerun \`dk config\` and accept the"
  echo "MCP-promotion prompt to mirror the server into ~/.claude/settings.json so"
  echo "worktrees inherit it."
fi
# ── Promote MCP servers to global settings ────────────────────────────
#
# Project-level .mcp.json servers require per-directory OAuth. When dk
# creates worktrees, the worktree is a different directory and won't
# share the main repo's MCP auth. Promoting servers to ~/.claude/settings.json
# makes auth global so all worktrees inherit it.

MCP_FILE="$repo_root/.mcp.json"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [[ -f "$MCP_FILE" ]] && command -v jq &>/dev/null; then
  # Find servers in .mcp.json that aren't already in global settings
  new_servers=""
  if [[ -f "$SETTINGS_FILE" ]]; then
    new_servers=$(jq -rs '
      (.[1].mcpServers // {} | keys) - (.[0].mcpServers // {} | keys)
      | .[]
    ' "$SETTINGS_FILE" "$MCP_FILE" 2>/dev/null || true)
  else
    new_servers=$(jq -r '.mcpServers // {} | keys | .[]' "$MCP_FILE" 2>/dev/null || true)
  fi

  if [[ -n "$new_servers" ]]; then
    server_count=$(echo "$new_servers" | wc -l | tr -d ' ')
    echo ""
    echo "Found ${server_count} MCP server(s) in .mcp.json not in global settings:"
    echo "$new_servers" | while IFS= read -r name; do
      echo "  - $name"
    done
    echo ""
    if ask_yn "Promote to ~/.claude/settings.json for worktree compatibility?" "y"; then
      if [[ ! -f "$SETTINGS_FILE" ]]; then
        mkdir -p "$(dirname "$SETTINGS_FILE")"
        TMPFILE="${SETTINGS_FILE}.tmp.$$"
        if ! printf '%s\n' '{}' > "$TMPFILE" || ! mv "$TMPFILE" "$SETTINGS_FILE"; then
          rm -f "$TMPFILE" 2>/dev/null || true
          dk_warn "Failed to create settings.json — MCP promotion skipped"
          echo ""
          echo "To reconfigure later, run: dk config"
          exit 0
        fi
      fi
      # Merge .mcp.json servers into global settings.json mcpServers
      if merged=$(jq -s '
        .[0] + {mcpServers: ((.[0].mcpServers // {}) + (.[1].mcpServers // {}))}
      ' "$SETTINGS_FILE" "$MCP_FILE" 2>/dev/null) && [[ -n "$merged" ]]; then
        TMPFILE="${SETTINGS_FILE}.tmp.$$"
        if printf '%s\n' "$merged" > "$TMPFILE" && mv "$TMPFILE" "$SETTINGS_FILE"; then
          dk_done "Promoted MCP servers to global settings"
        else
          rm -f "$TMPFILE" 2>/dev/null || true
          dk_warn "Failed to merge MCP servers — settings.json left unchanged"
        fi
      else
        dk_warn "Failed to merge MCP servers — settings.json left unchanged"
      fi
    else
      dk_skip "Skipped MCP promotion"
    fi
  fi
fi

echo ""
echo "To reconfigure later, run: dk config"
