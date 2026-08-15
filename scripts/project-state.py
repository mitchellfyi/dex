#!/usr/bin/env python3
"""Manage Dex project ownership and repository hook provenance."""

from __future__ import annotations

import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import stat
import string
import sys
import tempfile


HOOK_MARKER = "# Dex-managed hook proxy."
STANDARD_HOOKS = (
    "applypatch-msg",
    "pre-applypatch",
    "post-applypatch",
    "pre-commit",
    "pre-merge-commit",
    "prepare-commit-msg",
    "commit-msg",
    "post-commit",
    "pre-rebase",
    "post-checkout",
    "post-merge",
    "pre-push",
    "pre-receive",
    "update",
    "proc-receive",
    "post-receive",
    "post-update",
    "reference-transaction",
    "push-to-checkout",
    "pre-auto-gc",
    "post-rewrite",
    "sendemail-validate",
    "fsmonitor-watchman",
    "fsmonitor-watchmanv2",
    "p4-changelist",
    "p4-prepare-changelist",
    "p4-post-changelist",
    "p4-pre-submit",
    "post-index-change",
)


def read_state(path: Path, label: str) -> dict:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"dex: cannot read {label} state: {exc}") from exc
    if not isinstance(state, dict) or state.get("version") != 1:
        raise SystemExit(f"dex: unsupported {label} state")
    return state


def read_attribution_state(path: Path) -> dict:
    state = read_state(path, "attribution")
    required = {
        "version",
        "config_scope",
        "installed_hooks_path",
        "previous_config_present",
        "previous_config_value",
        "original_hooks_configured",
        "original_hooks_path",
        "generated_hooks",
        "installation_complete",
    }
    allowed = required | {"pending_generated_hooks", "pr_template_created"}
    if not required.issubset(state) or not set(state).issubset(allowed):
        raise SystemExit("dex: invalid attribution state fields")
    if state["config_scope"] not in {"local", "worktree"}:
        raise SystemExit("dex: invalid attribution config scope")
    if path.name == "dex-attribution-state.json":
        expected_scope = "local"
        expected_hooks = path.parent / "dex-hooks"
    elif path.name == "dex-attribution-worktree-state.json":
        expected_scope = "worktree"
        expected_hooks = path.parent / "dex-hooks-worktree"
    else:
        raise SystemExit("dex: attribution state path is not Dex-managed")
    if state["config_scope"] != expected_scope:
        raise SystemExit("dex: attribution config scope does not match its state path")
    installed_hooks_path = state["installed_hooks_path"]
    if (
        not isinstance(installed_hooks_path, str)
        or not Path(installed_hooks_path).is_absolute()
        or Path(installed_hooks_path).name != expected_hooks.name
    ):
        raise SystemExit("dex: invalid installed hook path in attribution state")
    if not isinstance(state["previous_config_present"], bool):
        raise SystemExit("dex: invalid previous config presence in attribution state")
    if not isinstance(state["previous_config_value"], str):
        raise SystemExit("dex: invalid previous config value in attribution state")
    if not isinstance(state["original_hooks_configured"], bool):
        raise SystemExit("dex: invalid original hook config flag in attribution state")
    if not isinstance(state["original_hooks_path"], str) or not state["original_hooks_path"]:
        raise SystemExit("dex: invalid original hook path in attribution state")
    if not state["original_hooks_configured"] and not Path(
        state["original_hooks_path"]
    ).is_absolute():
        raise SystemExit("dex: default original hook path must be absolute")
    if not isinstance(state["installation_complete"], bool):
        raise SystemExit("dex: invalid completion flags in attribution state")
    if "pr_template_created" in state and not isinstance(state["pr_template_created"], bool):
        raise SystemExit("dex: invalid legacy PR template flag in attribution state")

    generated = state["generated_hooks"]
    receipt_sets = [generated]
    if "pending_generated_hooks" in state:
        receipt_sets.append(state["pending_generated_hooks"])
    for receipts in receipt_sets:
        if not isinstance(receipts, dict):
            raise SystemExit("dex: invalid generated hook receipts")
        for name, digest in receipts.items():
            if not isinstance(name, str) or name not in STANDARD_HOOKS:
                raise SystemExit("dex: invalid generated hook name")
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or any(character not in string.hexdigits for character in digest)
            ):
                raise SystemExit("dex: invalid generated hook receipt")
    if state["installation_complete"] and "commit-msg" not in generated:
        raise SystemExit("dex: attribution state is missing the commit-msg receipt")
    return state


