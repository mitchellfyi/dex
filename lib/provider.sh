# shellcheck shell=bash
# Doyaken provider profile helpers.
#
# Profiles select how Doyaken should spend model work while keeping Claude Code
# as the outer lifecycle harness. Subscription-safe profiles intentionally avoid
# API-key credentials that would bypass subscription billing.

DK_PROVIDER_GLOBAL_CONFIG="$HOME/.doyaken/providers.json"

dk_provider_repo_config() {
  local root
  root=$(dk_repo_root 2>/dev/null) || return 1
  printf '%s\n' "$root/.doyaken/providers.json"
}

__dk_provider_json_default() {
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

__dk_provider_json_get() {
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

dk_provider_validate_config_file() {
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
    dk_error "Provider config is invalid: $file"
    dk_info "Use string values, unique non-built-in profile names, valid engines, and a default defined in that file or built in."
    return 1
  fi
}

dk_provider_validate_config_files() {
  local repo_config
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)
  if [[ -n "$repo_config" ]]; then
    dk_provider_validate_config_file "$repo_config" "repo" || return 1
  fi
  dk_provider_validate_config_file "$DK_PROVIDER_GLOBAL_CONFIG" "global" || return 1
}

__dk_provider_builtin_get() {
  local profile="$1" key="$2"
  case "$profile:$key" in
    claude-subscription:engine) printf '%s\n' "claude" ;;
    claude-subscription:auth) printf '%s\n' "subscription" ;;
    claude-subscription:model) printf '%s\n' "opus" ;;
    claude-subscription:plan_model) printf '%s\n' "opus" ;;
    claude-subscription:effort) printf '%s\n' "max" ;;
    claude-subscription:plan_effort) printf '%s\n' "max" ;;
    codex-subscription:engine) printf '%s\n' "codex-plugin" ;;
    codex-subscription:auth) printf '%s\n' "chatgpt-subscription" ;;
    codex-subscription:model) printf '%s\n' "opus" ;;
    codex-subscription:plan_model) printf '%s\n' "opus" ;;
    codex-subscription:effort) printf '%s\n' "max" ;;
    codex-subscription:plan_effort) printf '%s\n' "max" ;;
    *) return 1 ;;
  esac
}

dk_provider_is_builtin() {
  __dk_provider_builtin_get "$1" "engine" >/dev/null 2>&1
}

dk_provider_repo_gateway_allowed() {
  [[ "${DK_ALLOW_REPO_GATEWAY_PROVIDER:-0}" == "1" ]]
}

dk_provider_repo_profile_engine() {
  local profile="$1" repo_config
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)
  [[ -n "$repo_config" ]] || return 1
  __dk_provider_json_get "$repo_config" "$profile" "engine"
}

dk_provider_repo_default_profile() {
  local repo_config default_profile engine
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)
  [[ -n "$repo_config" ]] || return 1
  default_profile=$(__dk_provider_json_default "$repo_config" 2>/dev/null || true)
  [[ -n "$default_profile" ]] || return 1
  if dk_provider_is_builtin "$default_profile"; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  engine=$(__dk_provider_json_get "$repo_config" "$default_profile" "engine" 2>/dev/null || true)
  if [[ "$engine" == "anthropic-gateway" ]] && ! dk_provider_repo_gateway_allowed; then
    dk_warn "Ignoring repo provider default ${default_profile}: repo gateway/API profiles require DK_ALLOW_REPO_GATEWAY_PROVIDER=1 or a global user profile."
    return 1
  fi
  printf '%s\n' "$default_profile"
}

dk_provider_default_profile() {
  local default_profile
  dk_provider_validate_config_files || return 1
  default_profile=$(dk_provider_repo_default_profile 2>/dev/null || true)
  if [[ -n "$default_profile" ]]; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  default_profile=$(__dk_provider_json_default "$DK_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
  if [[ -n "$default_profile" ]]; then
    printf '%s\n' "$default_profile"
    return 0
  fi
  printf '%s\n' "claude-subscription"
}

dk_provider_resolve_source() {
  local profile="$1" preferred="${2:-auto}" repo_config
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)

  case "$preferred" in
    repo)
      if dk_provider_is_builtin "$profile"; then
        printf '%s\n' "builtin:"
        return 0
      fi
      if [[ -n "$repo_config" ]] && __dk_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
        printf '%s\n' "repo:$repo_config"
        return 0
      fi
      return 1
      ;;
    global)
      if dk_provider_is_builtin "$profile"; then
        printf '%s\n' "builtin:"
        return 0
      fi
      if __dk_provider_json_get "$DK_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
        printf '%s\n' "global:$DK_PROVIDER_GLOBAL_CONFIG"
        return 0
      fi
      return 1
      ;;
  esac

  if dk_provider_is_builtin "$profile"; then
    printf '%s\n' "builtin:"
  elif [[ -n "$repo_config" ]] && __dk_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
    printf '%s\n' "repo:$repo_config"
  elif __dk_provider_json_get "$DK_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
    printf '%s\n' "global:$DK_PROVIDER_GLOBAL_CONFIG"
  else
    return 1
  fi
}

