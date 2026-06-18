# shellcheck shell=bash
# Dex provider profile helpers.
#
# Profiles select how Dex should spend model work. The public agent layer maps
# stable names such as "claude" and "codex" onto those profiles so CLI flags do
# not need to know internal engine names. Subscription-safe profiles
# intentionally avoid API-key credentials that would bypass subscription billing.

DX_PROVIDER_GLOBAL_CONFIG="$HOME/.dex/providers.json"

dx_provider_repo_config() {
  local root
  root=$(dx_repo_root 2>/dev/null) || return 1
  printf '%s\n' "$root/.dex/providers.json"
}

__dx_provider_json_default() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
value = data.get("default", "")
if isinstance(value, str) and value:
    print(value)
    sys.exit(0)
sys.exit(1)
' "$file"
}

__dx_provider_json_get() {
  local file="$1" profile="$2" key="$3"
  [[ -f "$file" ]] || return 1
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
profile = data.get("profiles", {}).get(sys.argv[2], {})
value = profile.get(sys.argv[3], "")
if isinstance(value, str) and value:
    print(value)
else:
    sys.exit(1)
' "$file" "$profile" "$key"
}

dx_provider_validate_config_file() {
  local file="$1" scope="${2:-config}"
  [[ -f "$file" ]] || return 0
  if ! python3 -c '
import json
import re
import sys
from urllib.parse import urlparse

BUILTINS = {"claude-subscription", "codex-subscription"}
KNOWN_KEYS = {
    "engine",
    "auth",
    "base_url",
    "auth_env",
    "model",
    "plan_model",
    "haiku_model",
    "effort",
    "plan_effort",
    "codex_model",
}
ENGINES = {"claude", "codex-plugin", "anthropic-gateway"}
AUTH_BY_ENGINE = {
    "claude": {"subscription"},
    "codex-plugin": {"chatgpt-subscription"},
    "anthropic-gateway": {"api-token", "none"},
}
KEYS_BY_ENGINE = {
    "claude": {"engine", "auth", "model", "plan_model", "haiku_model", "effort", "plan_effort"},
    "codex-plugin": {"engine", "auth", "model", "plan_model", "haiku_model", "effort", "plan_effort", "codex_model"},
    "anthropic-gateway": {"engine", "auth", "base_url", "auth_env", "model", "plan_model", "haiku_model", "effort", "plan_effort"},
}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
AUTH_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASS|CREDENTIAL|CREDENTIALS)$")
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]*$")
REPO_AUTH_ENV_DENY_EXACT = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "OPENAI_API_KEY",
    "OPENAI_ADMIN_KEY",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITLAB_TOKEN",
    "NPM_TOKEN",
    "PYPI_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
}
REPO_AUTH_ENV_DENY_PREFIXES = (
    "ANTHROPIC_",
    "OPENAI_",
    "AWS_",
    "AZURE_",
    "GOOGLE_",
    "GCP_",
    "GITHUB_",
    "GH_",
    "GITLAB_",
    "NPM_",
    "PYPI_",
    "SENTRY_",
    "LINEAR_",
    "SLACK_",
    "STRIPE_",
    "VERCEL_",
    "CLOUDFLARE_",
    "DOCKER_",
    "DATABASE_",
    "POSTGRES_",
    "MYSQL_",
    "REDIS_",
)

def validate_base_url(name, value):
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError(f"profile {name!r} has invalid base_url")
    if parsed.username or parsed.password:
        raise ValueError(f"profile {name!r} base_url must not include credentials")
    if parsed.query or parsed.fragment:
        raise ValueError(f"profile {name!r} base_url must not include query or fragment")
    if (parsed.hostname or "").lower() == "api.openai.com":
        raise ValueError(f"profile {name!r} base_url points directly at OpenAI API, which is not Anthropic-compatible")

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise ValueError("top-level value must be an object")
for key in data:
    if key not in {"default", "profiles"}:
        raise ValueError(f"unsupported top-level key {key!r}")
if "default" in data and not isinstance(data["default"], str):
    raise ValueError("default must be a string")
scope = sys.argv[2]
profiles = data.get("profiles", {})
if not isinstance(profiles, dict):
    raise ValueError("profiles must be an object")
for name, profile in profiles.items():
    if not isinstance(name, str) or not isinstance(profile, dict):
        raise ValueError("profile entries must be objects keyed by strings")
    if name in BUILTINS:
        raise ValueError(f"profile {name!r} uses a reserved built-in profile name")
    for key, value in profile.items():
        if key not in KNOWN_KEYS:
            raise ValueError(f"profile {name!r} has unknown key {key!r}")
        if not isinstance(value, str) or not value:
            raise ValueError(f"profile {name!r} key {key!r} must be a non-empty string")
    engine = profile.get("engine")
    if engine not in ENGINES:
        raise ValueError(f"profile {name!r} has unsupported engine")
    for key in profile:
        if key not in KEYS_BY_ENGINE[engine]:
            raise ValueError(f"profile {name!r} key {key!r} is not valid for engine {engine!r}")
    auth = profile.get("auth", "")
    if not auth:
        raise ValueError(f"profile {name!r} must define auth")
    if auth not in AUTH_BY_ENGINE[engine]:
        raise ValueError(f"profile {name!r} has unsupported auth for engine")
    if engine == "anthropic-gateway":
        if not profile.get("model"):
            raise ValueError(f"profile {name!r} must define model")
        if not profile.get("base_url"):
            raise ValueError(f"profile {name!r} must define base_url")
        validate_base_url(name, profile["base_url"])
        if auth == "api-token" and not profile.get("auth_env"):
            raise ValueError(f"profile {name!r} with api-token auth must define auth_env")
        if auth == "none" and profile.get("auth_env"):
            raise ValueError(f"profile {name!r} with none auth must not define auth_env")
    elif profile.get("auth_env"):
        raise ValueError(f"profile {name!r} auth_env is only valid for anthropic-gateway profiles")
    auth_env = profile.get("auth_env", "")
    if auth_env and (not ENV_RE.match(auth_env) or not AUTH_ENV_RE.match(auth_env)):
        raise ValueError(f"profile {name!r} has invalid auth_env")
    if scope == "repo" and auth_env and (auth_env in REPO_AUTH_ENV_DENY_EXACT or auth_env.startswith(REPO_AUTH_ENV_DENY_PREFIXES)):
        raise ValueError(f"profile {name!r} uses a reserved/common credential auth_env that is not allowed in repo config")
    for key in ("model", "plan_model", "haiku_model", "codex_model"):
        if profile.get(key) and not MODEL_RE.match(profile[key]):
            raise ValueError(f"profile {name!r} has invalid {key}")
    for key in ("effort", "plan_effort"):
        if profile.get(key) and profile[key] not in EFFORTS:
            raise ValueError(f"profile {name!r} has invalid {key}")
default = data.get("default", "")
if default and default not in BUILTINS and default not in profiles:
    raise ValueError(f"{scope} default does not resolve in this config")
' "$file" "$scope" 2>/dev/null; then
    dx_error "Provider config is invalid: $file"
    dx_info "Use string values, unique non-built-in profile names, valid engines, and a default defined in that file or built in."
    return 1
  fi
}

dx_provider_validate_config_files() {
  local repo_config
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)
  if [[ -n "$repo_config" ]]; then
    dx_provider_validate_config_file "$repo_config" "repo" || return 1
  fi
  dx_provider_validate_config_file "$DX_PROVIDER_GLOBAL_CONFIG" "global" || return 1
}

