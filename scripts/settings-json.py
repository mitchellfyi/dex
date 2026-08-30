#!/usr/bin/env python3
"""Transform Claude settings and Dex install-state JSON."""

import copy
import json
import os
import re
import sys


DEFAULT_DEX_DIR = "$HOME/work/dex"
HOOK_NAMES = (
    "load-ticket-context.sh",
    "user-prompt-submit.sh",
    "guard-handler.py",
    "rtk-claude-hook.sh",
    "post-commit-guard.sh",
    "phase-loop.sh",
    "stop-sound.sh",
    "pre-compact.sh",
    "session-end.sh",
)
LEGACY_HOOK_PATTERN = re.compile(
    r'(^|[\s"])[^\s"]*/dex(?:-cli)?/hooks/(?:'
    + "|".join(re.escape(name) for name in HOOK_NAMES)
    + r')([\s"]|$)'
)


def load_object(path):
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def emit(value, compact=False):
    options = {"ensure_ascii": False}
    if compact:
        options["separators"] = (",", ":")
    else:
        options["indent"] = 2
    print(json.dumps(value, **options))


def replace_strings(value, old, new):
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_strings(item, old, new) for item in value]
    if isinstance(value, dict):
        return {key: replace_strings(item, old, new) for key, item in value.items()}
    return value


def customized_template(path, dex_dir):
    return replace_strings(load_object(path), DEFAULT_DEX_DIR, dex_dir)


def worktree_dirs(settings):
    worktree = settings.get("worktree")
    if not isinstance(worktree, dict):
        return []
    directories = worktree.get("symlinkDirectories", [])
    return directories if isinstance(directories, list) else []


def is_dex_command(command, dex_dir, home):
    if not isinstance(command, str):
        return False
    markers = (
        f"{dex_dir}/hooks/",
        f"{home}/work/dex/hooks/",
        "$HOME/work/dex/hooks/",
        "$DEX_DIR/hooks/",
    )
    return (
        any(marker in command for marker in markers)
        or ("export DEX_DIR=" in command and "/hooks/" in command)
        or bool(LEGACY_HOOK_PATTERN.search(command))
    )


def has_dex_hooks(settings, dex_dir, home):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            commands = group.get("hooks") if isinstance(group, dict) else None
            if not isinstance(commands, list):
                continue
            if any(
                isinstance(hook, dict) and is_dex_command(hook.get("command"), dex_dir, home)
                for hook in commands
            ):
                return True
    return False


def required_settings_complete(settings, template):
    hooks = settings.get("hooks")
    template_hooks = template.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(template_hooks, dict):
        return False

    for event, required_groups in template_hooks.items():
        installed_groups = hooks.get(event)
        if not isinstance(required_groups, list) or not isinstance(installed_groups, list):
            return False

        unmatched = copy.deepcopy(installed_groups)
        for required_group in required_groups:
            try:
                unmatched.remove(required_group)
            except ValueError:
                return False

    installed_dirs = worktree_dirs(settings)
    return all(directory in installed_dirs for directory in worktree_dirs(template))


def filtered_groups(groups, dex_dir, home):
    retained = []
    for group in groups:
        commands = group.get("hooks") if isinstance(group, dict) else None
        if not isinstance(commands, list):
            retained.append(copy.deepcopy(group))
            continue
        filtered = [
            hook
            for hook in commands
            if not (
                isinstance(hook, dict)
                and is_dex_command(hook.get("command"), dex_dir, home)
            )
        ]
        if filtered:
            updated = copy.deepcopy(group)
            updated["hooks"] = filtered
            retained.append(updated)
    return retained


def deep_merge(left, right):
    merged = copy.deepcopy(left) if isinstance(left, dict) else {}
    for key, value in (right if isinstance(right, dict) else {}).items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def append_unique(base, additions):
    result = copy.deepcopy(base)
    for item in additions:
        if item not in result:
            result.append(copy.deepcopy(item))
    return result


def unordered_equal(left, right):
    if len(left) != len(right):
        return False
    unmatched = copy.deepcopy(right)
    for item in left:
        try:
            unmatched.remove(item)
        except ValueError:
            return False
    return not unmatched


def merge_settings(existing, template, dex_dir, home):
    # Only these two keys have merge rules. A third one added to the template
    # would otherwise install as a silent no-op, and the failure would surface
    # much later as a setting that simply never took effect.
    unhandled = sorted(set(template) - {"hooks", "worktree"})
    if unhandled:
        raise ValueError(
            "settings template has keys with no merge rule: " + ", ".join(unhandled)
        )

    result = copy.deepcopy(existing)
    existing_hooks = existing.get("hooks")
    merged_hooks = copy.deepcopy(existing_hooks) if isinstance(existing_hooks, dict) else {}
    template_hooks = template.get("hooks", {})
    if not isinstance(template_hooks, dict):
        raise ValueError("settings template hooks must be an object")
    for event, template_groups in template_hooks.items():
        if not isinstance(template_groups, list):
            raise ValueError(f"settings template hook event {event!r} must be an array")
        existing_groups = merged_hooks.get(event, [])
        retained = filtered_groups(existing_groups, dex_dir, home) if isinstance(existing_groups, list) else []
        if event == "PreToolUse":
            # Dex's guards must evaluate before any retained user hook: a user
            # hook that rewrites or approves the call must not run ahead of
            # the guard that would have flagged it. Other events keep user
            # hooks first.
            merged_hooks[event] = copy.deepcopy(template_groups) + retained
        else:
            merged_hooks[event] = retained + copy.deepcopy(template_groups)
    result["hooks"] = merged_hooks

    existing_worktree = existing.get("worktree")
    template_worktree = template.get("worktree")
    existing_worktree = existing_worktree if isinstance(existing_worktree, dict) else {}
    template_worktree = template_worktree if isinstance(template_worktree, dict) else {}
    merged_worktree = deep_merge(existing_worktree, template_worktree)
    if (
        existing_worktree.get("symlinkDirectories") is not None
        or template_worktree.get("symlinkDirectories") is not None
    ):
        merged_worktree["symlinkDirectories"] = append_unique(
            worktree_dirs(existing), worktree_dirs(template)
        )
    result["worktree"] = merged_worktree
    return result