dk_provider_get() {
  local profile="$1" key="$2" source="${3:-}" source_kind source_file
  if [[ -z "$source" ]]; then
    source=$(dk_provider_resolve_source "$profile") || return 1
  fi
  source_kind="${source%%:*}"
  source_file="${source#*:}"
  case "$source_kind" in
    repo|global) __dk_provider_json_get "$source_file" "$profile" "$key" ;;
    builtin) __dk_provider_builtin_get "$profile" "$key" ;;
    *) return 1 ;;
  esac
}

dk_provider_config_auth_env_unsets() {
  local repo_config
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)
  python3 - "$repo_config" "$DK_PROVIDER_GLOBAL_CONFIG" <<'PY'
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

dk_provider_external_env_names() {
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

dk_provider_env_value() {
  command printenv "$1" 2>/dev/null || true
}

dk_provider_claude_override_env_names() {
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

__dk_provider_write_state_file() {
  local state_file="$1" session_id="$2" tmp_file
  tmp_file="${state_file}.$$"
  if ! {
    printf 'engine=%s\n' "$DK_PROVIDER_ENGINE"
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

dk_provider_write_session_state() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0
  [[ -n "${DK_PROVIDER_ENGINE:-}" ]] || return 0

  mkdir -p "$DK_LOOP_DIR" || return 1
  __dk_provider_write_state_file "$(dk_provider_state_file "$session_id")" "$session_id" || return 1

  local alias_id
  alias_id=$(dk_session_id 2>/dev/null || true)
  if [[ -n "$alias_id" && "$alias_id" != "$session_id" ]]; then
    __dk_provider_write_state_file "$(dk_provider_state_file "$alias_id")" "$session_id" || return 1
  fi
}

__dk_provider_state_file_belongs_to_session() {
  local state_file="$1" session_id="$2" line state_session=""
  [[ -f "$state_file" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      session=*) state_session="${line#session=}" ;;
    esac
  done < "$state_file"
  [[ "$state_session" == "$session_id" ]]
}

dk_provider_cleanup_session_state() {
  local session_id="$1" alias_id alias_file
  [[ -n "$session_id" ]] || return 0
  rm -f "$(dk_provider_state_file "$session_id")" 2>/dev/null

  alias_id=$(dk_session_id 2>/dev/null || true)
  if [[ -n "$alias_id" && "$alias_id" != "$session_id" ]]; then
    alias_file=$(dk_provider_state_file "$alias_id")
    if __dk_provider_state_file_belongs_to_session "$alias_file" "$session_id"; then
      rm -f "$alias_file" 2>/dev/null
    fi
  fi
}

dk_provider_apply() {
  local preferred_source="auto" default_profile explicit_engine
  dk_provider_validate_config_files || return 1
  if [[ -n "${DK_PROVIDER_PROFILE:-}" ]]; then
    DK_PROVIDER_PROFILE_RESOLVED="$DK_PROVIDER_PROFILE"
    if dk_provider_is_builtin "$DK_PROVIDER_PROFILE_RESOLVED"; then
      preferred_source="builtin"
    elif __dk_provider_json_get "$DK_PROVIDER_GLOBAL_CONFIG" "$DK_PROVIDER_PROFILE_RESOLVED" "engine" >/dev/null 2>&1; then
      preferred_source="global"
    else
      explicit_engine=$(dk_provider_repo_profile_engine "$DK_PROVIDER_PROFILE_RESOLVED" 2>/dev/null || true)
      if [[ -n "$explicit_engine" ]]; then
        if [[ "$explicit_engine" == "anthropic-gateway" ]] && ! dk_provider_repo_gateway_allowed; then
          dk_error "Repo provider profile ${DK_PROVIDER_PROFILE_RESOLVED} uses gateway/API routing and requires DK_ALLOW_REPO_GATEWAY_PROVIDER=1."
          dk_info "Define gateway profiles in ~/.doyaken/providers.json, or set DK_ALLOW_REPO_GATEWAY_PROVIDER=1 for an explicit one-off repo profile opt-in."
          return 1
        fi
        preferred_source="repo"
      fi
    fi
  else
    default_profile=$(dk_provider_repo_default_profile || true)
    if [[ -n "$default_profile" ]]; then
      DK_PROVIDER_PROFILE_RESOLVED="$default_profile"
      preferred_source="repo"
    else
      default_profile=$(__dk_provider_json_default "$DK_PROVIDER_GLOBAL_CONFIG" 2>/dev/null || true)
      if [[ -n "$default_profile" ]]; then
        DK_PROVIDER_PROFILE_RESOLVED="$default_profile"
        preferred_source="global"
      else
        DK_PROVIDER_PROFILE_RESOLVED="claude-subscription"
        preferred_source="builtin"
      fi
    fi
  fi
  DK_PROVIDER_SOURCE=$(dk_provider_resolve_source "$DK_PROVIDER_PROFILE_RESOLVED" "$preferred_source" 2>/dev/null || true)
  if [[ -z "$DK_PROVIDER_SOURCE" ]]; then
    if [[ "$preferred_source" == "repo" ]]; then
      dk_error "Repo provider default is not built in or defined in this repo: $DK_PROVIDER_PROFILE_RESOLVED"
    elif [[ "$preferred_source" == "global" ]]; then
      dk_error "Global provider default is not built in or defined globally: $DK_PROVIDER_PROFILE_RESOLVED"
    else
      dk_error "Unknown provider profile: $DK_PROVIDER_PROFILE_RESOLVED"
    fi
    dk_info "Run 'dk provider list' to see available profiles."
    return 1
  fi
  DK_PROVIDER_ENGINE=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "engine" "$DK_PROVIDER_SOURCE" 2>/dev/null || true)
  if [[ -z "$DK_PROVIDER_ENGINE" ]]; then
    dk_error "Unknown provider profile: $DK_PROVIDER_PROFILE_RESOLVED"
    dk_info "Run 'dk provider list' to see available profiles."
    return 1
  fi
  case "$DK_PROVIDER_ENGINE" in
    claude|codex-plugin|anthropic-gateway) ;;
    *)
      dk_error "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} has unsupported engine: ${DK_PROVIDER_ENGINE}"
      dk_info "Supported engines: claude, codex-plugin, anthropic-gateway"
      return 1
      ;;
  esac

  DK_PROVIDER_AUTH=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "auth" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DK_PROVIDER_BASE_URL=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "base_url" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DK_PROVIDER_AUTH_ENV=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "auth_env" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "")
  DK_PROVIDER_MODEL=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "model" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "opus")
  DK_PROVIDER_PLAN_MODEL=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "plan_model" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "$DK_PROVIDER_MODEL")
  # shellcheck disable=SC2034
  DK_PROVIDER_HAIKU_MODEL=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "haiku_model" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "$DK_PROVIDER_MODEL")
  DK_PROVIDER_EFFORT=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "effort" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "max")
  DK_PROVIDER_PLAN_EFFORT=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "plan_effort" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "$DK_PROVIDER_EFFORT")
  DK_CODEX_MODEL=$(dk_provider_get "$DK_PROVIDER_PROFILE_RESOLVED" "codex_model" "$DK_PROVIDER_SOURCE" 2>/dev/null || echo "")
  dk_provider_validate_model_field "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} model" "$DK_PROVIDER_MODEL" || return 1
  dk_provider_validate_model_field "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} plan_model" "$DK_PROVIDER_PLAN_MODEL" || return 1
  dk_provider_validate_model_field "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} haiku_model" "$DK_PROVIDER_HAIKU_MODEL" || return 1
  dk_provider_validate_model_field "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} codex_model" "$DK_CODEX_MODEL" || return 1

  if [[ -n "${DK_CLAUDE_MODEL:-}" && "${DK_CLAUDE_MODEL}" != "${DK_PROVIDER_LAST_CLAUDE_MODEL:-}" && "${DK_CLAUDE_MODEL}" != "${DK_PROVIDER_LAST_PROVIDER_MODEL:-}" ]]; then
    DK_USER_CLAUDE_MODEL="$DK_CLAUDE_MODEL"
  elif [[ -z "${DK_CLAUDE_MODEL:-}" || "${DK_CLAUDE_MODEL:-}" == "${DK_PROVIDER_LAST_PROVIDER_MODEL:-}" ]]; then
    DK_USER_CLAUDE_MODEL=""
  fi
  if [[ -n "${DK_PLAN_MODEL:-}" && "${DK_PLAN_MODEL}" != "${DK_PROVIDER_LAST_PLAN_MODEL:-}" && "${DK_PLAN_MODEL}" != "${DK_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" ]]; then
    DK_USER_PLAN_MODEL="$DK_PLAN_MODEL"
  elif [[ -z "${DK_PLAN_MODEL:-}" || "${DK_PLAN_MODEL:-}" == "${DK_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" ]]; then
    DK_USER_PLAN_MODEL=""
  fi
  if [[ -n "${DK_CLAUDE_EFFORT:-}" && "${DK_CLAUDE_EFFORT}" != "${DK_PROVIDER_LAST_CLAUDE_EFFORT:-}" && "${DK_CLAUDE_EFFORT}" != "${DK_PROVIDER_LAST_PROVIDER_EFFORT:-}" ]]; then
    DK_USER_CLAUDE_EFFORT="$DK_CLAUDE_EFFORT"
  elif [[ -z "${DK_CLAUDE_EFFORT:-}" || "${DK_CLAUDE_EFFORT:-}" == "${DK_PROVIDER_LAST_PROVIDER_EFFORT:-}" ]]; then
    DK_USER_CLAUDE_EFFORT=""
  fi
  if [[ -n "${DK_PLAN_EFFORT:-}" && "${DK_PLAN_EFFORT}" != "${DK_PROVIDER_LAST_PLAN_EFFORT:-}" && "${DK_PLAN_EFFORT}" != "${DK_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" ]]; then
    DK_USER_PLAN_EFFORT="$DK_PLAN_EFFORT"
  elif [[ -z "${DK_PLAN_EFFORT:-}" || "${DK_PLAN_EFFORT:-}" == "${DK_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" ]]; then
    DK_USER_PLAN_EFFORT=""
  fi

  DK_CLAUDE_MODEL="${DK_USER_CLAUDE_MODEL:-$DK_PROVIDER_MODEL}"
  # shellcheck disable=SC2034
  DK_PLAN_MODEL="${DK_USER_PLAN_MODEL:-${DK_USER_CLAUDE_MODEL:-$DK_PROVIDER_PLAN_MODEL}}"
  dk_provider_validate_model_field "DK_CLAUDE_MODEL" "$DK_CLAUDE_MODEL" || return 1
  dk_provider_validate_model_field "DK_PLAN_MODEL" "$DK_PLAN_MODEL" || return 1
  DK_CLAUDE_EFFORT="${DK_USER_CLAUDE_EFFORT:-$DK_PROVIDER_EFFORT}"
  # shellcheck disable=SC2034
  DK_PLAN_EFFORT="${DK_USER_PLAN_EFFORT:-${DK_USER_CLAUDE_EFFORT:-$DK_PROVIDER_PLAN_EFFORT}}"
  dk_provider_validate_effort_field "DK_CLAUDE_EFFORT" "$DK_CLAUDE_EFFORT" || return 1
  dk_provider_validate_effort_field "DK_PLAN_EFFORT" "$DK_PLAN_EFFORT" || return 1

  DK_PROVIDER_LAST_CLAUDE_MODEL="$DK_CLAUDE_MODEL"
  DK_PROVIDER_LAST_PLAN_MODEL="$DK_PLAN_MODEL"
  DK_PROVIDER_LAST_CLAUDE_EFFORT="$DK_CLAUDE_EFFORT"
  DK_PROVIDER_LAST_PLAN_EFFORT="$DK_PLAN_EFFORT"
  DK_PROVIDER_LAST_PROVIDER_MODEL="$DK_PROVIDER_MODEL"
  DK_PROVIDER_LAST_PROVIDER_PLAN_MODEL="$DK_PROVIDER_PLAN_MODEL"
  DK_PROVIDER_LAST_PROVIDER_EFFORT="$DK_PROVIDER_EFFORT"
  DK_PROVIDER_LAST_PROVIDER_PLAN_EFFORT="$DK_PROVIDER_PLAN_EFFORT"
}