__dx_provider_builtin_get() {
  local profile="$1" key="$2"
  case "$profile:$key" in
    claude-subscription:engine) printf '%s\n' "claude" ;;
    claude-subscription:auth) printf '%s\n' "subscription" ;;
    codex-subscription:engine) printf '%s\n' "codex-plugin" ;;
    codex-subscription:auth) printf '%s\n' "chatgpt-subscription" ;;
    *) return 1 ;;
  esac
}

dx_provider_is_builtin() {
  __dx_provider_builtin_get "$1" "engine" >/dev/null 2>&1
}

dx_provider_repo_gateway_allowed() {
  [[ "${DX_ALLOW_REPO_GATEWAY_PROVIDER:-0}" == "1" ]]
}

dx_provider_repo_profile_engine() {
  local profile="$1" repo_config
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)
  [[ -n "$repo_config" ]] || return 1
  __dx_provider_json_get "$repo_config" "$profile" "engine"
}

dx_provider_repo_default_profile() {
  local repo_config default_profile engine
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)
  [[ -n "$repo_config" ]] || return 1
  default_profile=$(__dx_provider_json_default "$repo_config" 2>/dev/null || true)
  [[ -n "$default_profile" ]] || return 1
  if dx_provider_is_builtin "$default_profile"; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  engine=$(__dx_provider_json_get "$repo_config" "$default_profile" "engine" 2>/dev/null || true)
  if [[ "$engine" == "anthropic-gateway" ]] && ! dx_provider_repo_gateway_allowed; then
    dx_warn "Ignoring repo provider default ${default_profile}: repo gateway/API profiles require DX_ALLOW_REPO_GATEWAY_PROVIDER=1 or a global user profile."
    return 1
  fi
  printf '%s\n' "$default_profile"
}

dx_provider_default_profile() {
  local default_profile
  dx_provider_validate_config_files || return 1
  default_profile=$(dx_provider_repo_default_profile 2>/dev/null || true)
  if [[ -n "$default_profile" ]]; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  default_profile=$(__dx_provider_json_default "$DX_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
  if [[ -n "$default_profile" ]]; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  printf '%s\n' "claude-subscription"
}

dx_provider_resolve_source() {
  local profile="$1" preferred="${2:-auto}" repo_config
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)

  case "$preferred" in
    repo)
      if dx_provider_is_builtin "$profile"; then
        printf '%s\n' "builtin:"
        return 0
      fi
      if [[ -n "$repo_config" ]] && __dx_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
        printf '%s\n' "repo:$repo_config"
        return 0
      fi
      return 1
      ;;
    global)
      if dx_provider_is_builtin "$profile"; then
        printf '%s\n' "builtin:"
        return 0
      fi
      if __dx_provider_json_get "$DX_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
        printf '%s\n' "global:$DX_PROVIDER_GLOBAL_CONFIG"
        return 0
      fi
      return 1
      ;;
  esac

  if dx_provider_is_builtin "$profile"; then
    printf '%s\n' "builtin:"
  elif [[ -n "$repo_config" ]] && __dx_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
    printf '%s\n' "repo:$repo_config"
  elif __dx_provider_json_get "$DX_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
    printf '%s\n' "global:$DX_PROVIDER_GLOBAL_CONFIG"
  else
    return 1
  fi
}

dx_provider_get() {
  local profile="$1" key="$2" source="${3:-}" source_kind source_file
  if [[ -z "$source" ]]; then
    source=$(dx_provider_resolve_source "$profile") || return 1
  fi
  source_kind="${source%%:*}"
  source_file="${source#*:}"
  case "$source_kind" in
    repo|global) __dx_provider_json_get "$source_file" "$profile" "$key" ;;
    builtin) __dx_provider_builtin_get "$profile" "$key" ;;
    *) return 1 ;;
  esac
}

dx_provider_config_auth_env_unsets() {
  local repo_config
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)
  python3 - "$repo_config" "$DX_PROVIDER_GLOBAL_CONFIG" <<'PY'
import json
import re
import sys

seen = set()
for path in sys.argv[1:]:
    if not path:
        continue
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue
    for profile in data.get("profiles", {}).values():
        value = profile.get("auth_env", "")
        if isinstance(value, str) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", value) and value not in seen:
            seen.add(value)
            print(value)
PY
}

dx_provider_external_env_names() {
  {
    cat <<'EOF'
ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_CUSTOM_HEADERS
ANTHROPIC_IDENTITY_TOKEN
ANTHROPIC_UNIX_SOCKET
ANTHROPIC_BEDROCK_BASE_URL
ANTHROPIC_BEDROCK_MANTLE_API_KEY
ANTHROPIC_BEDROCK_MANTLE_BASE_URL
ANTHROPIC_FOUNDRY_API_KEY
ANTHROPIC_FOUNDRY_AUTH_TOKEN
ANTHROPIC_FOUNDRY_BASE_URL
ANTHROPIC_FOUNDRY_RESOURCE
ANTHROPIC_VERTEX_BASE_URL
ANTHROPIC_VERTEX_PROJECT_ID
AWS_BEARER_TOKEN_BEDROCK
CLAUDE_CODE_SKIP_BEDROCK_AUTH
CLAUDE_CODE_SKIP_VERTEX_AUTH
CLAUDE_CODE_USE_BEDROCK
CLAUDE_CODE_USE_FOUNDRY
CLAUDE_CODE_USE_MANTLE
CLAUDE_CODE_USE_VERTEX
OPENAI_API_KEY
OPENAI_ADMIN_KEY
OPENAI_BASE_URL
OPENAI_ORG_ID
OPENAI_ORGANIZATION
OPENAI_PROJECT
EOF
    env | while IFS='=' read -r env_name _; do
      case "$env_name" in
        ANTHROPIC_AWS_*|ANTHROPIC_BEDROCK_*|ANTHROPIC_FOUNDRY_*|ANTHROPIC_MANTLE_*|ANTHROPIC_VERTEX_*|OPENAI_*)
          printf '%s\n' "$env_name"
          ;;
      esac
    done
  } | awk 'NF && !seen[$0]++'
}

dx_provider_env_value() {
  command printenv "$1" 2>/dev/null || true
}

dx_provider_claude_override_env_names() {
  cat <<'EOF'
ANTHROPIC_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION
ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES
ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTS
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION
ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES
ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTS
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION
ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES
ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTS
ANTHROPIC_CUSTOM_MODEL_OPTION
ANTHROPIC_CUSTOM_MODEL_OPTION_NAME
ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION
ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES
ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTS
ANTHROPIC_SMALL_FAST_MODEL
CLAUDE_CODE_SUBAGENT_MODEL
CLAUDE_CODE_EFFORT_LEVEL
EOF
}

__dx_provider_write_state_file() {
  local state_file="$1" session_id="$2" tmp_file
  tmp_file="${state_file}.$$"
  if ! {
    printf 'engine=%s\n' "$DX_PROVIDER_ENGINE"
    printf 'session=%s\n' "$session_id"
  } > "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
  if ! command mv -f "$tmp_file" "$state_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

dx_provider_write_session_state() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0
  [[ -n "${DX_PROVIDER_ENGINE:-}" ]] || return 0

  mkdir -p "$DX_LOOP_DIR" || return 1
  __dx_provider_write_state_file "$(dx_provider_state_file "$session_id")" "$session_id" || return 1

  local alias_id
  alias_id=$(dx_session_id 2>/dev/null || true)
  if [[ -n "$alias_id" && "$alias_id" != "$session_id" ]]; then
    __dx_provider_write_state_file "$(dx_provider_state_file "$alias_id")" "$session_id" || return 1
  fi
}