def remove_dex_hooks(settings, dex_dir, home):
    result = copy.deepcopy(settings)
    hooks = result.get("hooks")
    if not isinstance(hooks, dict):
        return result
    retained_events = {}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            retained_events[event] = groups
            continue
        retained = filtered_groups(groups, dex_dir, home)
        if retained:
            retained_events[event] = retained
    if retained_events:
        result["hooks"] = retained_events
    else:
        result.pop("hooks", None)
    return result


def command_render_template(template_path, dex_dir):
    emit(customized_template(template_path, dex_dir))


def command_template_dirs(template_path):
    emit(worktree_dirs(load_object(template_path)), compact=True)


def command_managed_dirs(existing_path, template_path, dex_dir, home):
    existing = load_object(existing_path)
    template = customized_template(template_path, dex_dir)
    existing_dirs = worktree_dirs(existing)
    template_dirs = worktree_dirs(template)
    if has_dex_hooks(existing, dex_dir, home) and (
        unordered_equal(existing_dirs, template_dirs)
        or all(directory in existing_dirs for directory in template_dirs)
    ):
        managed = template_dirs
    else:
        managed = [directory for directory in template_dirs if directory not in existing_dirs]
    emit(managed, compact=True)


def command_merge_settings(existing_path, template_path, dex_dir, home):
    existing = load_object(existing_path)
    template = customized_template(template_path, dex_dir)
    emit(merge_settings(existing, template, dex_dir, home))


def command_merge_state(state_path, directories_json):
    directories = json.loads(directories_json)
    if not isinstance(directories, list):
        raise ValueError("managed worktree directories must be an array")
    state = load_object(state_path) if os.path.isfile(state_path) else {}
    worktree = state.get("worktree")
    if worktree is None:
        worktree = {}
        state["worktree"] = worktree
    if not isinstance(worktree, dict):
        raise ValueError("install-state worktree must be an object")
    managed = worktree.get("managedSymlinkDirectories", [])
    if not isinstance(managed, list):
        raise ValueError("managedSymlinkDirectories must be an array")
    worktree["managedSymlinkDirectories"] = append_unique(managed, directories)
    emit(state)


def command_has_hooks(settings_path, dex_dir, home):
    settings = load_object(settings_path)
    return 0 if has_dex_hooks(settings, dex_dir, home) else 1


def command_settings_complete(settings_path, template_path, dex_dir, home):
    settings = load_object(settings_path)
    template = customized_template(template_path, dex_dir)
    return 0 if required_settings_complete(settings, template) else 1


def command_remove_hooks(settings_path, dex_dir, home):
    emit(remove_dex_hooks(load_object(settings_path), dex_dir, home))


def command_state_dirs(state_path):
    state = load_object(state_path)
    worktree = state.get("worktree", {})
    if not isinstance(worktree, dict):
        raise ValueError("install-state worktree must be an object")
    directories = worktree.get("managedSymlinkDirectories", [])
    if not isinstance(directories, list):
        raise ValueError("managedSymlinkDirectories must be an array")
    emit(directories, compact=True)


def command_remove_dirs(settings_path, directories_json):
    settings = load_object(settings_path)
    managed = json.loads(directories_json)
    if not isinstance(managed, list):
        raise ValueError("managed worktree directories must be an array")
    worktree = settings.get("worktree")
    if isinstance(worktree, dict):
        directories = worktree.get("symlinkDirectories")
        if isinstance(directories, list):
            retained = [directory for directory in directories if directory not in managed]
            if retained:
                worktree["symlinkDirectories"] = retained
            else:
                worktree.pop("symlinkDirectories", None)
        if not worktree:
            settings.pop("worktree", None)
    emit(settings)


COMMANDS = {
    "render-template": (2, command_render_template),
    "template-dirs": (1, command_template_dirs),
    "managed-dirs-added": (4, command_managed_dirs),
    "merge-settings": (4, command_merge_settings),
    "merge-install-state": (2, command_merge_state),
    "has-dex-hooks": (3, command_has_hooks),
    "settings-complete": (4, command_settings_complete),
    "remove-dex-hooks": (3, command_remove_hooks),
    "state-dirs": (1, command_state_dirs),
    "remove-worktree-dirs": (2, command_remove_dirs),
}


def main(arguments):
    if not arguments or arguments[0] not in COMMANDS:
        print("usage: settings-json.py <command> [arguments ...]", file=sys.stderr)
        print("commands: " + ", ".join(COMMANDS), file=sys.stderr)
        return 2
    command, command_arguments = arguments[0], arguments[1:]
    expected, handler = COMMANDS[command]
    if len(command_arguments) != expected:
        print(f"settings-json: {command} expects {expected} arguments", file=sys.stderr)
        return 2
    try:
        status = handler(*command_arguments)
        return status if status is not None else 0
    except (OSError, TypeError, ValueError) as error:
        print(f"settings-json: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