dk_provider_claude() {
  [[ -n "${DK_PROVIDER_ENGINE:-}" ]] || dk_provider_apply || return 1
  if [[ -n "${DOYAKEN_SESSION_ID:-}" ]]; then
    dk_provider_write_session_state "$DOYAKEN_SESSION_ID" || return 1
  fi
  local env_args=()
  local provider_external_env_name
  while IFS= read -r provider_external_env_name; do
    [[ -n "$provider_external_env_name" ]] && env_args+=(-u "$provider_external_env_name")
  done < <(dk_provider_external_env_names)
  local provider_auth_env_name
  while IFS= read -r provider_auth_env_name; do
    [[ -n "$provider_auth_env_name" ]] && env_args+=(-u "$provider_auth_env_name")
  done < <(dk_provider_config_auth_env_unsets)
  local provider_override_env_name
  while IFS= read -r provider_override_env_name; do
    [[ -n "$provider_override_env_name" ]] && env_args+=(-u "$provider_override_env_name")
  done < <(dk_provider_claude_override_env_names)

  case "$DK_PROVIDER_ENGINE" in
    anthropic-gateway)
      local token=""
      if [[ -n "${DK_PROVIDER_AUTH_ENV:-}" ]]; then
        if ! dk_provider_valid_env_name "$DK_PROVIDER_AUTH_ENV"; then
          dk_error "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} has invalid auth_env: ${DK_PROVIDER_AUTH_ENV}"
          return 1
        fi
        token=$(dk_provider_env_value "$DK_PROVIDER_AUTH_ENV")
      fi
      if [[ -n "${DK_PROVIDER_AUTH_ENV:-}" && -z "$token" ]]; then
        dk_error "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} requires ${DK_PROVIDER_AUTH_ENV}, but it is not set."
        return 1
      fi
      if [[ -z "${DK_PROVIDER_BASE_URL:-}" ]]; then
        dk_error "Provider profile ${DK_PROVIDER_PROFILE_RESOLVED} is missing base_url."
        return 1
      fi
      if [[ -n "$token" ]]; then
        [[ -n "${DK_PROVIDER_AUTH_ENV:-}" ]] && env_args+=(-u "$DK_PROVIDER_AUTH_ENV")
        env_args+=(
          ANTHROPIC_BASE_URL="$DK_PROVIDER_BASE_URL"
          ANTHROPIC_AUTH_TOKEN="$token"
          ANTHROPIC_DEFAULT_OPUS_MODEL="$DK_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_SONNET_MODEL="$DK_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_HAIKU_MODEL="${DK_PROVIDER_HAIKU_MODEL:-$DK_CLAUDE_MODEL}"
          ANTHROPIC_CUSTOM_MODEL_OPTION="$DK_CLAUDE_MODEL"
          CLAUDE_CODE_SUBAGENT_MODEL="$DK_CLAUDE_MODEL"
        )
        env \
          "${env_args[@]}" \
          claude "$@"
      else
        env_args+=(
          ANTHROPIC_BASE_URL="$DK_PROVIDER_BASE_URL"
          ANTHROPIC_DEFAULT_OPUS_MODEL="$DK_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_SONNET_MODEL="$DK_CLAUDE_MODEL"
          ANTHROPIC_DEFAULT_HAIKU_MODEL="${DK_PROVIDER_HAIKU_MODEL:-$DK_CLAUDE_MODEL}"
          ANTHROPIC_CUSTOM_MODEL_OPTION="$DK_CLAUDE_MODEL"
          CLAUDE_CODE_SUBAGENT_MODEL="$DK_CLAUDE_MODEL"
        )
        env \
          "${env_args[@]}" \
          claude "$@"
      fi
      ;;
    codex-plugin)
      dk_provider_codex_ready_check || return 1
      env_args+=(
        DK_PROVIDER_PROFILE="$DK_PROVIDER_PROFILE_RESOLVED"
        DK_PROVIDER_ENGINE="$DK_PROVIDER_ENGINE"
        DK_CODEX_MODEL="${DK_CODEX_MODEL:-}"
      )
      env \
        "${env_args[@]}" \
        claude "$@"
      ;;
    claude)
      env_args+=(
        DK_PROVIDER_PROFILE="$DK_PROVIDER_PROFILE_RESOLVED"
        DK_PROVIDER_ENGINE="$DK_PROVIDER_ENGINE"
      )
      env \
        "${env_args[@]}" \
        claude "$@"
      ;;
  esac
}