__dx_provider_state_file_belongs_to_session() {
  local state_file="$1" session_id="$2" line state_session=""
  [[ -f "$state_file" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      session=*) state_session="${line#session=}" ;;
    esac
  done < "$state_file"
  [[ "$state_session" == "$session_id" ]]
}

dx_provider_cleanup_session_state() {
  local session_id="$1" alias_id alias_file
  [[ -n "$session_id" ]] || return 0
  rm -f "$(dx_provider_state_file "$session_id")" 2>/dev/null

  alias_id=$(dx_session_id 2>/dev/null || true)
  if [[ -n "$alias_id" && "$alias_id" != "$session_id" ]]; then
    alias_file=$(dx_provider_state_file "$alias_id")
    if __dx_provider_state_file_belongs_to_session "$alias_file" "$session_id"; then
      rm -f "$alias_file" 2>/dev/null
    fi
  fi
}

dx_agent_normalize() {
  local agent="${1:-}"
  case "$agent" in
    ""|default|Default|claude|Claude|claude-code|ClaudeCode|claudecode)
      printf '%s\n' "claude"
      ;;
    codex|Codex|codex-cli|openai-codex|OpenAICodex)
      printf '%s\n' "codex"
      ;;
    *)
      dx_error "Unsupported agent: $agent"
      dx_info "Supported agents: claude, codex"
      return 1
      ;;
  esac
}

dx_agent_label() {
  case "$1" in
    codex) printf '%s\n' "Codex" ;;
    *) printf '%s\n' "Claude" ;;
  esac
}

dx_agent_default_profile() {
  case "$1" in
    claude) printf '%s\n' "claude-subscription" ;;
    codex) printf '%s\n' "codex-subscription" ;;
    *) return 1 ;;
  esac
}

dx_agent_for_engine() {
  case "$1" in
    claude|anthropic-gateway) printf '%s\n' "claude" ;;
    codex-plugin) printf '%s\n' "codex" ;;
    *) return 1 ;;
  esac
}

dx_provider_profile_agent() {
  local profile="$1" preferred="${2:-auto}" source engine
  source=$(dx_provider_resolve_source "$profile" "$preferred") || return 1
  engine=$(dx_provider_get "$profile" "engine" "$source" 2>/dev/null || true)
  [[ -n "$engine" ]] || return 1
  dx_agent_for_engine "$engine"
}

dx_provider_profile_matches_agent() {
  local profile="$1" preferred="$2" agent="$3" profile_agent
  profile_agent=$(dx_provider_profile_agent "$profile" "$preferred" 2>/dev/null || true)
  [[ "$profile_agent" == "$agent" ]]
}

dx_agent_host() {
  case "${DEX_AGENT_HOST:-${DX_AGENT_HOST:-auto}}" in
    codex|Codex)
      printf '%s\n' "codex"
      return 0
      ;;
    claude|Claude)
      printf '%s\n' "claude"
      return 0
      ;;
    auto|"") ;;
    *)
      dx_warn "Unknown DEX_AGENT_HOST '${DEX_AGENT_HOST:-${DX_AGENT_HOST:-}}'; using auto detection."
      ;;
  esac

  if [[ -n "${CODEX_THREAD_ID:-}" || "${CODEX_CI:-}" == "1" || -n "${CODEX_MANAGED_BY_NPM:-}" ]]; then
    printf '%s\n' "codex"
    return 0
  fi

  if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" || -n "${CLAUDE_CODE_SSE_PORT:-}" || -n "${CLAUDECODE:-}" ]]; then
    printf '%s\n' "claude"
    return 0
  fi

  printf '%s\n' "claude"
}

dx_agent_host_label() {
  case "$(dx_agent_host)" in
    codex) printf '%s\n' "Codex" ;;
    *) printf '%s\n' "Claude" ;;
  esac
}

dx_provider_codex_exec() {
  local prompt="$1" cwd="${2:-}"
  local codex_args

  [[ -n "$cwd" ]] || cwd=$(pwd)
  dx_provider_codex_ready_check || return 1

  codex_args=(exec --ignore-user-config --dangerously-bypass-approvals-and-sandbox -C "$cwd")
  if [[ -n "${DX_CODEX_MODEL:-}" ]]; then
    codex_args+=(-m "$DX_CODEX_MODEL")
  fi
  codex_args+=(-)

  printf '%s\n' "$prompt" | DX_PROVIDER_CODEX_WRAPPER=1 dx_provider_codex "${codex_args[@]}"
}

