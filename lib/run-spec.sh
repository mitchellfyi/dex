# shellcheck shell=bash
# Dex shared library - structured headless run specs.

dx_run_spec_token() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' "$1"
  elif [[ -n "${DEX_RUN_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_RUN_TOKEN"
  elif [[ -n "${DEX_FACTORY_RUN_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_FACTORY_RUN_TOKEN"
  elif [[ -n "${DEX_FACTORY_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_FACTORY_TOKEN"
  else
    return 1
  fi
}

dx_run_spec_fetch() {
  local spec_url="$1" output_file="$2" token="${3:-}" tmp_file
  [[ -n "$spec_url" && -n "$output_file" ]] || return 1
  tmp_file="${output_file}.tmp.$$"

  DX_RUN_SPEC_URL="$spec_url" \
  DX_RUN_SPEC_OUTPUT="$tmp_file" \
  DX_RUN_SPEC_TOKEN="$token" \
  python3 - <<'PY'
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qsl, urlparse

url = os.environ["DX_RUN_SPEC_URL"]
output = Path(os.environ["DX_RUN_SPEC_OUTPUT"])
token = os.environ.get("DX_RUN_SPEC_TOKEN", "")
secret_query_re = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)

parsed = urlparse(url)
if parsed.scheme not in {"http", "https"} or not parsed.netloc:
    print("invalid spec URL: expected http(s) URL", file=sys.stderr)
    raise SystemExit(1)
if parsed.username or parsed.password:
    print("invalid spec URL: credentials must not be embedded in the URL", file=sys.stderr)
    raise SystemExit(1)
for key, _value in parse_qsl(parsed.query, keep_blank_values=True):
    if secret_query_re.search(key):
        print("invalid spec URL: use --run-token instead of secret-bearing query parameters", file=sys.stderr)
        raise SystemExit(1)

request = urllib.request.Request(url, method="GET")
request.add_header("Accept", "application/json")
request.add_header("User-Agent", "dex-run-spec/1")
if token:
    request.add_header("Authorization", f"Bearer {token}")

try:
    with urllib.request.urlopen(request, timeout=15) as response:
        status = response.getcode()
        if not 200 <= status < 300:
            print(f"spec URL returned HTTP {status}", file=sys.stderr)
            raise SystemExit(1)
        data = response.read()
except urllib.error.HTTPError as exc:
    print(f"spec URL returned HTTP {exc.code}", file=sys.stderr)
    raise SystemExit(1) from exc
except urllib.error.URLError as exc:
    print(f"could not fetch run spec: {exc.reason}", file=sys.stderr)
    raise SystemExit(1) from exc
except TimeoutError as exc:
    print("could not fetch run spec: timeout", file=sys.stderr)
    raise SystemExit(1) from exc

output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(data)
PY
  local fetch_status=$?
  if [[ $fetch_status -ne 0 ]]; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return "$fetch_status"
  fi
  command mv -f "$tmp_file" "$output_file"
}

dx_run_spec_redact_source() {
  local source="$1"
  DX_RUN_SPEC_SOURCE="$source" python3 - <<'PY'
import os
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

source = os.environ.get("DX_RUN_SPEC_SOURCE", "")
secret_key_re = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)
parts = urlsplit(source)
if parts.scheme not in {"http", "https"} or not parts.netloc:
    print(source)
    raise SystemExit(0)

host = parts.hostname or ""
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
netloc = host
if parts.port:
    netloc = f"{netloc}:{parts.port}"

query = []
for key, value in parse_qsl(parts.query, keep_blank_values=True):
    query.append((key, "[REDACTED]" if secret_key_re.search(key) else value))

print(urlunsplit((parts.scheme, netloc, parts.path, urlencode(query), "")))
PY
}

dx_run_spec_normalize() {
  local input_file="$1" output_file="$2"
  [[ -n "$input_file" && -n "$output_file" ]] || return 1

  DX_RUN_SPEC_INPUT="$input_file" \
  DX_RUN_SPEC_OUTPUT="$output_file" \
  python3 - <<'PY'
import copy
import json
import os
import re
import sys
import tempfile
from pathlib import Path

input_path = Path(os.environ["DX_RUN_SPEC_INPUT"])
output_path = Path(os.environ["DX_RUN_SPEC_OUTPUT"])

RUN_ID_RE = re.compile(r"^run_[A-Za-z0-9._-]+$")
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]*$")
SECRET_KEY_RE = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)
SECRET_QUERY_RE = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
REPO_FULL_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VALID_HARNESS_NAMES = {"claude-code", "claude", "codex"}
VALID_UI_EVIDENCE = {"auto", "always", "never"}


def fail(message):
    print(f"invalid run spec: {message}", file=sys.stderr)
    raise SystemExit(1)


def as_object(value, path, required=True):
    if value is None and not required:
        return {}
    if not isinstance(value, dict):
        fail(f"{path} must be an object")
    return value


def string_at(obj, key, path, required=True):
    value = obj.get(key)
    if value is None:
        if required:
            fail(f"{path}.{key} is required")
        return ""
    if not isinstance(value, str):
        fail(f"{path}.{key} must be a string")
    value = value.strip()
    if required and not value:
        fail(f"{path}.{key} must not be empty")
    return value


def bool_at(obj, key, path, default):
    value = obj.get(key, default)
    if not isinstance(value, bool):
        fail(f"{path}.{key} must be true or false")
    return value


def reject_secret_keys(value, path=""):
    if isinstance(value, dict):
        for key, child in value.items():
            next_path = f"{path}.{key}" if path else str(key)
            if SECRET_KEY_RE.search(str(key)):
                fail(f"{next_path} is not allowed; run specs must not contain secrets")
            reject_secret_keys(child, next_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_secret_keys(child, f"{path}[{index}]")


def validate_slug(value, path):
    if value and not SLUG_RE.match(value):
        fail(f"{path} must be a lowercase slug using letters, numbers, '.', '_', or '-'")


def validate_branch(value, path):
    if not BRANCH_RE.match(value) or value.startswith(("-", "/", ".")) or value.endswith(("/", ".")):
        fail(f"{path} is not a safe branch name")
    if ".." in value or "//" in value or "@{" in value or "\\" in value:
        fail(f"{path} is not a safe branch name")


def validate_url(value, path, *, base=False):
    if not value:
        return
    from urllib.parse import parse_qsl, urlsplit

    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        fail(f"{path} must be an http(s) URL")
    if parsed.username or parsed.password:
        fail(f"{path} must not include URL credentials")
    for key, _value in parse_qsl(parsed.query, keep_blank_values=True):
        if SECRET_QUERY_RE.search(key):
            fail(f"{path} must not include secret-bearing query parameters")
    if base and (parsed.query or parsed.fragment):
        fail(f"{path} must be a base URL without query or fragment")


try:
    data = json.loads(input_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    fail(f"file not found: {input_path}")
except json.JSONDecodeError as exc:
    fail(f"JSON parse error at line {exc.lineno} column {exc.colno}: {exc.msg}")
except OSError as exc:
    fail(f"could not read file: {exc}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

reject_secret_keys(data)

run_id = string_at(data, "run_id", "run_spec")
if not RUN_ID_RE.match(run_id) or ".." in run_id or "/" in run_id:
    fail("run_id must match run_[A-Za-z0-9._-]+ and must not contain path segments")

company = as_object(data.get("company"), "company", required=False)
project = as_object(data.get("project"), "project", required=False)
repository = as_object(data.get("repository"), "repository")
source = as_object(data.get("source"), "source")
harness = as_object(data.get("harness"), "harness", required=False)
workflow = as_object(data.get("workflow"), "workflow", required=False)
sync = as_object(data.get("sync"), "sync", required=False)

company_slug = string_at(company, "slug", "company", required=False)
project_slug = string_at(project, "slug", "project", required=False)
repo_provider = string_at(repository, "provider", "repository", required=False) or "github"
repo_full_name = string_at(repository, "full_name", "repository", required=False)
default_branch = string_at(repository, "default_branch", "repository", required=False) or "main"
working_directory = string_at(repository, "working_directory", "repository")
validate_slug(company_slug, "company.slug")
validate_slug(project_slug, "project.slug")
if repo_full_name and not REPO_FULL_NAME_RE.match(repo_full_name):
    fail("repository.full_name must look like owner/repo")
validate_branch(default_branch, "repository.default_branch")
if not Path(working_directory).is_absolute():
    fail("repository.working_directory must be an absolute path")

source_type = string_at(source, "type", "source")
source_id = string_at(source, "id", "source", required=False)
source_url = string_at(source, "url", "source", required=False)
source_title = string_at(source, "title", "source", required=False)
source_body = string_at(source, "body", "source", required=False)
if not any([source_id, source_url, source_title, source_body]):
    fail("source must include at least one of id, url, title, or body")
validate_url(source_url, "source.url")

harness_name = string_at(harness, "name", "harness", required=False) or "claude-code"
if harness_name not in VALID_HARNESS_NAMES:
    fail(f"harness.name must be one of: {', '.join(sorted(VALID_HARNESS_NAMES))}")
harness_model = harness.get("model")
if harness_model is None:
    harness_model = ""
elif not isinstance(harness_model, str) or not harness_model.strip():
    fail("harness.model must be a non-empty string or null")
else:
    harness_model = harness_model.strip()
    if not MODEL_RE.match(harness_model):
        fail("harness.model contains unsupported characters")

workflow_name = string_at(workflow, "name", "workflow", required=False) or "ticket_to_pr"
workflow_version = string_at(workflow, "version", "workflow", required=False) or "v1"
requires_plan_approval = bool_at(workflow, "requires_plan_approval", "workflow", True)
auto_merge = bool_at(workflow, "auto_merge", "workflow", False)
requires_ui_evidence = workflow.get("requires_ui_evidence", "auto")
if isinstance(requires_ui_evidence, bool):
    requires_ui_evidence = "always" if requires_ui_evidence else "never"
elif isinstance(requires_ui_evidence, str):
    requires_ui_evidence = requires_ui_evidence.strip() or "auto"
else:
    fail("workflow.requires_ui_evidence must be auto, always, never, true, or false")
if requires_ui_evidence not in VALID_UI_EVIDENCE:
    fail("workflow.requires_ui_evidence must be auto, always, or never")

factory_url = string_at(sync, "factory_url", "sync", required=False)
events_endpoint = string_at(sync, "events_endpoint", "sync", required=False)
validate_url(factory_url, "sync.factory_url", base=True)
validate_url(events_endpoint, "sync.events_endpoint")

repo_value = repo_full_name
if not repo_value:
    repo_value = project_slug or Path(working_directory).name or "repo"
if not company_slug and "/" in repo_value:
    company_slug = repo_value.split("/", 1)[0]
if not project_slug:
    project_slug = repo_value.split("/")[-1]

title_line = source_title or f"{source_type} {source_id or run_id}"
prompt_lines = [
    f"Headless run spec: {run_id}",
    f"Source: {source_type}" + (f" {source_id}" if source_id else ""),
]
if source_url:
    prompt_lines.append(f"URL: {source_url}")
prompt_lines.append(f"Title: {title_line}")
if source_body:
    prompt_lines.extend(["", source_body])
source_prompt = "\n".join(prompt_lines).strip()

workspace_input = f"headless {run_id}"

normalized = copy.deepcopy(data)
normalized.update(
    {
        "schema_version": 1,
        "run_spec_schema_version": 1,
        "run_id": run_id,
        "command": "dx run",
        "workspace_mode": "headless",
        "workspace_name": workspace_input,
        "input": source_prompt,
        "company_slug": company_slug,
        "project_slug": project_slug,
        "repo": repo_value,
        "repo_path": working_directory,
        "headless": True,
    }
)
normalized["repository"] = {
    **repository,
    "provider": repo_provider,
    "full_name": repo_full_name,
    "default_branch": default_branch,
    "working_directory": working_directory,
}
normalized["source"] = {
    **source,
    "type": source_type,
    "id": source_id,
    "url": source_url,
    "title": source_title,
    "body": source_body,
}
normalized["harness"] = {
    **harness,
    "name": harness_name,
    "model": harness_model or None,
}
normalized["workflow"] = {
    **workflow,
    "name": workflow_name,
    "version": workflow_version,
    "requires_plan_approval": requires_plan_approval,
    "requires_ui_evidence": requires_ui_evidence,
    "auto_merge": auto_merge,
}
normalized["sync"] = {
    **sync,
    "factory_url": factory_url,
    "events_endpoint": events_endpoint,
}

output_path.parent.mkdir(parents=True, exist_ok=True)
tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=str(output_path.parent), delete=False)
try:
    with tmp:
        json.dump(normalized, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
    os.replace(tmp.name, output_path)
except Exception:
    try:
        Path(tmp.name).unlink()
    except OSError:
        pass
    raise
PY
}

dx_run_spec_field() {
  local spec_file="$1" field="$2"
  [[ -n "$spec_file" && -n "$field" ]] || return 1

  DX_RUN_SPEC_FILE="$spec_file" DX_RUN_SPEC_FIELD="$field" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

data = json.loads(Path(os.environ["DX_RUN_SPEC_FILE"]).read_text(encoding="utf-8"))
value = data
for part in os.environ["DX_RUN_SPEC_FIELD"].split("."):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
    if value is None:
        value = ""
        break
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
else:
    print(str(value))
PY
}

dx_run_spec_prepare_journal() {
  local spec_file="$1" session_id="$2" repo_dir="$3" command_name="${4:-dx run}"
  local run_id run_dir final_spec prepared
  [[ -n "$spec_file" && -n "$session_id" ]] || return 1
  run_id=$(dx_run_spec_field "$spec_file" "run_id") || return 1
  dx_run_validate_id "$run_id" || return 1

  export DEX_RUN_ID="$run_id"
  run_dir=$(dx_run_dir "$run_id") || return 1
  final_spec=$(dx_run_spec_file "$run_id") || return 1
  mkdir -p "$run_dir" "$(dx_run_artifacts_dir "$run_id")"
  command cp "$spec_file" "${final_spec}.tmp.$$" || return 1
  command mv -f "${final_spec}.tmp.$$" "$final_spec" || return 1

  prepared=$(dx_run_prepare "$session_id" "$repo_dir" "headless" "$(dx_run_spec_field "$spec_file" "workspace_name")" "$(dx_run_spec_field "$spec_file" "input")" "$command_name") || return 1
  [[ "$prepared" == "$run_id" ]] || return 1
  printf '%s\n' "$final_spec"
}