dk_provider_codex() {
  if [[ "${DK_PROVIDER_CODEX_WRAPPER:-0}" == "1" ]]; then
    dk_provider_codex_wrapper_args "$@" || return 2
  elif ! dk_provider_codex_diagnostic_args "$@"; then
    dk_error "Direct dk_provider_codex delegation is blocked."
    dk_info "Use bin/dkcodex.sh so Doyaken can enforce Codex config, sandbox, and provider cleanup."
    return 2
  fi

  local env_args=()
  local provider_external_env_name
  while IFS= read -r provider_external_env_name; do
    [[ -n "$provider_external_env_name" ]] && env_args+=(-u "$provider_external_env_name")
  done < <(dk_provider_external_env_names)
  local provider_auth_env_name
  while IFS= read -r provider_auth_env_name; do
    [[ -n "$provider_auth_env_name" ]] && env_args+=(-u "$provider_auth_env_name")
  done < <(dk_provider_config_auth_env_unsets)
  local provider_override_env_name
  while IFS= read -r provider_override_env_name; do
    [[ -n "$provider_override_env_name" ]] && env_args+=(-u "$provider_override_env_name")
  done < <(dk_provider_claude_override_env_names)
  env "${env_args[@]}" codex "$@"
}

dk_provider_codex_diagnostic_args() {
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

dk_provider_codex_wrapper_args() {
  local subcmd="${1:-}"
  [[ "$subcmd" == "exec" ]] || {
    dk_error "Doyaken Codex wrapper may only delegate through 'codex exec'."
    return 1
  }

  local saw_ignore_user_config=0
  local saw_full_auto=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ignore-user-config)
        saw_ignore_user_config=1
        ;;
      --full-auto)
        saw_full_auto=1
        ;;
    esac
    shift
  done

  if [[ $saw_ignore_user_config -ne 1 || $saw_full_auto -ne 1 ]]; then
    dk_error "Doyaken Codex delegation requires --ignore-user-config and --full-auto."
    return 1
  fi
}