dx_provider_apply() {
  local preferred_source="auto" default_profile explicit_engine agent_override="" model_override=""
  dx_provider_validate_config_files || return 1
  if [[ -n "${DX_AGENT_OVERRIDE:-}" ]]; then
    agent_override=$(dx_agent_normalize "$DX_AGENT_OVERRIDE") || return 1
  elif [[ -n "${DX_AGENT:-}" ]]; then
    agent_override=$(dx_agent_normalize "$DX_AGENT") || return 1
  fi
  model_override="${DX_MODEL_OVERRIDE:-${DX_MODEL:-}}"
  dx_provider_validate_model_field "DX_MODEL override" "$model_override" || return 1

  if [[ -n "$agent_override" ]]; then
    default_profile=$(dx_provider_repo_default_profile 2>/dev/null || true)
    if [[ -n "$default_profile" ]] && dx_provider_profile_matches_agent "$default_profile" "repo" "$agent_override"; then
      DX_PROVIDER_PROFILE_RESOLVED="$default_profile"
      preferred_source="repo"
    else
      default_profile=$(__dx_provider_json_default "$DX_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
      if [[ -n "$default_profile" ]] && dx_provider_profile_matches_agent "$default_profile" "global" "$agent_override"; then
        DX_PROVIDER_PROFILE_RESOLVED="$default_profile"
        preferred_source="global"
      else
        DX_PROVIDER_PROFILE_RESOLVED=$(dx_agent_default_profile "$agent_override") || return 1
        preferred_source="builtin"
      fi
    fi
  elif [[ -n "${DX_PROVIDER_PROFILE:-}" ]]; then
    DX_PROVIDER_PROFILE_RESOLVED="$DX_PROVIDER_PROFILE"
    if dx_provider_is_builtin "$DX_PROVIDER_PROFILE_RESOLVED"; then
      preferred_source="builtin"
    elif __dx_provider_json_get "$DX_PROVIDER_GLOBAL_CONFIG" "$DX_PROVIDER_PROFILE_RESOLVED" "engine" >/dev/null 2>&1; then
      preferred_source="global"
    else
      explicit_engine=$(dx_provider_repo_profile_engine "$DX_PROVIDER_PROFILE_RESOLVED" 2>/dev/null || true)
      if [[ -n "$explicit_engine" ]]; then
        if [[ "$explicit_engine" == "anthropic-gateway" ]] && ! dx_provider_repo_gateway_allowed; then
          dx_error "Repo provider profile ${DX_PROVIDER_PROFILE_RESOLVED} uses gateway/API routing and requires DX_ALLOW_REPO_GATEWAY_PROVIDER=1."
          dx_info "Define gateway profiles in ~/.dex/providers.json, or set DX_ALLOW_REPO_GATEWAY_PROVIDER=1 for an explicit one-off repo profile opt-in."
          return 1
        fi
        preferred_source="repo"
      fi
    fi
  else
    default_profile=$(dx_provider_repo_default_profile || true)
    if [[ -n "$default_profile" ]]; then
      DX_PROVIDER_PROFILE_RESOLVED="$default_profile"
      preferred_source="repo"
    else
      default_profile=$(__dx_provider_json_default "$DX_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
      if [[ -n "$default_profile" ]]; then
        DX_PROVIDER_PROFILE_RESOLVED="$default_profile"
        preferred_source="global"
      else
        DX_PROVIDER_PROFILE_RESOLVED="claude-subscription"
        preferred_source="builtin"
      fi
    fi
  fi
  DX_PROVIDER_SOURCE=$(dx_provider_resolve_source "$DX_PROVIDER_PROFILE_RESOLVED" "$preferred_source" 2>/dev/null || true)
  if [[ -z "$DX_PROVIDER_SOURCE" ]]; then
    if [[ "$preferred_source" == "repo" ]]; then
      dx_error "Repo provider default is not built in or defined in this repo: $DX_PROVIDER_PROFILE_RESOLVED"
    elif [[ "$preferred_source" == "global" ]]; then
      dx_error "Global provider default is not built in or defined globally: $DX_PROVIDER_PROFILE_RESOLVED"
    else
      dx_error "Unknown provider profile: $DX_PROVIDER_PROFILE_RESOLVED"
    fi
    dx_info "Run 'dx provider list' to see available profiles."
    return 1
  fi
  DX_PROVIDER_ENGINE=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "engine" "$DX_PROVIDER_SOURCE" 2>/dev/null || true)
  if [[ -z "$DX_PROVIDER_ENGINE" ]]; then
    dx_error "Unknown provider profile: $DX_PROVIDER_PROFILE_RESOLVED"
    dx_info "Run 'dx provider list' to see available profiles."
    return 1
  fi
  case "$DX_PROVIDER_ENGINE" in
    claude|codex-plugin|anthropic-gateway) ;;
    *)
      dx_error "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} has unsupported engine: ${DX_PROVIDER_ENGINE}"
      dx_info "Supported engines: claude, codex-plugin, anthropic-gateway"
      return 1
      ;;
  esac
  DX_PROVIDER_AGENT=$(dx_agent_for_engine "$DX_PROVIDER_ENGINE")

  DX_PROVIDER_AUTH=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "auth" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DX_PROVIDER_BASE_URL=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "base_url" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DX_PROVIDER_AUTH_ENV=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "auth_env" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DX_PROVIDER_MODEL=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "model" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DX_PROVIDER_PLAN_MODEL=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "plan_model" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "$DX_PROVIDER_MODEL")
  # shellcheck disable=SC2034
  DX_PROVIDER_HAIKU_MODEL=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "haiku_model" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "$DX_PROVIDER_MODEL")
  DX_PROVIDER_EFFORT=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "effort" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DX_PROVIDER_PLAN_EFFORT=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "plan_effort" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "$DX_PROVIDER_EFFORT")
  DX_CODEX_MODEL=$(dx_provider_get "$DX_PROVIDER_PROFILE_RESOLVED" "codex_model" "$DX_PROVIDER_SOURCE" 2>/dev/null || echo "")
  dx_provider_validate_model_field "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} model" "$DX_PROVIDER_MODEL" || return 1
  dx_provider_validate_model_field "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} plan_model" "$DX_PROVIDER_PLAN_MODEL" || return 1
  dx_provider_validate_model_field "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} haiku_model" "$DX_PROVIDER_HAIKU_MODEL" || return 1
  dx_provider_validate_model_field "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} codex_model" "$DX_CODEX_MODEL" || return 1
  if [[ "$DX_PROVIDER_ENGINE" == "codex-plugin" && -n "$model_override" ]]; then
    DX_CODEX_MODEL="$model_override"
  fi

  if [[ "$DX_PROVIDER_ENGINE" != "codex-plugin" && -n "$model_override" ]]; then
    DX_USER_CLAUDE_MODEL="$model_override"
    DX_USER_PLAN_MODEL="$model_override"
  else
    if [[ -n "${DX_CLAUDE_MODEL:-}" && "${DX_CLAUDE_MODEL}" != "${DX_PROVIDER_LAST_CLAUDE_MODEL:-}" && "${DX_CLAUDE_MODEL}" != "${DX_PROVIDER_LAST_PROVIDER_MODEL:-}" ]]; then
      DX_USER_CLAUDE_MODEL="$DX_CLAUDE_MODEL"
    elif [[ -z "${DX_CLAUDE_MODEL:-}" || "${DX_CLAUDE_MODEL:-}" == "${DX_PROVIDER_LAST_PROVIDER_MODEL:-}" ]]; then
      DX_USER_CLAUDE_MODEL=""
    fi
    if [[ -n "${DX_PLAN_MODEL:-}" && "${DX_PLAN_MODEL}" != "${DX_PROVIDER_LAST_PLAN_MODEL:-}" && "${DX_PLAN_MODEL}" != "${DX_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" ]]; then
      DX_USER_PLAN_MODEL="$DX_PLAN_MODEL"
    elif [[ -z "${DX_PLAN_MODEL:-}" || "${DX_PLAN_MODEL:-}" == "${DX_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" ]]; then
      DX_USER_PLAN_MODEL=""
    fi
  fi
  if [[ -n "${DX_CLAUDE_EFFORT:-}" && "${DX_CLAUDE_EFFORT}" != "${DX_PROVIDER_LAST_CLAUDE_EFFORT:-}" && "${DX_CLAUDE_EFFORT}" != "${DX_PROVIDER_LAST_PROVIDER_EFFORT:-}" ]]; then
    DX_USER_CLAUDE_EFFORT="$DX_CLAUDE_EFFORT"
  elif [[ -z "${DX_CLAUDE_EFFORT:-}" || "${DX_CLAUDE_EFFORT:-}" == "${DX_PROVIDER_LAST_PROVIDER_EFFORT:-}" ]]; then
    DX_USER_CLAUDE_EFFORT=""
  fi
  if [[ -n "${DX_PLAN_EFFORT:-}" && "${DX_PLAN_EFFORT}" != "${DX_PROVIDER_LAST_PLAN_EFFORT:-}" && "${DX_PLAN_EFFORT}" != "${DX_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" ]]; then
    DX_USER_PLAN_EFFORT="$DX_PLAN_EFFORT"
  elif [[ -z "${DX_PLAN_EFFORT:-}" || "${DX_PLAN_EFFORT:-}" == "${DX_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" ]]; then
    DX_USER_PLAN_EFFORT=""
  fi

  DX_CLAUDE_MODEL="${DX_USER_CLAUDE_MODEL:-$DX_PROVIDER_MODEL}"
  # shellcheck disable=SC2034
  DX_PLAN_MODEL="${DX_USER_PLAN_MODEL:-${DX_USER_CLAUDE_MODEL:-$DX_PROVIDER_PLAN_MODEL}}"
  dx_provider_validate_model_field "DX_CLAUDE_MODEL" "$DX_CLAUDE_MODEL" || return 1
  dx_provider_validate_model_field "DX_PLAN_MODEL" "$DX_PLAN_MODEL" || return 1
  dx_provider_validate_model_field "DX_CODEX_MODEL" "$DX_CODEX_MODEL" || return 1
  DX_CLAUDE_EFFORT="${DX_USER_CLAUDE_EFFORT:-$DX_PROVIDER_EFFORT}"
  # shellcheck disable=SC2034
  DX_PLAN_EFFORT="${DX_USER_PLAN_EFFORT:-${DX_USER_CLAUDE_EFFORT:-$DX_PROVIDER_PLAN_EFFORT}}"
  dx_provider_validate_effort_field "DX_CLAUDE_EFFORT" "$DX_CLAUDE_EFFORT" || return 1
  dx_provider_validate_effort_field "DX_PLAN_EFFORT" "$DX_PLAN_EFFORT" || return 1

  DX_PROVIDER_LAST_CLAUDE_MODEL="$DX_CLAUDE_MODEL"
  DX_PROVIDER_LAST_PLAN_MODEL="$DX_PLAN_MODEL"
  DX_PROVIDER_LAST_CLAUDE_EFFORT="$DX_CLAUDE_EFFORT"
  DX_PROVIDER_LAST_PLAN_EFFORT="$DX_PLAN_EFFORT"
  DX_PROVIDER_LAST_PROVIDER_MODEL="$DX_PROVIDER_MODEL"
  DX_PROVIDER_LAST_PROVIDER_PLAN_MODEL="$DX_PROVIDER_PLAN_MODEL"
  DX_PROVIDER_LAST_PROVIDER_EFFORT="$DX_PROVIDER_EFFORT"
  DX_PROVIDER_LAST_PROVIDER_PLAN_EFFORT="$DX_PROVIDER_PLAN_EFFORT"
}

