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
import http.client
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qsl, urljoin, urlparse

url = os.environ["DX_RUN_SPEC_URL"]
output = Path(os.environ["DX_RUN_SPEC_OUTPUT"])
token = os.environ.get("DX_RUN_SPEC_TOKEN", "")
max_spec_bytes = 1024 * 1024
secret_query_re = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)
allowed_token_chars = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="
)


class InvalidSpecURL(ValueError):
    pass


class UnsafeRedirectError(Exception):
    pass


class SpecTooLargeError(Exception):
    pass


def validate_spec_url(candidate):
    if any(ord(char) <= 32 or ord(char) == 127 for char in candidate):
        raise InvalidSpecURL("control characters are not allowed")
    try:
        parsed_candidate = urlparse(candidate)
    except ValueError as exc:
        raise InvalidSpecURL(str(exc)) from exc
    if (
        parsed_candidate.scheme not in {"http", "https"}
        or not parsed_candidate.netloc
        or not parsed_candidate.hostname
    ):
        raise InvalidSpecURL("expected http(s) URL")
    try:
        parsed_candidate.port
    except ValueError as exc:
        raise InvalidSpecURL("port must be numeric") from exc
    if parsed_candidate.username or parsed_candidate.password:
        raise InvalidSpecURL("credentials must not be embedded in the URL")
    if parsed_candidate.fragment:
        raise InvalidSpecURL("fragments are not allowed")
    for key, _value in parse_qsl(parsed_candidate.query, keep_blank_values=True):
        if secret_query_re.search(key):
            raise InvalidSpecURL(
                "use --run-token instead of secret-bearing query parameters"
            )
    return parsed_candidate


def url_origin(parsed_url):
    default_port = 443 if parsed_url.scheme == "https" else 80
    return (
        parsed_url.scheme.lower(),
        (parsed_url.hostname or "").lower(),
        parsed_url.port or default_port,
    )


try:
    parsed = validate_spec_url(url)