dk_provider_claude_diagnostic() {
  [[ -n "${DK_PROVIDER_ENGINE:-}" ]] || dk_provider_apply || return 1
  local env_args=()
  local provider_external_env_name
  while IFS= read -r provider_external_env_name; do
    [[ -n "$provider_external_env_name" ]] && env_args+=(-u "$provider_external_env_name")
  done < <(dk_provider_external_env_names)
  local provider_auth_env_name
  while IFS= read -r provider_auth_env_name; do
    [[ -n "$provider_auth_env_name" ]] && env_args+=(-u "$provider_auth_env_name")
  done < <(dk_provider_config_auth_env_unsets)
  local provider_override_env_name
  while IFS= read -r provider_override_env_name; do
    [[ -n "$provider_override_env_name" ]] && env_args+=(-u "$provider_override_env_name")
  done < <(dk_provider_claude_override_env_names)
  env_args+=(
    DK_PROVIDER_PROFILE="$DK_PROVIDER_PROFILE_RESOLVED"
    DK_PROVIDER_ENGINE="$DK_PROVIDER_ENGINE"
  )
  env "${env_args[@]}" claude "$@"
}

dk_provider_codex_ignore_user_config_check() {
  local codex_exec_help codex_review_help
  codex_exec_help=$(dk_provider_codex exec --help 2>&1 || true)
  codex_review_help=$(dk_provider_codex exec review --help 2>&1 || true)
  if printf '%s\n' "$codex_exec_help" | grep -q -- "--ignore-user-config" && printf '%s\n' "$codex_review_help" | grep -q -- "--ignore-user-config"; then
    return 0
  fi
  dk_error "Codex CLI does not support --ignore-user-config; upgrade Codex before using codex-subscription."
  return 1
}