# __dx_provider_env_unset_args prints all env var names that should be stripped
# from the environment before launching claude/codex for provider isolation.
# Callers read the output to build env_args arrays.
__dx_provider_env_unset_args() {
  dx_provider_external_env_names
  dx_provider_config_auth_env_unsets
  dx_provider_claude_override_env_names
  cat <<'EOF'
DEX_FACTORY_TOKEN
DEX_FACTORY_RUN_TOKEN
DEX_RUN_TOKEN
EOF
}

dx_provider_claude() {
  [[ -n "${DX_PROVIDER_ENGINE:-}" ]] || dx_provider_apply || return 1
  if [[ -n "${DEX_SESSION_ID:-}" ]]; then
    dx_provider_write_session_state "$DEX_SESSION_ID" || return 1
  fi
  local env_args=()
  local _env_name
  while IFS= read -r _env_name; do
    [[ -n "$_env_name" ]] && env_args+=(-u "$_env_name")
  done < <(__dx_provider_env_unset_args)

  # Dex drives long autonomous Stop-hook loops — audit iterations (up to
  # DEX_LOOP_MAX_ITERATIONS), Phase 3 review-pass waits (DEX_REVIEW_PASS_TIMEOUT
  # at DEX_REVIEW_PASS_RECHECK_SECONDS granularity), and Phase 6 CI/review
  # monitoring — that intentionally block the Stop hook far more than Claude
  # Code's default cap (9) allows, which would force the turn to end mid-wait.
  # Raise the cap so Dex's own iteration counters and timeouts govern
  # termination. Still overridable from the environment.
  env_args+=(CLAUDE_CODE_STOP_HOOK_BLOCK_CAP="${CLAUDE_CODE_STOP_HOOK_BLOCK_CAP:-1000}")

  case "$DX_PROVIDER_ENGINE" in
    anthropic-gateway)
      local token=""
      if [[ -n "${DX_PROVIDER_AUTH_ENV:-}" ]]; then
        if ! dx_provider_valid_env_name "$DX_PROVIDER_AUTH_ENV"; then
          dx_error "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} has invalid auth_env: ${DX_PROVIDER_AUTH_ENV}"
          return 1
        fi
        token=$(dx_provider_env_value "$DX_PROVIDER_AUTH_ENV")
      fi
      if [[ -n "${DX_PROVIDER_AUTH_ENV:-}" && -z "$token" ]]; then
        dx_error "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} requires ${DX_PROVIDER_AUTH_ENV}, but it is not set."
        return 1
      fi
      if [[ -z "${DX_PROVIDER_BASE_URL:-}" ]]; then
        dx_error "Provider profile ${DX_PROVIDER_PROFILE_RESOLVED} is missing base_url."
        return 1
      fi
      if [[ -n "$token" ]]; then
        [[ -n "${DX_PROVIDER_AUTH_ENV:-}" ]] && env_args+=(-u "$DX_PROVIDER_AUTH_ENV")
        env_args+=(
          ANTHROPIC_BASE_URL="$DX_PROVIDER_BASE_URL"
          ANTHROPIC_AUTH_TOKEN="$token"
          ANTHROPIC_DEFAULT_OPUS_MODEL="$DX_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_SONNET_MODEL="$DX_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_HAIKU_MODEL="${DX_PROVIDER_HAIKU_MODEL:-$DX_CLAUDE_MODEL}"
          ANTHROPIC_CUSTOM_MODEL_OPTION="$DX_CLAUDE_MODEL"
          CLAUDE_CODE_SUBAGENT_MODEL="$DX_CLAUDE_MODEL"
        )
        env \
          "${env_args[@]}" \
          claude "$@"
      else
        env_args+=(
          ANTHROPIC_BASE_URL="$DX_PROVIDER_BASE_URL"
          ANTHROPIC_DEFAULT_OPUS_MODEL="$DX_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_SONNET_MODEL="$DX_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_HAIKU_MODEL="${DX_PROVIDER_HAIKU_MODEL:-$DX_CLAUDE_MODEL}"
          ANTHROPIC_CUSTOM_MODEL_OPTION="$DX_CLAUDE_MODEL"
          CLAUDE_CODE_SUBAGENT_MODEL="$DX_CLAUDE_MODEL"
        )
        env \
          "${env_args[@]}" \
          claude "$@"
      fi
      ;;
    codex-plugin)
      dx_provider_codex_ready_check || return 1
      env_args+=(
        DX_PROVIDER_PROFILE="$DX_PROVIDER_PROFILE_RESOLVED"
        DX_PROVIDER_ENGINE="$DX_PROVIDER_ENGINE"
        DX_PROVIDER_AGENT="${DX_PROVIDER_AGENT:-codex}"
        DX_CODEX_MODEL="${DX_CODEX_MODEL:-}"
        DX_AGENT_OVERRIDE="${DX_AGENT_OVERRIDE:-}"
        DX_MODEL_OVERRIDE="${DX_MODEL_OVERRIDE:-}"
      )
      local codex_prompt
      codex_prompt=$(dx_provider_codex_prompt_from_claude_args "$@") || return 1
      env \
        "${env_args[@]}" \
        bash "$DEX_DIR/bin/dxcodex.sh" exec -- "$codex_prompt"
      ;;
    claude)
      env_args+=(
        DX_PROVIDER_PROFILE="$DX_PROVIDER_PROFILE_RESOLVED"
        DX_PROVIDER_ENGINE="$DX_PROVIDER_ENGINE"
        DX_PROVIDER_AGENT="${DX_PROVIDER_AGENT:-claude}"
      )
      env \
        "${env_args[@]}" \
        claude "$@"
      ;;
  esac
}