def atomic_write(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fingerprint(path: Path) -> dict[str, str]:
    if path.is_symlink():
        return {"type": "symlink", "target": os.readlink(path)}
    if path.is_dir():
        return {"type": "dir", "mode": f"{stat.S_IMODE(path.stat().st_mode):04o}"}
    if not path.is_file():
        return {"type": "other", "mode": f"{stat.S_IMODE(path.stat().st_mode):04o}"}
    return {
        "type": "file",
        "sha256": sha256_file(path),
        "mode": f"{stat.S_IMODE(path.stat().st_mode):04o}",
    }


def project_snapshot(repo: Path) -> dict[str, dict[str, str]]:
    paths: dict[str, dict[str, str]] = {}
    dex_dir = repo / ".dex"
    if dex_dir.exists() or dex_dir.is_symlink():
        paths[".dex"] = fingerprint(dex_dir)
        if dex_dir.is_dir() and not dex_dir.is_symlink():
            for root, dirs, files in os.walk(dex_dir, followlinks=False):
                root_path = Path(root)
                if root_path == dex_dir:
                    dirs[:] = [name for name in dirs if name not in {"git-hooks", "worktrees"}]
                for name in dirs + files:
                    path = root_path / name
                    paths[path.relative_to(repo).as_posix()] = fingerprint(path)
    github_dir = repo / ".github"
    if github_dir.exists() or github_dir.is_symlink():
        paths[".github"] = fingerprint(github_dir)
        if github_dir.is_dir() and not github_dir.is_symlink():
            template = github_dir / "pull_request_template.md"
            if template.exists() or template.is_symlink():
                paths[".github/pull_request_template.md"] = fingerprint(template)
    return paths


def valid_managed_path(relative: str) -> bool:
    path = PurePosixPath(relative)
    if relative != path.as_posix() or path.is_absolute() or ".." in path.parts:
        return False
    if path.parts == (".dex",):
        return True
    if path.parts in {
        (".github",),
        (".github", "pull_request_template.md"),
    }:
        return True
    return len(path.parts) > 1 and path.parts[0] == ".dex" and path.parts[1] not in {
        "git-hooks",
        "worktrees",
    }


def valid_fingerprint(value: object) -> bool:
    if not isinstance(value, dict) or not isinstance(value.get("type"), str):
        return False
    kind = value["type"]
    mode = value.get("mode")
    valid_mode = isinstance(mode, str) and len(mode) == 4 and all(
        character in "01234567" for character in mode
    )
    if kind in {"dir", "other"}:
        return set(value) == {"type"} or (set(value) == {"type", "mode"} and valid_mode)
    if kind == "file":
        fields = set(value)
        return (
            fields in ({"type", "sha256"}, {"type", "sha256", "mode"})
            and isinstance(value.get("sha256"), str)
            and ("mode" not in value or valid_mode)
        )
    if kind == "symlink":
        return set(value) == {"type", "target"} and isinstance(value.get("target"), str)
    return False


def has_symlinked_parent(repo: Path, path: Path) -> bool:
    current = repo
    for part in path.relative_to(repo).parts[:-1]:
        current /= part
        if current.is_symlink():
            return True
    return False


def project_begin(repo: Path, state_path: Path) -> None:
    if state_path.is_file():
        state = read_state(state_path, "project ownership")
        if not isinstance(state.get("managed"), dict):
            raise SystemExit("dex: invalid project ownership state")
    else:
        state = {"version": 1, "managed": {}}
    current = project_snapshot(repo)
    if "pre_init" not in state:
        # A receipt only covers the exact bytes from the previous successful
        # init. Once a user changes a managed path, a later init must not claim
        # the combined user and generated content as Dex-owned.
        for relative, value in current.items():
            if relative in state["managed"] and state["managed"][relative] != value:
                del state["managed"][relative]
        state["pre_init"] = current
    else:
        before = state["pre_init"]
        managed = state["managed"]
        if not isinstance(before, dict):
            raise SystemExit("dex: invalid interrupted project ownership state")
        # Files appearing or changing between attempts may have been edited by
        # the user after an interrupted init. Adopt their current bytes as the
        # new baseline unless an existing receipt proves Dex already owned them.
        for relative, value in current.items():
            if managed.get(relative) == value:
                continue
            managed.pop(relative, None)
            before[relative] = value
    atomic_write(state_path, state)


def project_finalize(repo: Path, state_path: Path) -> None:
    state = read_state(state_path, "project ownership")
    before = state.get("pre_init")
    managed = state.get("managed")
    if not isinstance(before, dict) or not isinstance(managed, dict):
        raise SystemExit("dex: invalid project ownership state")

    current = project_snapshot(repo)
    for relative, value in current.items():
        if relative not in before:
            managed[relative] = value
        elif relative in managed and before[relative] != value:
            managed[relative] = value
    for relative in list(managed):
        if relative not in current:
            del managed[relative]

    state["managed"] = managed
    state.pop("pre_init", None)
    atomic_write(state_path, state)


def project_remove(repo: Path, state_path: Path) -> None:
    state = read_state(state_path, "project ownership")
    managed = state.get("managed")
    if (
        not isinstance(managed, dict)
        or any(not valid_managed_path(path) for path in managed)
        or any(not valid_fingerprint(value) for value in managed.values())
    ):
        raise SystemExit("dex: invalid project ownership state")

    preserved = []
    removed = []
    for relative in sorted(managed, key=lambda item: (item.count("/"), item), reverse=True):
        path = repo / relative
        expected = managed[relative]
        if not path.exists() and not path.is_symlink():
            removed.append(relative)
            continue
        if has_symlinked_parent(repo, path):
            preserved.append(relative)
            continue
        try:
            path.resolve(strict=False).relative_to(repo)
        except ValueError:
            preserved.append(relative)
            continue
        if fingerprint(path) != expected:
            preserved.append(relative)
            continue
        if expected.get("type") == "dir":
            try:
                path.rmdir()
            except OSError as exc:
                if exc.errno in {errno.ENOTEMPTY, errno.EEXIST}:
                    preserved.append(relative)
                elif exc.errno == errno.ENOENT:
                    removed.append(relative)
                else:
                    raise
            else:
                removed.append(relative)
            continue
        path.unlink()
        removed.append(relative)

    for relative in removed + preserved:
        managed.pop(relative, None)
    state["managed"] = managed
    state.pop("pre_init", None)
    if managed:
        atomic_write(state_path, state)
    else:
        state_path.unlink(missing_ok=True)

    for relative in removed:
        print(f"removed\t{relative}")
    for relative in preserved:
        print(f"preserved\t{relative}")


def attribution_create(
    state_path: Path,
    config_scope: str,
    previous_config_present: str,
    previous_config_value: str,
    installed_hooks_path: str,
    original_hooks_configured: str,
    original_hooks_path: str,
) -> None:
    if config_scope not in {"local", "worktree"}:
        raise SystemExit("dex: invalid attribution config scope")
    if state_path.name == "dex-attribution-worktree-state.json":
        expected_hooks = state_path.parent / "dex-hooks-worktree"
    elif state_path.name == "dex-attribution-state.json":
        expected_hooks = state_path.parent / "dex-hooks"
    else:
        raise SystemExit("dex: attribution state path is not Dex-managed")
    if Path(os.path.abspath(installed_hooks_path)) != Path(os.path.abspath(expected_hooks)):
        raise SystemExit("dex: installed hook path must use the fixed Dex directory")
    state = {
        "version": 1,
        "config_scope": config_scope,
        "installed_hooks_path": installed_hooks_path,
        "previous_config_present": previous_config_present == "1",
        "previous_config_value": previous_config_value,
        "original_hooks_configured": original_hooks_configured == "1",
        "original_hooks_path": original_hooks_path,
        "generated_hooks": {},
        "installation_complete": False,
    }
    atomic_write(state_path, state)


def attribution_get(state_path: Path, field: str) -> None:
    state = read_attribution_state(state_path)
    value = state.get(field)
    if isinstance(value, bool):
        print("1" if value else "0")
    elif isinstance(value, str):
        print(value)
    else:
        raise SystemExit(f"dex: invalid attribution state field: {field}")


def attribution_mark_installed(state_path: Path) -> None:
    state = read_attribution_state(state_path)
    state["installation_complete"] = True
    atomic_write(state_path, state)


def attribution_set_installed_path(state_path: Path, hook_dir: Path) -> None:
    state = read_attribution_state(state_path)
    validate_hook_directory(state_path, hook_dir)
    state["installed_hooks_path"] = str(Path(os.path.abspath(hook_dir)))
    atomic_write(state_path, state)


def validate_hook_directory(state_path: Path, hook_dir: Path) -> None:
    if state_path.name == "dex-attribution-worktree-state.json":
        expected = state_path.parent / "dex-hooks-worktree"
    elif state_path.name == "dex-attribution-state.json":
        expected = state_path.parent / "dex-hooks"
    else:
        raise SystemExit("dex: attribution state path is not Dex-managed")
    if Path(os.path.abspath(hook_dir)) != Path(os.path.abspath(expected)):
        raise SystemExit("dex: hook proxy directory escaped its fixed Dex path")
    if hook_dir.is_symlink():
        raise SystemExit("dex: refusing to follow a symlinked hook proxy directory")
    if hook_dir.exists() and not hook_dir.is_dir():
        raise SystemExit("dex: hook proxy path is not a directory")


def attribution_generate(
    state_path: Path,
    hook_dir: Path,
    original_dir: Path,
    dex_dir: str,
) -> None:
    state = read_attribution_state(state_path)
    validate_hook_directory(state_path, hook_dir)
    original_hooks_path = state["original_hooks_path"]
    original_hooks_configured = state["original_hooks_configured"]
    if original_dir.resolve() == hook_dir.resolve():
        raise SystemExit("dex: hook proxy directory cannot proxy itself")
    # A shared local core.hooksPath also serves linked worktrees. Generate the
    # complete proxy set so hooks that exist only in a linked checkout still
    # run. The protocol hooks below use absence-equivalent fallbacks.
    generated = set(STANDARD_HOOKS)

    contents = {}
    for name in generated:
        lines = [
            "#!/usr/bin/env bash",
            HOOK_MARKER,
            "# Re-run 'dx init' or 'dx sync' to refresh.",
            "set -euo pipefail",
            "",
            f"original_hooks_path={shlex.quote(original_hooks_path)}",
            f"original_hooks_configured={'1' if original_hooks_configured else '0'}",
            'if [[ "$original_hooks_configured" == "1" ]]; then',
            "  original_hook_dir=$(git -c core.hooksPath=\"$original_hooks_path\" \\",
            "    rev-parse --path-format=absolute --git-path hooks 2>/dev/null)",
            "else",
            "  original_git_common_dir=$(git rev-parse --path-format=absolute \\",
            "    --git-common-dir 2>/dev/null)",
            '  original_hook_dir="$original_git_common_dir/hooks"',
            "fi",
            'proxy_hook_dir=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)',
            'original_hook_dir_resolved=""',
            'if [[ -d "$original_hook_dir" ]]; then',
            '  original_hook_dir_resolved=$(CDPATH= cd "$original_hook_dir" && pwd -P)',
            "fi",
            'original_hook_is_proxy="0"',
            'if [[ -n "$original_hook_dir_resolved" && "$original_hook_dir_resolved" == "$proxy_hook_dir" ]]; then',
            '  original_hook_is_proxy="1"',
            "fi",
            f"original_hook=\"$original_hook_dir/{name}\"",
            'if [[ "$original_hook_is_proxy" == "0" && -e "$original_hook" && "$original_hook" -ef "${BASH_SOURCE[0]}" ]]; then',
            '  original_hook_is_proxy="1"',
            "fi",
        ]
        if name == "push-to-checkout":
            lines.extend(
                [
                    'if [[ "$original_hook_is_proxy" == "0" ]] && [[ -x "$original_hook" ]]; then',
                    '  "$original_hook" "$@"',
                    "else",
                    '  git read-tree -u -m HEAD "$1"',
                    "fi",
                ]
            )
        elif name in {"fsmonitor-watchman", "fsmonitor-watchmanv2", "proc-receive"}:
            lines.extend(
                [
                    'if [[ "$original_hook_is_proxy" == "0" ]] && [[ -x "$original_hook" ]]; then',
                    '  "$original_hook" "$@"',
                    "else",
                    "  exit 1",
                    "fi",
                ]
            )
        else:
            lines.extend(
                [
                    'if [[ "$original_hook_is_proxy" == "0" ]] && [[ -x "$original_hook" ]]; then',
                    '  "$original_hook" "$@"',
                    "fi",
                ]
            )
        if name == "commit-msg":
            # Attribution is best-effort: this hook runs for every commit in
            # the repo, so a moved/deleted Dex checkout or a missing python3
            # must degrade to an unattributed commit, never block committing.
            lines.extend(
                [
                    "",
                    f"DEX_DIR={shlex.quote(dex_dir)}",
                    "export DEX_DIR",
                    "# shellcheck disable=SC1091",
                    'if [[ -r "$DEX_DIR/lib/common.sh" ]] && source "$DEX_DIR/lib/common.sh" 2>/dev/null; then',
                    '  dx_commit_attribution_message "$1" ||',
                    "    printf 'dex: commit attribution skipped\\n' >&2",
                    "else",
                    "  printf 'dex: commit attribution skipped (Dex not found at %s)\\n' \\",
                    '    "$DEX_DIR" >&2',
                    "fi",
                    "",
                    "exit 0",
                ]
            )
        else:
            lines.extend(["", "exit 0"])
        contents[name] = "\n".join(lines) + "\n"

    hook_dir.mkdir(parents=True, exist_ok=True)
    receipts = {
        name: hashlib.sha256(content.encode("utf-8")).hexdigest()
        for name, content in contents.items()
    }
    prior_hooks = state["generated_hooks"]
    pending_hooks = state.get("pending_generated_hooks")
    if pending_hooks is not None and pending_hooks != receipts:
        raise SystemExit(
            "dex: an interrupted hook refresh must finish before upgrading again"
        )
    accepted_hooks: dict[str, set[str]] = {}
    for receipt_set in (prior_hooks, pending_hooks or {}):
        for name, receipt in receipt_set.items():
            accepted_hooks.setdefault(name, set()).add(receipt)
    for name, accepted_receipts in accepted_hooks.items():
        destination = hook_dir / name
        if not destination.exists() and not destination.is_symlink():
            continue
        if destination.is_symlink() or not destination.is_file():
            raise SystemExit(f"dex: refusing to replace modified hook: {destination}")
        if (
            stat.S_IMODE(destination.stat().st_mode) != 0o755
            or sha256_file(destination) not in accepted_receipts
        ):
            raise SystemExit(f"dex: refusing to replace modified hook: {destination}")
    for name in generated - accepted_hooks.keys():
        destination = hook_dir / name
        if destination.exists() or destination.is_symlink():
            raise SystemExit(f"dex: refusing to overwrite user hook: {destination}")

    if pending_hooks is None:
        # Keep the previous receipts while a refresh is in flight. A retry or
        # uninit can then recognize either side of a partially completed batch.
        state["pending_generated_hooks"] = receipts
        atomic_write(state_path, state)

    for name in prior_hooks.keys() - generated:
        (hook_dir / name).unlink(missing_ok=True)
    for name in sorted(generated):
        destination = hook_dir / name
        descriptor, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=hook_dir)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(contents[name])
            os.chmod(temporary, 0o755)
            os.replace(temporary, destination)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    state["generated_hooks"] = receipts
    state.pop("pending_generated_hooks", None)
    atomic_write(state_path, state)