dk_provider_codex_ready_check() {
  if ! command -v codex >/dev/null 2>&1; then
    dk_error "Codex CLI not found; codex-subscription cannot delegate work before launching Claude."
    dk_info "Install Codex, sign in with ChatGPT, then run 'dk provider doctor'."
    return 1
  fi
  dk_provider_codex_ignore_user_config_check || return 1

  local login_status
  login_status=$(dk_provider_codex login status 2>&1 || true)
  if printf '%s\n' "$login_status" | grep -qi "ChatGPT"; then
    return 0
  fi
  if printf '%s\n' "$login_status" | grep -q "Logged in"; then
    dk_error "Codex CLI is logged in, but ChatGPT subscription auth could not be confirmed."
  else
    dk_error "Codex CLI is not logged in with ChatGPT."
  fi
  dk_info "Run 'codex login' or '/codex:setup', then run 'dk provider doctor'."
  return 1
}

dk_provider_prompt() {
  [[ -n "${DK_PROVIDER_ENGINE:-}" ]] || dk_provider_apply || return 1

  if [[ "$DK_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    local codex_wrapper="${DOYAKEN_DIR}/bin/dkcodex.sh"
    cat <<EOF

## Provider Profile: Codex Subscription Delegation

Doyaken is running in the "${DK_PROVIDER_PROFILE_RESOLVED}" provider profile.
Claude Code remains the outer lifecycle harness, but substantive coding and
review work should be delegated to Codex using the local Codex CLI through the
Doyaken wrapper. The OpenAI Codex Claude Code plugin is optional for setup/slash
commands, but not for subscription-safe delegation.

Subscription-safety rules:
- Do NOT set or use OpenAI/Anthropic API keys, gateway URLs, or provider routing env vars.
- Prefer the signed-in Codex CLI subscription session.
- Use the Doyaken Codex wrapper shown below. Do NOT run raw "codex exec" or
  "codex exec review"; also do NOT run raw aliases/forms like "codex e",
  "codex review", bare "codex <prompt>", direct "dk_provider_codex"
  delegation, or package-runner forms like "npx codex". The wrapper enforces
  "--ignore-user-config", sanitized environment variables, and the configured
  Codex model.
- If Codex is missing or not logged in, stop and report that "dk provider doctor"
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
  do not go through the Doyaken wrapper.
- After Codex returns, inspect the resulting changes yourself and continue the
  Doyaken phase protocol, including skills, audits, verification, commits, and PR flow.
EOF
  elif [[ "$DK_PROVIDER_ENGINE" == "anthropic-gateway" ]]; then
    cat <<EOF

## Provider Profile: Gateway API

Doyaken is running through the "${DK_PROVIDER_PROFILE_RESOLVED}" gateway profile.
This mode is API/provider billed unless the gateway operator provides a separate
subscription-safe billing arrangement.
EOF
  fi
}

dk_provider_list() {
  dk_provider_validate_config_files || return 1
  printf '%s\n' "Built-in profiles:"
  printf '  %s\n' "claude-subscription     Claude Code with Claude subscription OAuth"
  printf '  %s\n' "codex-subscription      Claude Code harness with Codex CLI subscription delegation"

  local repo_config
  repo_config=$(dk_provider_repo_config 2>/dev/null || true)
  for file in "$repo_config" "$DK_PROVIDER_GLOBAL_CONFIG"; do
    [[ -n "$file" && -f "$file" ]] || continue
    printf '\n%s\n' "Profiles in $file:"
    python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
for name in sorted(data.get("profiles", {})):
    print(f"  {name}")
' "$file" 2>/dev/null || dk_warn "Could not parse $file"
  done
}

dk_provider_current() {
  dk_provider_apply || return 1
  dk_info "Profile: ${DK_PROVIDER_PROFILE_RESOLVED}"
  dk_info "Engine:  ${DK_PROVIDER_ENGINE}"
  dk_info "Auth:    ${DK_PROVIDER_AUTH:-unknown}"
  dk_info "Claude:  ${DK_CLAUDE_MODEL} (${DK_CLAUDE_EFFORT})"
  if [[ "$DK_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    dk_info "Codex:   ${DK_CODEX_MODEL:-default}"
  fi
  if [[ "$DK_PROVIDER_ENGINE" == "anthropic-gateway" ]]; then
    dk_info "Gateway: ${DK_PROVIDER_BASE_URL:-not configured}"
  fi
}

dk_provider_write_default() {
  local profile="$1" scope="$2" file
  if [[ "$scope" == "repo" ]]; then
    file=$(dk_provider_repo_config) || return 1
  else
    file="$DK_PROVIDER_GLOBAL_CONFIG"
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
  dk_done "Set ${scope} provider profile to ${profile}"
}

dk_provider_subscription_safe_check() {
  local ok=0
  local provider_external_env_name provider_external_env_value
  while IFS= read -r provider_external_env_name; do
    [[ -n "$provider_external_env_name" ]] || continue
    provider_external_env_value=$(dk_provider_env_value "$provider_external_env_name")
    if [[ -n "$provider_external_env_value" ]]; then
      dk_error "${provider_external_env_name} is set; it can route Claude/Codex through API, gateway, or provider-billed auth instead of subscription auth."
      ok=1
    fi
  done < <(dk_provider_external_env_names)
  local provider_auth_env_name
  while IFS= read -r provider_auth_env_name; do
    if [[ -n "$provider_auth_env_name" ]]; then
      local provider_auth_env_value
      provider_auth_env_value=$(dk_provider_env_value "$provider_auth_env_name")
      if [[ -n "$provider_auth_env_value" ]]; then
        dk_error "${provider_auth_env_name} is set; it matches a configured provider auth_env and may expose gateway/API credentials."
        ok=1
      fi
    fi
  done < <(dk_provider_config_auth_env_unsets)
  if ! dk_provider_claude_override_env_check; then
    ok=1
  fi
  if [[ $ok -ne 0 ]]; then
    dk_info "Unset API/gateway and model override env vars. DK_ALLOW_API_BILLED_AUTH=1 only tolerates API/gateway billing vars."
  fi
  return $ok
}

dk_provider_claude_override_env_check() {
  local ok=0
  local override_env_name override_env_value
  while IFS= read -r override_env_name; do
    [[ -n "$override_env_name" ]] || continue
    override_env_value=$(dk_provider_env_value "$override_env_name")
    if [[ -n "$override_env_value" ]]; then
      dk_error "${override_env_name} is set; it can override provider profile model or effort routing."
      ok=1
    fi
  done < <(dk_provider_claude_override_env_names)
  return $ok
}

dk_provider_valid_env_name() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

dk_provider_valid_model_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]]
}

dk_provider_validate_model_field() {
  local label="$1" value="$2"
  if [[ -n "$value" ]] && ! dk_provider_valid_model_id "$value"; then
    dk_error "${label} has invalid model id: ${value}"
    dk_info "Model ids may contain only letters, numbers, dot, underscore, dash, colon, slash, and plus, and must start with a letter or number."
    return 1
  fi
}

dk_provider_valid_effort() {
  case "$1" in
    low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

dk_provider_validate_effort_field() {
  local label="$1" value="$2"
  if [[ -n "$value" ]] && ! dk_provider_valid_effort "$value"; then
    dk_error "${label} has invalid effort: ${value}"
    dk_info "Supported efforts: low, medium, high, xhigh, max"
    return 1
  fi
}

dk_provider_doctor() {
  dk_provider_apply || return 1
  dk_provider_current
  printf '\n'

  local failed=0
  if command -v claude >/dev/null 2>&1; then
    dk_ok "Claude Code CLI found"
  else
    dk_error "Claude Code CLI not found"
    failed=1
  fi

  case "$DK_PROVIDER_ENGINE" in
    claude|codex-plugin)
      if [[ "${DK_ALLOW_API_BILLED_AUTH:-0}" == "1" ]]; then
        dk_warn "API/gateway billing env vars allowed by DK_ALLOW_API_BILLED_AUTH=1"
        if ! dk_provider_claude_override_env_check; then
          failed=1
        fi
      elif dk_provider_subscription_safe_check; then
        dk_ok "Subscription-safe Claude environment"
      else
        failed=1
      fi
      ;;
    anthropic-gateway)
      if ! dk_provider_claude_override_env_check; then
        failed=1
      fi
      if [[ -z "$DK_PROVIDER_BASE_URL" ]]; then
        dk_error "Gateway profile is missing base_url"
        failed=1
      else
        dk_ok "Gateway URL configured"
      fi
      if [[ -n "$DK_PROVIDER_AUTH_ENV" ]]; then
        if ! dk_provider_valid_env_name "$DK_PROVIDER_AUTH_ENV"; then
          dk_error "Gateway auth_env is not a valid environment variable name: $DK_PROVIDER_AUTH_ENV"
          return 1
        fi
        local token
        token=$(dk_provider_env_value "$DK_PROVIDER_AUTH_ENV")
        if [[ -n "$token" ]]; then
          dk_ok "Gateway auth env ${DK_PROVIDER_AUTH_ENV} is set"
        else
          dk_error "Gateway auth env ${DK_PROVIDER_AUTH_ENV} is not set"
          failed=1
        fi
      else
        dk_warn "Gateway profile has no auth_env; only use this if the gateway does not require client auth"
      fi
      ;;
  esac

  if [[ "$DK_PROVIDER_ENGINE" == "codex-plugin" ]]; then
    local codex_cli_found=0
    if command -v codex >/dev/null 2>&1; then
      codex_cli_found=1
      dk_ok "Codex CLI found"
      if dk_provider_codex_ignore_user_config_check; then
        dk_ok "Codex CLI supports --ignore-user-config"
      else
        failed=1
      fi
      local login_status
      login_status=$(dk_provider_codex login status 2>&1 || true)
      if printf '%s\n' "$login_status" | grep -qi "ChatGPT"; then
        dk_ok "Codex is logged in with ChatGPT"
      elif printf '%s\n' "$login_status" | grep -q "Logged in"; then
        dk_error "Codex is logged in, but doctor could not confirm ChatGPT subscription auth"
        failed=1
      else
        dk_error "Codex is not logged in with ChatGPT"
        failed=1
      fi
    else
      dk_error "Codex CLI not found"
      failed=1
    fi
    local codex_skill_count=0
    local codex_skill_expected=0
    if command -v dk_count_codex_doyaken_skills >/dev/null 2>&1; then
      codex_skill_count=$(dk_count_codex_doyaken_skills)
      codex_skill_expected=$(dk_count_doyaken_skills)
    fi
    if command -v dk_codex_doyaken_skills_complete >/dev/null 2>&1 && dk_codex_doyaken_skills_complete; then
      dk_ok "Doyaken Codex skills linked (${codex_skill_count}/${codex_skill_expected})"
    elif [[ "$codex_skill_count" -gt 0 ]]; then
      dk_warn "Doyaken Codex skills are partially linked (${codex_skill_count}/${codex_skill_expected}); run 'dk install' to repair skill links"
    else
      dk_warn "Doyaken Codex skills are not linked; run 'dk install' to refresh skill links"
    fi

    local plugin_status
    plugin_status=$(dk_provider_claude_diagnostic plugin list 2>/dev/null || true)
    if printf '%s\n' "$plugin_status" | grep -A4 "codex@openai-codex" | grep -qi "enabled"; then
      dk_ok "OpenAI Codex Claude Code plugin installed"
    else
      if [[ $codex_cli_found -eq 1 ]]; then
        dk_warn "OpenAI Codex Claude Code plugin not installed; Codex CLI delegation is still available"
        dk_info "Install plugin slash commands with: claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex"
      else
        dk_error "OpenAI Codex Claude Code plugin not installed"
        dk_info "Install it with: claude plugin marketplace add openai/codex-plugin-cc && claude plugin install codex@openai-codex"
        failed=1
      fi
    fi
    dk_info "Run '/codex:setup' inside Claude Code when Claude usage is available."
  fi

  return $failed
}