dx_provider_codex_prompt_from_claude_args() {
  local system_prompt_file="" prompt="" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --append-system-prompt-file)
        [[ $# -ge 2 ]] || {
          dx_error "--append-system-prompt-file requires a path."
          return 1
        }
        system_prompt_file="$2"
        shift 2
        ;;
      -n|--settings|--model|--effort|--permission-mode)
        [[ $# -ge 2 ]] || {
          dx_error "${arg} requires a value."
          return 1
        }
        shift 2
        ;;
      --chrome|--dangerously-skip-permissions)
        shift
        ;;
      --)
        shift
        prompt="$*"
        break
        ;;
      -*)
        shift
        ;;
      *)
        prompt="$arg"
        shift
        ;;
    esac
  done

  if [[ -n "$system_prompt_file" ]]; then
    if [[ ! -r "$system_prompt_file" ]]; then
      dx_error "Codex lifecycle launch could not read system prompt file: $system_prompt_file"
      return 1
    fi
    {
      cat "$system_prompt_file"
      printf '\n\n--- Dex phase task ---\n\n'
      printf '%s\n' "$prompt"
    }
  else
    printf '%s\n' "$prompt"
  fi
}

dx_provider_codex() {
  if [[ "${DX_PROVIDER_CODEX_WRAPPER:-0}" == "1" ]]; then
    dx_provider_codex_wrapper_args "$@" || return 2
  elif ! dx_provider_codex_diagnostic_args "$@"; then
    dx_error "Direct dx_provider_codex delegation is blocked."
    dx_info "Use bin/dxcodex.sh so Dex can enforce Codex config, sandbox, and provider cleanup."
    return 2
  fi

  local env_args=()
  local _env_name
  while IFS= read -r _env_name; do
    [[ -n "$_env_name" ]] && env_args+=(-u "$_env_name")
  done < <(__dx_provider_env_unset_args)
  env_args+=(-u DX_PROVIDER_CODEX_WRAPPER)
  env "${env_args[@]}" codex "$@"
}

dx_provider_codex_diagnostic_args() {
  local subcmd="${1:-}"
  case "$subcmd" in
    help|--help|-h|-V|--version|completion|debug|features|mcp|mcp-server|plugin)
      return 0
      ;;
    login)
      shift || true
      case "${1:-}" in
        status|help|--help|-h)
          return 0
          ;;
      esac
      return 1
      ;;
    exec|e)
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          help|--help|-h)
            return 0
            ;;
          review)
            shift
            continue
            ;;
          --)
            return 1
            ;;
          -*)
            shift
            continue
            ;;
          *)
            return 1
            ;;
        esac
      done
      return 1
      ;;
    review)
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          help|--help|-h)
            return 0
            ;;
          --)
            return 1
            ;;
          -*)
            shift
            continue
            ;;
          *)
            return 1
            ;;
        esac
      done
      return 1
      ;;
  esac
  return 1
}

dx_provider_codex_wrapper_args() {
  local subcmd="${1:-}"
  [[ "$subcmd" == "exec" ]] || {
    dx_error "Dex Codex wrapper may only delegate through 'codex exec'."
    return 1
  }

  local saw_ignore_user_config=0
  local saw_dangerous_bypass=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ignore-user-config)
        saw_ignore_user_config=1
        ;;
      --dangerously-bypass-approvals-and-sandbox|--yolo)
        saw_dangerous_bypass=1
        ;;
    esac
    shift
  done

  if [[ $saw_ignore_user_config -ne 1 || $saw_dangerous_bypass -ne 1 ]]; then
    dx_error "Dex Codex delegation requires --ignore-user-config and --dangerously-bypass-approvals-and-sandbox."
    return 1
  fi
}

dx_provider_claude_diagnostic() {
  [[ -n "${DX_PROVIDER_ENGINE:-}" ]] || dx_provider_apply || return 1
  local env_args=()
  local _env_name
  while IFS= read -r _env_name; do
    [[ -n "$_env_name" ]] && env_args+=(-u "$_env_name")
  done < <(__dx_provider_env_unset_args)
  env_args+=(
    DX_PROVIDER_PROFILE="$DX_PROVIDER_PROFILE_RESOLVED"
    DX_PROVIDER_ENGINE="$DX_PROVIDER_ENGINE"
  )
  env "${env_args[@]}" claude "$@"
}

dx_provider_claude_required_flags_check() {
  local claude_help
  claude_help=$(claude --help 2>&1 || true)
  local failed=0
  if ! printf '%s\n' "$claude_help" | grep -q -- "--dangerously-skip-permissions"; then
    dx_error "Claude Code CLI does not support --dangerously-skip-permissions; upgrade Claude before using Dex."
    failed=1
  fi
  if ! printf '%s\n' "$claude_help" | grep -q -- "--permission-mode"; then
    dx_error "Claude Code CLI does not support --permission-mode; upgrade Claude before using Dex."
    failed=1
  fi
  return $failed
}

dx_provider_codex_required_flags_check() {
  local codex_exec_help codex_review_help
  codex_exec_help=$(dx_provider_codex exec --help 2>&1 || true)
  codex_review_help=$(dx_provider_codex exec review --help 2>&1 || true)
  local failed=0
  if ! printf '%s\n' "$codex_exec_help" | grep -q -- "--ignore-user-config" || ! printf '%s\n' "$codex_review_help" | grep -q -- "--ignore-user-config"; then
    dx_error "Codex CLI does not support --ignore-user-config; upgrade Codex before using codex-subscription."
    failed=1
  fi
  if ! printf '%s\n' "$codex_exec_help" | grep -q -- "--dangerously-bypass-approvals-and-sandbox" || ! printf '%s\n' "$codex_review_help" | grep -q -- "--dangerously-bypass-approvals-and-sandbox"; then
    dx_error "Codex CLI does not support --dangerously-bypass-approvals-and-sandbox; upgrade Codex before using codex-subscription."
    failed=1
  fi
  return $failed
}

dx_provider_codex_ignore_user_config_check() {
  dx_provider_codex_required_flags_check
}

dx_provider_codex_ready_check() {
  if ! command -v codex >/dev/null 2>&1; then
    dx_error "Codex CLI not found; codex-subscription cannot delegate work before launching Claude."
    dx_info "Install Codex, sign in with ChatGPT, then run 'dx provider doctor'."
    return 1
  fi
  dx_provider_codex_required_flags_check || return 1

  local login_status
  login_status=$(dx_provider_codex login status 2>&1 || true)
  if printf '%s\n' "$login_status" | grep -qi "ChatGPT"; then
    return 0
  fi
  if printf '%s\n' "$login_status" | grep -q "Logged in"; then
    dx_error "Codex CLI is logged in, but ChatGPT subscription auth could not be confirmed."
  else
    dx_error "Codex CLI is not logged in with ChatGPT."
  fi
  dx_info "Run 'codex login' or '/codex:setup', then run 'dx provider doctor'."
  return 1
}