def attribution_cleanup(state_path: Path, hook_dir: Path) -> None:
    state = read_attribution_state(state_path)
    validate_hook_directory(state_path, hook_dir)
    accepted_hooks: dict[str, set[str]] = {}
    for receipt_set in (
        state["generated_hooks"],
        state.get("pending_generated_hooks", {}),
    ):
        for name, receipt in receipt_set.items():
            accepted_hooks.setdefault(name, set()).add(receipt)
    for name, accepted_receipts in accepted_hooks.items():
        path = hook_dir / name
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink() or not path.is_file():
            print(path)
            continue
        if (
            stat.S_IMODE(path.stat().st_mode) != 0o755
            or sha256_file(path) not in accepted_receipts
        ):
            print(path)
            continue
        path.unlink()
    try:
        hook_dir.rmdir()
    except OSError:
        pass


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: project-state.py <command> [arguments]")
    command = sys.argv[1]
    arguments = sys.argv[2:]
    if command == "project-begin" and len(arguments) == 2:
        project_begin(Path(arguments[0]).resolve(), Path(arguments[1]))
    elif command == "project-finalize" and len(arguments) == 2:
        project_finalize(Path(arguments[0]).resolve(), Path(arguments[1]))
    elif command == "project-remove" and len(arguments) == 2:
        project_remove(Path(arguments[0]).resolve(), Path(arguments[1]))
    elif command == "attribution-create" and len(arguments) == 7:
        attribution_create(Path(arguments[0]), *arguments[1:])
    elif command == "attribution-get" and len(arguments) == 2:
        attribution_get(Path(arguments[0]), arguments[1])
    elif command == "attribution-validate" and len(arguments) == 1:
        read_attribution_state(Path(arguments[0]))
    elif command == "attribution-mark-installed" and len(arguments) == 1:
        attribution_mark_installed(Path(arguments[0]))
    elif command == "attribution-set-installed-path" and len(arguments) == 2:
        attribution_set_installed_path(Path(arguments[0]), Path(arguments[1]))
    elif command == "attribution-generate" and len(arguments) == 4:
        attribution_generate(Path(arguments[0]), Path(arguments[1]), Path(arguments[2]), arguments[3])
    elif command == "attribution-cleanup" and len(arguments) == 2:
        attribution_cleanup(Path(arguments[0]), Path(arguments[1]))
    else:
        raise SystemExit(f"dex: invalid project-state command or arguments: {command}")


if __name__ == "__main__":
    main()