except InvalidSpecURL as exc:
    print(f"invalid spec URL: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc

initial_origin = url_origin(parsed)

if token and (
    len(token) > 8192
    or any(char not in allowed_token_chars for char in token)
):
    print("invalid run token: expected Bearer-token characters", file=sys.stderr)
    raise SystemExit(1)


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target_url = urljoin(req.full_url, newurl)
        target = validate_spec_url(target_url)
        if token and url_origin(target) != initial_origin:
            raise UnsafeRedirectError(
                "authenticated run spec redirects must remain on the original origin"
            )
        return super().redirect_request(req, fp, code, msg, headers, target_url)

request = urllib.request.Request(url, method="GET")
request.add_header("Accept", "application/json")
request.add_header("User-Agent", "dex-run-spec/1")
if token:
    request.add_header("Authorization", f"Bearer {token}")

try:
    opener = urllib.request.build_opener(SafeRedirectHandler())
    with opener.open(request, timeout=15) as response:
        status = response.getcode()
        if not 200 <= status < 300:
            print(f"spec URL returned HTTP {status}", file=sys.stderr)
            raise SystemExit(1)
        content_length = response.headers.get("Content-Length")
        if content_length:
            try:
                if int(content_length) > max_spec_bytes:
                    raise SpecTooLargeError
            except ValueError:
                pass
        chunks = []
        total = 0
        while True:
            chunk = response.read(min(64 * 1024, max_spec_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_spec_bytes:
                raise SpecTooLargeError
            chunks.append(chunk)
        data = b"".join(chunks)
except SpecTooLargeError:
    print(f"could not fetch run spec: response exceeds {max_spec_bytes} bytes", file=sys.stderr)
    raise SystemExit(1)
except UnsafeRedirectError as exc:
    print(f"could not fetch run spec: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
except InvalidSpecURL as exc:
    print(f"invalid spec URL: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc
except urllib.error.HTTPError as exc:
    print(f"spec URL returned HTTP {exc.code}", file=sys.stderr)
    raise SystemExit(1) from exc
except urllib.error.URLError as exc:
    print(f"could not fetch run spec: {exc.reason}", file=sys.stderr)
    raise SystemExit(1) from exc
except TimeoutError as exc:
    print("could not fetch run spec: timeout", file=sys.stderr)
    raise SystemExit(1) from exc
except (ValueError, http.client.InvalidURL) as exc:
    print(f"invalid spec URL: {exc}", file=sys.stderr)
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
try:
    parts = urlsplit(source)
except ValueError:
    print("invalid-spec-url")
    raise SystemExit(0)
if parts.scheme not in {"http", "https"} or not parts.netloc:
    print(source)
    raise SystemExit(0)

host = parts.hostname or ""
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
netloc = host
try:
    port = parts.port
except ValueError:
    port = None
if port:
    netloc = f"{netloc}:{port}"

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
MAX_SPEC_BYTES = 1024 * 1024
MAX_SOURCE_BODY_BYTES = 128 * 1024

RUN_ID_RE = re.compile(r"^run_[A-Za-z0-9._-]+$")
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]*$")
# The same set dx_provider_validate_effort_field enforces. A spec may only ask
# for an effort the CLI could actually pass on.
SPEC_EFFORTS = {"low", "medium", "high", "xhigh", "max"}
SECRET_KEY_RE = re.compile(r"(token|secret|password|passwd|api[_-]?key|credential)", re.I)
# One pattern: a divergence here would silently weaken secret rejection in
# exactly one of the two paths that share it.
SECRET_QUERY_RE = SECRET_KEY_RE
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


def validate_text(value, path, max_bytes, *, multiline=False):
    if len(value.encode("utf-8")) > max_bytes:
        fail(f"{path} must not exceed {max_bytes} UTF-8 bytes")
    for char in value:
        codepoint = ord(char)
        unsupported_control = codepoint < 32 and (
            not multiline or char not in "\n\t"
        )
        if codepoint in {0, 127} or unsupported_control:
            fail(f"{path} contains unsupported control characters")


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
    if value in {".", ".."} or (value and not SLUG_RE.match(value)):
        fail(f"{path} must be a lowercase slug using letters, numbers, '.', '_', or '-'")


def validate_branch(value, path):
    if len(value.encode("utf-8")) > 255 or value == "HEAD":
        fail(f"{path} is not a safe branch name")
    if not BRANCH_RE.match(value) or value.startswith(("-", "/", ".")) or value.endswith(("/", ".")):
        fail(f"{path} is not a safe branch name")
    if ".." in value or "//" in value or "@{" in value or "\\" in value:
        fail(f"{path} is not a safe branch name")
    components = value.split("/")
    if any(component.startswith(".") or component.endswith(".lock") for component in components):
        fail(f"{path} is not a safe branch name")


def validate_url(value, path, *, base=False, allow_fragment=False):
    if not value:
        return
    from urllib.parse import parse_qsl, urlsplit

    validate_text(value, path, 8192)
    try:
        parsed = urlsplit(value)
    except ValueError as exc:
        fail(f"{path} is invalid: {exc}")
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        fail(f"{path} must be an http(s) URL")
    try:
        parsed.port
    except ValueError:
        fail(f"{path} port must be numeric")
    if parsed.username or parsed.password:
        fail(f"{path} must not include URL credentials")
    if parsed.fragment and not allow_fragment:
        fail(f"{path} must not include a fragment")
    for key, _value in parse_qsl(parsed.query, keep_blank_values=True):
        if SECRET_QUERY_RE.search(key):
            fail(f"{path} must not include secret-bearing query parameters")
    if base and (parsed.query or parsed.fragment):
        fail(f"{path} must be a base URL without query or fragment")


try:
    if input_path.stat().st_size > MAX_SPEC_BYTES:
        fail(f"file exceeds {MAX_SPEC_BYTES} bytes")
    data = json.loads(input_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    fail(f"file not found: {input_path}")
except json.JSONDecodeError as exc:
    fail(f"JSON parse error at line {exc.lineno} column {exc.colno}: {exc.msg}")
except UnicodeDecodeError:
    fail("file must contain valid UTF-8 JSON")
except OSError as exc:
    fail(f"could not read file: {exc}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

reject_secret_keys(data)

run_id = string_at(data, "run_id", "run_spec")
# DexCode stores this in agent_runs.external_id, constrained to 128
# characters. Accepting 200 here meant an over-long id passed validation and
# was refused by the server with a 400, which is fatal rather than retried.
validate_text(run_id, "run_id", 128)
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
validate_text(company_slug, "company.slug", 100)
validate_text(project_slug, "project.slug", 100)
validate_text(repo_provider, "repository.provider", 64)
validate_text(repo_full_name, "repository.full_name", 256)
validate_text(working_directory, "repository.working_directory", 4096)
validate_slug(company_slug, "company.slug")
validate_slug(project_slug, "project.slug")
if repo_full_name and (
    not REPO_FULL_NAME_RE.match(repo_full_name)
    or any(part in {".", ".."} for part in repo_full_name.split("/"))
):
    fail("repository.full_name must look like owner/repo")
validate_branch(default_branch, "repository.default_branch")
if not Path(working_directory).is_absolute():
    fail("repository.working_directory must be an absolute path")

source_type = string_at(source, "type", "source")
source_id = string_at(source, "id", "source", required=False)
source_url = string_at(source, "url", "source", required=False)
source_title = string_at(source, "title", "source", required=False)
source_body = string_at(source, "body", "source", required=False)
validate_text(source_type, "source.type", 100)
validate_text(source_id, "source.id", 512)
validate_text(source_title, "source.title", 1024)
validate_text(source_body, "source.body", MAX_SOURCE_BODY_BYTES, multiline=True)
if not any([source_id, source_url, source_title, source_body]):
    fail("source must include at least one of id, url, title, or body")
validate_url(source_url, "source.url", allow_fragment=True)

harness_name = string_at(harness, "name", "harness", required=False) or "claude-code"
if harness_name not in VALID_HARNESS_NAMES:
    fail(f"harness.name must be one of: {', '.join(sorted(VALID_HARNESS_NAMES))}")
harness_effort = harness.get("effort")
if harness_effort is None:
    harness_effort = ""
elif not isinstance(harness_effort, str) or harness_effort.strip() not in SPEC_EFFORTS:
    fail("harness.effort must be one of: " + ", ".join(sorted(SPEC_EFFORTS)))
else:
    harness_effort = harness_effort.strip()

harness_model = harness.get("model")
if harness_model is None:
    harness_model = ""
elif not isinstance(harness_model, str) or not harness_model.strip():
    fail("harness.model must be a non-empty string or null")
else:
    harness_model = harness_model.strip()
    validate_text(harness_model, "harness.model", 256)
    if not MODEL_RE.match(harness_model):
        fail("harness.model contains unsupported characters")

workflow_name = string_at(workflow, "name", "workflow", required=False) or "ticket_to_pr"
workflow_version = string_at(workflow, "version", "workflow", required=False) or "v1"
validate_text(workflow_name, "workflow.name", 100)
validate_text(workflow_version, "workflow.version", 100)
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
    "effort": harness_effort or None,
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