dk_provider_command() {
  local subcmd="${1:-current}"
  shift 2>/dev/null || true

  case "$subcmd" in
    list)
      dk_provider_list
      ;;
    current)
      dk_provider_current
      ;;
    doctor)
      dk_provider_doctor
      ;;
    use)
      dk_provider_validate_config_files || return 1
      local scope="global"
      if [[ "${1:-}" == "--repo" ]]; then
        scope="repo"
        shift
      fi
      local profile="${1:-}"
      if [[ -z "$profile" ]]; then
        dk_error "Usage: dk provider use [--repo] <profile>"
        return 1
      fi
      if [[ "$scope" == "global" ]]; then
        if ! __dk_provider_builtin_get "$profile" "engine" >/dev/null 2>&1 && ! __dk_provider_json_get "$DK_PROVIDER_GLOBAL_CONFIG" "$profile" "engine" >/dev/null 2>&1; then
          dk_error "Global provider profile is not defined globally: $profile"
          dk_info "Use 'dk provider use --repo $profile' for repo-local profiles, or define the profile in ~/.doyaken/providers.json."
          return 1
        fi
      else
        local repo_config
        repo_config=$(dk_provider_repo_config) || return 1
        if ! __dk_provider_builtin_get "$profile" "engine" >/dev/null 2>&1 && ! __dk_provider_json_get "$repo_config" "$profile" "engine" >/dev/null 2>&1; then
          dk_error "Repo provider profile is not built in or defined in this repo: $profile"
          dk_info "Define custom repo profiles in .doyaken/providers.json, or use a built-in profile."
          return 1
        fi
        local repo_engine
        repo_engine=$(__dk_provider_json_get "$repo_config" "$profile" "engine" 2>/dev/null || true)
        if [[ "$repo_engine" == "anthropic-gateway" ]] && ! dk_provider_repo_gateway_allowed; then
          dk_error "Repo gateway/API profiles cannot be saved as an auto-selected default without DK_ALLOW_REPO_GATEWAY_PROVIDER=1."
          dk_info "Define gateway profiles in ~/.doyaken/providers.json, or use DK_PROVIDER_PROFILE=$profile DK_ALLOW_REPO_GATEWAY_PROVIDER=1 for an explicit one-off repo opt-in."
          return 1
        fi
      fi
      dk_provider_write_default "$profile" "$scope"
      ;;
    help|--help|-h)
      printf '%s\n' "Usage: dk provider <command>"
      printf '%s\n' ""
      printf '%s\n' "Commands:"
      printf '%s\n' "  list                    Show built-in and configured profiles"
      printf '%s\n' "  current                 Show the resolved active profile"
      printf '%s\n' "  use <profile>           Set the global default profile"
      printf '%s\n' "  use --repo <profile>    Set the current repo default profile"
      printf '%s\n' "  doctor                  Check subscription-safety and local tooling"
      ;;
    *)
      dk_error "Unknown provider command: $subcmd"
      dk_info "Run 'dk provider help' for usage."
      return 1
      ;;
  esac
}