dx_provider_prompt() {
  [[ -n "${DX_PROVIDER_ENGINE:-}" ]] || dx_provider_apply || return 1

  if [[ "$DX_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    local codex_wrapper="${DEX_DIR}/bin/dxcodex.sh"
    cat <<EOF

## Provider Profile: Codex Subscription Delegation

Dex is running in the "${DX_PROVIDER_PROFILE_RESOLVED}" provider profile.
Claude Code remains the outer lifecycle harness, but substantive coding and
review work should be delegated to Codex using the local Codex CLI through the
Dex wrapper. The OpenAI Codex Claude Code plugin is optional for setup/slash
commands, but not for subscription-safe delegation.

Subscription-safety rules:
- Do NOT set or use OpenAI/Anthropic API keys, gateway URLs, or provider routing env vars.
- Prefer the signed-in Codex CLI subscription session.
- Use the Dex Codex wrapper shown below. Do NOT run raw "codex exec" or
  "codex exec review"; also do NOT run raw aliases/forms like "codex e",
  "codex review", bare "codex <prompt>", direct "dx_provider_codex"
  delegation, or package-runner forms like "npx codex". The wrapper enforces
  "--ignore-user-config", "--dangerously-bypass-approvals-and-sandbox",
  sanitized environment variables, and any explicit Codex model override.
- If Codex is missing or not logged in, stop and report that "dx provider doctor"
  or "/codex:setup" must be run.

Delegation guidance:
- For implementation, run Codex via Bash with: bash "${codex_wrapper}" exec
  and pass
  the current phase task as the prompt. If the prompt can begin with "-", use
  bash "${codex_wrapper}" exec -- "<prompt>".
- For review of current working-tree changes, run Codex via Bash with
  bash "${codex_wrapper}" review and pass the current review instructions as the prompt.
- For branch-diff reviews, pass "--base <branch>" to the review wrapper.
- Do NOT use Codex plugin slash commands for subscription-safe delegation; they
  do not go through the Dex wrapper.
- After Codex returns, inspect the resulting changes yourself and continue the
  Dex phase protocol, including skills, audits, verification, commits, and PR flow.
EOF
  elif [[ "$DX_PROVIDER_ENGINE" == "anthropic-gateway" ]]; then
    cat <<EOF

## Provider Profile: Gateway API

Dex is running through the "${DX_PROVIDER_PROFILE_RESOLVED}" gateway profile.
This mode is API/provider billed unless the gateway operator provides a separate
subscription-safe billing arrangement.
EOF
  fi
}

dx_provider_list() {
  dx_provider_validate_config_files || return 1
  printf '%s\n' "Agents:"
  printf '  %s\n' "claude                  Direct Claude Code lifecycle agent"
  printf '  %s\n' "codex                   Codex CLI delegation with Claude Code lifecycle harness"
  printf '\n'
  printf '%s\n' "Built-in profiles:"
  printf '  %s\n' "claude-subscription     Claude Code with Claude subscription OAuth"
  printf '  %s\n' "codex-subscription      Claude Code harness with Codex CLI subscription delegation"

  local repo_config
  repo_config=$(dx_provider_repo_config 2>/dev/null || true)
  for file in "$repo_config" "$DX_PROVIDER_GLOBAL_CONFIG"; do
    [[ -n "$file" && -f "$file" ]] || continue
    printf '\n%s\n' "Profiles in $file:"
    python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for name in sorted(data.get("profiles", {})):
    print(f"  {name}")
' "$file" 2>/dev/null || dx_warn "Could not parse $file"
  done
}

dx_provider_current() {
  dx_provider_apply || return 1
  dx_info "Agent:   $(dx_agent_label "$DX_PROVIDER_AGENT")"
  dx_info "Profile: ${DX_PROVIDER_PROFILE_RESOLVED}"
  dx_info "Engine:  ${DX_PROVIDER_ENGINE}"
  dx_info "Auth:    ${DX_PROVIDER_AUTH:-unknown}"
  if [[ "$DX_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    dx_info "Harness: ${DX_CLAUDE_MODEL:-session default} (${DX_CLAUDE_EFFORT:-default effort})"
    dx_info "Codex:   ${DX_CODEX_MODEL:-session default}"
  else
    dx_info "Claude:  ${DX_CLAUDE_MODEL:-session default} (${DX_CLAUDE_EFFORT:-default effort})"
  fi
  if [[ "$DX_PROVIDER_ENGINE" == "anthropic-gateway" ]]; then
    dx_info "Gateway: ${DX_PROVIDER_BASE_URL:-not configured}"
  fi
}

dx_provider_write_default() {
  local profile="$1" scope="$2" file
  if [[ "$scope" == "repo" ]]; then
    file=$(dx_provider_repo_config) || return 1
  else
    file="$DX_PROVIDER_GLOBAL_CONFIG"
  fi
  mkdir -p "$(dirname "$file")"
  python3 -c '
import json, os, sys, tempfile
path, profile = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
data.setdefault("profiles", {})
data["default"] = profile
directory = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(prefix=".providers.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
' "$file" "$profile" || return 1
  dx_done "Set ${scope} provider profile to ${profile}"
}

dx_provider_subscription_safe_check() {
  local problems=0
  local provider_external_env_name provider_external_env_value
  while IFS= read -r provider_external_env_name; do
    [[ -n "$provider_external_env_name" ]] || continue
    provider_external_env_value=$(dx_provider_env_value "$provider_external_env_name")
    if [[ -n "$provider_external_env_value" ]]; then
      dx_error "${provider_external_env_name} is set; it can route Claude/Codex through API, gateway, or provider-billed auth instead of subscription auth."
      problems=1
    fi
  done < <(dx_provider_external_env_names)
  local provider_auth_env_name
  while IFS= read -r provider_auth_env_name; do
    if [[ -n "$provider_auth_env_name" ]]; then
      local provider_auth_env_value
      provider_auth_env_value=$(dx_provider_env_value "$provider_auth_env_name")
      if [[ -n "$provider_auth_env_value" ]]; then
        dx_error "${provider_auth_env_name} is set; it matches a configured provider auth_env and may expose gateway/API credentials."
        problems=1
      fi
    fi
  done < <(dx_provider_config_auth_env_unsets)
  if ! dx_provider_claude_override_env_check; then
    problems=1
  fi
  if [[ $problems -ne 0 ]]; then
    dx_info "Unset API/gateway and model override env vars. DX_ALLOW_API_BILLED_AUTH=1 only tolerates API/gateway billing vars."
  fi
  return $problems
}

dx_provider_claude_override_env_check() {
  local problems=0
  local override_env_name override_env_value
  while IFS= read -r override_env_name; do
    [[ -n "$override_env_name" ]] || continue
    override_env_value=$(dx_provider_env_value "$override_env_name")
    if [[ -n "$override_env_value" ]]; then
      dx_error "${override_env_name} is set; it can override provider profile model or effort routing."
      problems=1
    fi
  done < <(dx_provider_claude_override_env_names)
  return $problems
}

dx_provider_valid_env_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

dx_provider_valid_model_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]
}

dx_provider_validate_model_field() {
  local label="$1" value="$2"
  if [[ -n "$value" ]] && ! dx_provider_valid_model_id "$value"; then
    dx_error "${label} has invalid model id: ${value}"
    dx_info "Model ids may contain only letters, numbers, dot, underscore, dash, colon, slash, and plus, and must start with a letter or number."
    return 1
  fi
}

dx_provider_valid_effort() {
  case "$1" in
    low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

dx_provider_validate_effort_field() {
  local label="$1" value="$2"
  if [[ -n "$value" ]] && ! dx_provider_valid_effort "$value"; then
    dx_error "${label} has invalid effort: ${value}"
    dx_info "Supported efforts: low, medium, high, xhigh, max"
    return 1
  fi
}

dx_provider_doctor() {
  dx_provider_apply || return 1
  dx_provider_current
  printf '\n'

  local failed=0
  if command -v claude >/dev/null 2>&1; then
    dx_ok "Claude Code CLI found"
    if dx_provider_claude_required_flags_check; then
      dx_ok "Claude Code CLI supports required Dex permission flags"
    else
      failed=1
    fi
  else
    dx_error "Claude Code CLI not found"
    failed=1
  fi

  case "$DX_PROVIDER_ENGINE" in
    claude|codex-plugin)
      if [[ "${DX_ALLOW_API_BILLED_AUTH:-0}" == "1" ]]; then
        dx_warn "API/gateway billing env vars allowed by DX_ALLOW_API_BILLED_AUTH=1"
        if ! dx_provider_claude_override_env_check; then
          failed=1
        fi
      elif dx_provider_subscription_safe_check; then
        dx_ok "Subscription-safe Claude environment"
      else
        failed=1
      fi
      ;;
    anthropic-gateway)
      if ! dx_provider_claude_override_env_check; then
        failed=1
      fi
      if [[ -z "$DX_PROVIDER_BASE_URL" ]]; then
        dx_error "Gateway profile is missing base_url"
        failed=1
      else
        dx_ok "Gateway URL configured"
      fi
      if [[ -n "$DX_PROVIDER_AUTH_ENV" ]]; then
        if ! dx_provider_valid_env_name "$DX_PROVIDER_AUTH_ENV"; then
          dx_error "Gateway auth_env is not a valid environment variable name: $DX_PROVIDER_AUTH_ENV"
          return 1
        fi
        local token
        token=$(dx_provider_env_value "$DX_PROVIDER_AUTH_ENV")
        if [[ -n "$token" ]]; then
          dx_ok "Gateway auth env ${DX_PROVIDER_AUTH_ENV} is set"
        else
          dx_error "Gateway auth env ${DX_PROVIDER_AUTH_ENV} is not set"
          failed=1
        fi
      else
        dx_warn "Gateway profile has no auth_env; only use this if the gateway does not require client auth"
      fi
      ;;
  esac

  if [[ "$DX_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    local codex_cli_found=0
    if command -v codex >/dev/null 2>&1; then
      codex_cli_found=1
      dx_ok "Codex CLI found"
      if dx_provider_codex_required_flags_check; then
        dx_ok "Codex CLI supports required Dex exec flags"
      else
        failed=1
      fi
      local login_status
      login_status=$(dx_provider_codex login status 2>&1 || true)
      if printf '%s\n' "$login_status" | grep -qi "ChatGPT"; then
        dx_ok "Codex is logged in with ChatGPT"
      elif printf '%s\n' "$login_status" | grep -q "Logged in"; then
        dx_error "Codex is logged in, but doctor could not confirm ChatGPT subscription auth"
        failed=1
      else
        dx_error "Codex is not logged in with ChatGPT"
        failed=1
      fi
    else
      dx_error "Codex CLI not found"
      failed=1
    fi
    local codex_skill_count=0
    local codex_skill_expected=0
    if command -v dx_count_codex_dex_skills >/dev/null 2>&1; then
      codex_skill_count=$(dx_count_codex_dex_skills)
      codex_skill_expected=$(dx_count_dex_skills)
    fi
    if command -v dx_codex_dex_skills_complete >/dev/null 2>&1 && dx_codex_dex_skills_complete; then
      dx_ok "Dex Codex skills linked (${codex_skill_count}/${codex_skill_expected})"
    elif [[ "$codex_skill_count" -gt 0 ]]; then
      dx_warn "Dex Codex skills are partially linked (${codex_skill_count}/${codex_skill_expected}); run 'dx install' to reinstall skill links"
    else
      dx_warn "Dex Codex skills are not linked; run 'dx install' to refresh skill links"
    fi

    local plugin_status
    plugin_status=$(dx_provider_claude_diagnostic plugin list 2>/dev/null || true)
    if printf '%s\n' "$plugin_status" | grep -A4 "codex@openai-codex" | grep -qi "enabled"; then
      dx_ok "OpenAI Codex Claude Code plugin installed"
    else
      if [[ $codex_cli_found -eq 1 ]]; then
        dx_warn "OpenAI Codex Claude Code plugin not installed; Codex CLI delegation is still available"
        dx_info "Install plugin slash commands with: dx tools bootstrap"
      else
        dx_error "OpenAI Codex Claude Code plugin not installed"
        dx_info "Install Codex CLI, then run: dx tools bootstrap"
        failed=1
      fi
    fi
    dx_info "Run '/codex:setup' inside Claude Code when Claude usage is available."
  fi

  return $failed
}

dx_provider_command() {
  local subcmd="${1:-current}"
  shift 2>/dev/null || true

  case "$subcmd" in
    list)
      dx_provider_list
      ;;
    current)
      dx_provider_current
      ;;
    doctor)
      dx_provider_doctor
      ;;
    use)
      dx_provider_validate_config_files || return 1
      local scope="global"
      if [[ "${1:-}" == "--repo" ]]; then
        scope="repo"
        shift
      fi
      local profile="${1:-}"
      if [[ -z "$profile" ]]; then
        dx_error "Usage: dx provider use [--repo] <profile>"
        return 1
      fi
      if [[ "$scope" == "global" ]]; then
        if ! __dx_provider_builtin_get "$profile" "engine" >/dev/null 2>&1 && ! __dx_provider_json_get "$DX_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
          dx_error "Global provider profile is not defined globally: $profile"
          dx_info "Use 'dx provider use --repo $profile' for repo-local profiles, or define the profile in ~/.dex/providers.json."
          return 1
        fi
      else
        local repo_config
        repo_config=$(dx_provider_repo_config) || return 1
        if ! __dx_provider_builtin_get "$profile" "engine" >/dev/null 2>&1 && ! __dx_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
          dx_error "Repo provider profile is not built in or defined in this repo: $profile"
          dx_info "Define custom repo profiles in .dex/providers.json, or use a built-in profile."
          return 1
        fi
        local repo_engine
        repo_engine=$(__dx_provider_json_get "$repo_config" "$profile" "engine" 2>/dev/null || true)
        if [[ "$repo_engine" == "anthropic-gateway" ]] && ! dx_provider_repo_gateway_allowed; then
          dx_error "Repo gateway/API profiles cannot be saved as an auto-selected default without DX_ALLOW_REPO_GATEWAY_PROVIDER=1."
          dx_info "Define gateway profiles in ~/.dex/providers.json, or use DX_PROVIDER_PROFILE=$profile DX_ALLOW_REPO_GATEWAY_PROVIDER=1 for an explicit one-off repo opt-in."
          return 1
        fi
      fi
      dx_provider_write_default "$profile" "$scope"
      ;;
    help|--help|-h)
      printf '%s\n' "Usage: dx provider <command>"
      printf '%s\n' ""
      printf '%s\n' "Global run overrides:"
      printf '%s\n' "  dx --agent <claude|codex> <command-or-task>"
      printf '%s\n' "  dx --model <model> <command-or-task>"
      printf '%s\n' ""
      printf '%s\n' "Commands:"
      printf '%s\n' "  list                    Show built-in and configured profiles"
      printf '%s\n' "  current                 Show the resolved active profile"
      printf '%s\n' "  use <profile>           Set the global default profile"
      printf '%s\n' "  use --repo <profile>    Set the current repo default profile"
      printf '%s\n' "  doctor                  Check subscription-safety and local tooling"
      ;;
    *)
      dx_error "Unknown provider command: $subcmd"
      dx_info "Run 'dx provider help' for usage."
      return 1
      ;;
  esac
}
