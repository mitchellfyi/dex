# shellcheck shell=bash
# Dex shared library — session ID and state file helpers
#
# Session IDs key all state and loop files. Path-based derivation makes them
# stable across branch renames (the SessionStart hook may rename branches to
# follow project conventions). See: docs/autonomous-mode.md § State Management
#
# Scope: state/loop dirs are global (~/.claude/.dex-{phases,loops}/), so
# session IDs include a repo-stable key plus the worktree/branch identifier.
# This prevents two repos using the same ticket, task, or branch name from
# sharing phase, provider, watcher, or loop state.
#
# Concurrency: dx_unique_session_id() appends PID+epoch to avoid collisions
# when multiple dxloop invocations run on the same branch. The unique ID is
# passed to Claude via DEX_SESSION_ID env var so the stop hook resolves
# to the same unique ID (see the SESSION_ID bootstrap in hooks/phase-loop.sh).

# __dx_session_canonical_git_dir <git-dir|git-common-dir>
# Resolve Git's administrative path without depending on the spelling of the
# checkout path. Linked worktrees need the common directory to share state.
__dx_session_canonical_git_dir() {
  local mode="${1:-}" option raw_dir
  case "$mode" in
    git-dir) option="--absolute-git-dir" ;;
    git-common-dir) option="--git-common-dir" ;;
    *) return 1 ;;
  esac

  if ! raw_dir=$(git rev-parse --path-format=absolute "$option" 2>/dev/null); then
    raw_dir=$(git rev-parse "$option" 2>/dev/null) || return 1
    case "$raw_dir" in
      /*) ;;
      *) raw_dir="${PWD:-.}/$raw_dir" ;;
    esac
  fi
  [[ -d "$raw_dir" ]] || return 1
  (cd "$raw_dir" 2>/dev/null && pwd -P)
}

__dx_session_canonical_toplevel() {
  local raw_root
  if ! raw_root=$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null); then
    raw_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  fi
  [[ -d "$raw_root" ]] || return 1
  (cd "$raw_root" 2>/dev/null && pwd -P)
}

# dx_session_repo_root
# Print the canonical main-worktree root for the current repository. A linked
# worktree outside Dex's directory still resolves to the checkout that owns its
# common Git directory.
dx_session_repo_root() {
  local common_dir git_dir current_root candidate_root candidate_common configured_root listed_root inside_worktree
  common_dir=$(__dx_session_canonical_git_dir git-common-dir) || return 1

  if [[ "${common_dir##*/}" == ".git" ]]; then
    candidate_root="${common_dir%/.git}"
    if candidate_common=$(cd "$candidate_root" 2>/dev/null \
      && __dx_session_canonical_git_dir git-common-dir); then
      if [[ "$candidate_common" == "$common_dir" ]]; then
        (cd "$candidate_root" 2>/dev/null && pwd -P)
        return
      fi
    fi
  fi

  if git_dir=$(__dx_session_canonical_git_dir git-dir) \
    && current_root=$(__dx_session_canonical_toplevel) \
    && [[ "$git_dir" == "$common_dir" ]]; then
    printf '%s\n' "$current_root"
    return
  fi

  if ! configured_root=$(git config --path --get core.worktree 2>/dev/null); then
    configured_root=""
  fi
  if [[ -n "$configured_root" && -d "$configured_root" ]]; then
    candidate_root=$(cd "$configured_root" 2>/dev/null && pwd -P) || return 1
    candidate_common=$(cd "$candidate_root" 2>/dev/null \
      && __dx_session_canonical_git_dir git-common-dir) || return 1
    if [[ "$candidate_common" == "$common_dir" ]]; then
      printf '%s\n' "$candidate_root"
      return
    fi
  fi

  listed_root=$(git worktree list --porcelain 2>/dev/null \
    | awk 'NR == 1 && /^worktree / { sub(/^worktree /, ""); print; exit }') || return 1
  [[ -n "$listed_root" && -d "$listed_root" ]] || return 1
  candidate_root=$(cd "$listed_root" 2>/dev/null && pwd -P) || return 1
  inside_worktree=$(git -C "$candidate_root" rev-parse --is-inside-work-tree 2>/dev/null) || return 1
  [[ "$inside_worktree" == "true" ]] || return 1
  candidate_common=$(cd "$candidate_root" 2>/dev/null \
    && __dx_session_canonical_git_dir git-common-dir) || return 1
  [[ "$candidate_common" == "$common_dir" ]] || return 1
  printf '%s\n' "$candidate_root"
}

# dx_session_repo_key
# Derive a filesystem-safe key from the canonical common Git directory. Normal
# repositories retain their established root-based digest, while alternate Git
# directory layouts use the common directory itself as the stable identity.
dx_session_repo_key() {
  local common_dir repo_root repo_identity name slug hash
  if common_dir=$(__dx_session_canonical_git_dir git-common-dir); then
    if ! repo_root=$(dx_session_repo_root); then
      repo_root=""
    fi
    if [[ -n "$repo_root" && "$common_dir" == "$repo_root/.git" ]]; then
      repo_identity="$repo_root"
    else
      repo_identity="$common_dir"
    fi
  else
    if ! repo_root=$(__dx_session_canonical_toplevel); then
      repo_root=$(cd "${PWD:-.}" 2>/dev/null && pwd -P) || repo_root="${PWD:-unknown}"
    fi
    repo_identity="$repo_root"
  fi

  if [[ -n "$repo_root" ]]; then
    name=$(basename "$repo_root")
  else
    name=$(basename "$repo_identity")
  fi
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  [[ -n "$slug" ]] || slug="repo"

  hash=""
  if command -v cksum >/dev/null 2>&1; then
    hash=$(printf '%s' "$repo_identity" | cksum 2>/dev/null | awk '{print $1}') || hash=""
  fi
  [[ -n "$hash" ]] || hash="nohash"

  printf 'repo-%s-%s\n' "$slug" "$hash"
}

# dx_scoped_session_id <raw_id>
# Add the current repo namespace to a raw worktree/branch/session identifier.
dx_scoped_session_id() {
  local raw_id="$1"
  printf '%s-%s\n' "$(dx_session_repo_key)" "$raw_id"
}

# __dx_session_dex_worktree_name <toplevel> <common_dir>
# Print the directory name only when the checkout is a direct Dex worktree of
# the repository that owns the common Git directory.
__dx_session_dex_worktree_name() {
  local worktree_root="$1" common_dir="$2" parent_dir candidate_root candidate_common
  parent_dir=$(dirname "$worktree_root")
  case "$parent_dir" in
    */.dex/worktrees) ;;
    *) return 1 ;;
  esac

  candidate_root="${parent_dir%/.dex/worktrees}"
  [[ -n "$candidate_root" && -d "$candidate_root" ]] || return 1
  candidate_common=$(cd "$candidate_root" 2>/dev/null \
    && __dx_session_canonical_git_dir git-common-dir) || return 1
  [[ "$candidate_common" == "$common_dir" ]] || return 1
  basename "$worktree_root"
}

# dx_session_id [wt_name]
# Derive a stable session identifier used to key state and loop files.
#
# With argument:  "repo-<name>-<hash>-worktree-<wt_name>" — used by dx.sh
# which knows the name.
# Without argument: auto-detect from the current git directory:
#   - If inside a linked worktree, derive from its registered Git identity.
#     Dex-managed worktrees retain the worktree directory name used by dx.sh.
#   - Otherwise, fall back to a readable branch slug plus a digest of the exact
#     branch name, so names such as feature/foo and feature-foo cannot collide.
# shellcheck disable=SC2120  # Intentionally dual-mode: called with args from dx.sh, without from hooks
dx_session_id() {
  local raw_id scoped_id toplevel git_dir common_dir worktree_name worktree_slug worktree_hash
  if [[ $# -ge 1 ]]; then
    raw_id="worktree-${1}"
    scoped_id=$(dx_scoped_session_id "$raw_id")
    printf '%s\n' "$scoped_id"
    return
  fi
  if ! toplevel=$(__dx_session_canonical_toplevel); then
    toplevel=""
  fi
  if git_dir=$(__dx_session_canonical_git_dir git-dir) \
    && common_dir=$(__dx_session_canonical_git_dir git-common-dir) \
    && [[ "$git_dir" != "$common_dir" ]]; then
    if worktree_name=$(__dx_session_dex_worktree_name "$toplevel" "$common_dir"); then
      raw_id="worktree-${worktree_name}"
    else
      worktree_name=$(basename "$git_dir")
      worktree_slug=$(printf '%s' "$worktree_name" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
      [[ -n "$worktree_slug" ]] || worktree_slug="worktree"
      if [[ "$worktree_slug" != "$worktree_name" || ${#worktree_slug} -gt 64 ]]; then
        worktree_hash=$(printf '%s' "$worktree_name" | cksum 2>/dev/null | awk '{print $1}') || worktree_hash=""
        [[ -n "$worktree_hash" ]] || worktree_hash="nohash"
        worktree_slug="$(printf '%.64s' "$worktree_slug")-${worktree_hash}"
      fi
      raw_id="worktree-${worktree_slug}"
    fi
  else
    local branch branch_slug branch_hash
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$branch" ]]; then
      branch="detached-$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
    fi
    branch_slug=$(printf '%s' "$branch" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [[ -n "$branch_slug" ]] || branch_slug="branch"
    branch_slug=$(printf '%.64s' "$branch_slug")
    branch_hash=$(printf '%s' "$branch" | cksum 2>/dev/null | awk '{print $1}') || branch_hash=""
    [[ -n "$branch_hash" ]] || branch_hash="nohash"
    raw_id="branch-${branch_slug}-${branch_hash}"
  fi
  scoped_id=$(dx_scoped_session_id "$raw_id")
  printf '%s\n' "$scoped_id"
}

# dx_unique_session_id
# Generate a session ID unique to this shell invocation, for concurrent dxloop isolation.
# Appends PID, epoch seconds, and $RANDOM to the branch-based ID so multiple dxloop
# calls on the same branch get distinct state/prompt files — even if started in the
# same second ($RANDOM provides 0-32767 range, available in both bash and zsh).
dx_unique_session_id() {
  echo "$(dx_session_id)-$$-$(date +%s)-${RANDOM}"
}

# dx_session_id_valid <session_id> — reject traversal and unsafe state keys
dx_session_id_valid() {
  local session_id="${1:-}"
  [[ -n "$session_id" && ${#session_id} -le 180 ]] || return 1
  [[ "$session_id" != "." && "$session_id" != ".." ]] || return 1
  [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# dx_state_file <session_id>  — phase state file path
dx_state_file() { echo "${DX_STATE_DIR}/${1}.phase"; }

# dx_times_file <session_id>  — phase timing file path
dx_times_file() { echo "${DX_STATE_DIR}/${1}.times"; }

# dx_session_phase_start_epoch <session_id> <phase> — latest phase start time.
dx_session_phase_start_epoch() {
  local session_id="$1" phase="$2" times_file
  dx_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  times_file=$(dx_times_file "$session_id")
  if [[ -f "$times_file" ]]; then
    awk -F: -v phase="$phase" \
      '$1 == phase { started=$2 } END { if (started != "") print started }' \
      "$times_file"
  fi
}

# dx_loop_file <session_id>   — loop iteration state file path
dx_loop_file() { echo "${DX_LOOP_DIR}/${1}.state"; }

# dx_complete_file <session_id> — loop completion signal file path
dx_complete_file() { echo "${DX_LOOP_DIR}/${1}.complete"; }

# dx_active_file <session_id>  — loop activation signal file path (for in-session /dxloop)
dx_active_file() { echo "${DX_LOOP_DIR}/${1}.active"; }

# A cleanup journal is a durable transition brake owned by its parent session.
dx_session_cleanup_journal_file() {
  dx_session_id_valid "${1:-}" || return 2
  printf '%s/%s.cleanup-journal\n' "$DX_LOOP_DIR" "$1"
}

# Return 0 for a trusted versioned marker, 1 when absent, and 2 when unsafe.
# Full transaction validation stays in session-management; lifecycle writers
# only need a fail-closed marker they can check while holding the same lock.
dx_session_cleanup_journal_state() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" journal_file journal_raw journal_header journal_rc=0
  journal_file=$(dx_session_cleanup_journal_file "$session_id") || return 2
  journal_raw=$(dx_session_trusted_file_read "$journal_file" 1048576 \
    2>/dev/null) || journal_rc=$?
  [[ "$journal_rc" -eq 0 ]] || return "$journal_rc"
  journal_header="${journal_raw%%$'\n'*}"
  [[ "$journal_raw" != "$journal_header" ]] || return 2
  [[ "$journal_header" == "dex-cleanup-journal-v1"$'\t'"$session_id" ]]
}

# Startup and destructive cleanup serialize on a private per-session claim.
# The claim lives below a directory the catalog does not scan, so holding it
# cannot manufacture or change a lifecycle record.
dx_session_claim_root() {
  printf '%s/.session-claims\n' "$DX_LOOP_DIR"
}

dx_session_claim_lock_dir() {
  dx_session_id_valid "${1:-}" || return 2
  printf '%s/%s.lock\n' "$(dx_session_claim_root)" "$1"
}

# Perform one claim transaction below descriptors opened with O_NOFOLLOW.
# The token arrives on fd 3: it never appears in argv, the environment, or
# command output. Successful acquire/inspect operations print only inode
# bindings for the shell to retain.
__dx_session_claim_filesystem() { # <operation> <sid> <pid> <binding|->
  [[ $# -eq 4 ]] || return 2
  local claim_operation="$1" session_id="$2" owner_pid="$3"
  local expected_binding="$4"
  command env -u DX_SESSION_CLAIM_TOKEN python3 - "$claim_operation" \
    "$DX_LOOP_DIR" "$session_id" "$owner_pid" "$expected_binding" \
    3<&0 <<'PY' 2>/dev/null
import errno
import fcntl
import hashlib
import os
import re
import stat
import sys
import time


class ClaimFailure(Exception):
    def __init__(self, result):
        self.result = result


def reject(result=2):
    raise ClaimFailure(result)


def inode(metadata):
    return metadata.st_dev, metadata.st_ino


def snapshot(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def directory_ok(metadata, expected_mode=None):
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        return False
    return expected_mode is None or stat.S_IMODE(metadata.st_mode) == expected_mode


def regular_owner_ok(metadata):
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.geteuid()
        and stat.S_IMODE(metadata.st_mode) == 0o600
        and metadata.st_nlink == 1
        and 1 <= metadata.st_size <= 512
    )


def open_directory(parent_fd, name, expected_mode):
    try:
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        reject()
    if not directory_ok(named, expected_mode):
        reject()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_fd)
        opened = os.fstat(descriptor)
    except OSError:
        reject()
    if not directory_ok(opened, expected_mode) or inode(opened) != inode(named):
        os.close(descriptor)
        reject()
    return descriptor


def named_directory_is(parent_fd, name, descriptor, expected_mode):
    try:
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(descriptor)
    except OSError:
        return False
    return (
        directory_ok(named, expected_mode)
        and directory_ok(opened, expected_mode)
        and inode(named) == inode(opened)
    )


def read_token():
    chunks = []
    total = 0
    while total <= 512:
        part = os.read(3, 513 - total)
        if not part:
            break
        chunks.append(part)
        total += len(part)
    raw = b"".join(chunks)
    if len(raw) > 512 or raw.count(b"\n") != 1 or not raw.endswith(b"\n"):
        reject()
    try:
        value = raw[:-1].decode("ascii")
    except UnicodeDecodeError:
        reject()
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,256}", value):
        reject()
    return value


def parse_binding(raw):
    fields = raw.split(":")
    if len(fields) != 6 or any(not item.isdigit() for item in fields):
        reject()
    return tuple(int(item) for item in fields)


def process_is_live(raw_pid):
    try:
        os.kill(int(raw_pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def named_owner_record(parent_fd, owner_name):
    try:
        named = os.stat(owner_name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        reject()
    if not regular_owner_ok(named):
        reject()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = -1
    try:
        descriptor = os.open(owner_name, flags, dir_fd=parent_fd)
        opened = os.fstat(descriptor)
        if not regular_owner_ok(opened) or snapshot(opened) != snapshot(named):
            reject()
        payload = b""
        while len(payload) <= 512:
            part = os.read(descriptor, 513 - len(payload))
            if not part:
                break
            payload += part
        after = os.fstat(descriptor)
        current = os.stat(owner_name, dir_fd=parent_fd, follow_symlinks=False)
    except ClaimFailure:
        raise
    except OSError:
        reject()
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        len(payload) > 512
        or snapshot(after) != snapshot(opened)
        or snapshot(current) != snapshot(opened)
    ):
        reject()
    if payload.count(b"\n") != 1 or not payload.endswith(b"\n"):
        reject()
    try:
        fields = payload[:-1].decode("ascii").split("\t")
    except UnicodeDecodeError:
        reject()
    if (
        len(fields) != 3
        or not re.fullmatch(r"[0-9]+", fields[0])
        or not re.fullmatch(r"[1-9][0-9]*", fields[1])
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,256}", fields[2])
    ):
        reject()
    return opened, fields, payload


def owner_record(leaf_fd, owner_name="owner"):
    try:
        if sorted(os.listdir(leaf_fd)) != [owner_name]:
            reject()
    except ClaimFailure:
        raise
    except OSError:
        reject()
    return named_owner_record(leaf_fd, owner_name)


def publish_owner(leaf_fd, raw_pid, token, payload=None):
    if payload is None:
        payload = f"{int(time.time())}\t{raw_pid}\t{token}\n".encode("ascii")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open("owner", flags, 0o600, dir_fd=leaf_fd)
        os.fchmod(descriptor, 0o600)
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                reject()
            written += count
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if not regular_owner_ok(metadata) or metadata.st_size != len(payload):
            reject()
    except ClaimFailure:
        raise
    except OSError:
        reject()
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    verified, fields, verified_payload = owner_record(leaf_fd)
    if verified_payload != payload or fields[1] != raw_pid or fields[2] != token:
        reject()
    return verified


def binding_text(root_metadata, leaf_metadata, owner_metadata):
    values = inode(root_metadata) + inode(leaf_metadata) + inode(owner_metadata)
    return ":".join(str(item) for item in values)


def release_prefix(session_id):
    session_hash = hashlib.sha256(session_id.encode("ascii")).hexdigest()[:24]
    return f".claim-release-{session_hash}-"


def release_staging_name(
    session_id, root_metadata, leaf_metadata, owner_metadata, owner_payload
):
    binding = (
        inode(root_metadata) + inode(leaf_metadata) + inode(owner_metadata)
    )
    return release_staging_name_from_binding(session_id, binding, owner_payload)


def release_staging_name_from_binding(session_id, binding, owner_payload):
    binding_text_value = ":".join(str(item) for item in binding)
    attestation = hashlib.sha256(
        b"dex-claim-release-v1\0"
        + session_id.encode("ascii")
        + b"\0"
        + binding_text_value.encode("ascii")
        + b"\0"
        + owner_payload
    ).hexdigest()
    numbers = "-".join(str(item) for item in binding)
    return f"{release_prefix(session_id)}{numbers}-{attestation}"


def retire_release_staging(root_fd, root_metadata, session_id, expected_name=None):
    prefix = release_prefix(session_id)
    try:
        candidates = sorted(name for name in os.listdir(root_fd) if name.startswith(prefix))
    except OSError:
        reject()
    if not candidates:
        if expected_name is None:
            return False
        reject(1)
    if len(candidates) != 1:
        reject()
    staging_name = candidates[0]
    if expected_name is not None and staging_name != expected_name:
        reject()
    try:
        os.stat(f"{session_id}.lock", dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    except OSError:
        reject()
    else:
        reject()
    suffix = staging_name[len(prefix):]
    parts = suffix.split("-")
    if len(parts) != 7 or any(not item.isdigit() for item in parts[:6]):
        reject()
    if not re.fullmatch(r"[0-9a-f]{64}", parts[6]):
        reject()
    binding = tuple(int(item) for item in parts[:6])
    if inode(root_metadata) != binding[:2]:
        reject()
    staged_owner, _, staged_payload = named_owner_record(root_fd, staging_name)
    if inode(staged_owner) != binding[4:6]:
        reject()
    calculated = release_staging_name_from_binding(
        session_id, binding, staged_payload
    )
    if calculated != staging_name:
        reject()
    current = os.stat(staging_name, dir_fd=root_fd, follow_symlinks=False)
    if snapshot(current) != snapshot(staged_owner):
        reject()
    try:
        os.unlink(staging_name, dir_fd=root_fd)
    except OSError:
        reject(1)
    try:
        os.stat(staging_name, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    except OSError:
        reject(1)
    reject(1)


def main():
    if len(sys.argv) != 6:
        reject()
    operation, loop_dir, session_id, raw_pid, raw_binding = sys.argv[1:]
    if operation not in {
        "acquire",
        "inspect",
        "release-detach",
        "release-finish",
        "release-restore",
        "release-retire",
    }:
        reject()
    if not re.fullmatch(r"[A-Za-z0-9._-]+", session_id):
        reject()
    if not re.fullmatch(r"[1-9][0-9]*", raw_pid):
        reject()
    token = read_token()
    expected = (
        None
        if operation in {"acquire", "release-retire"}
        else parse_binding(raw_binding)
    )

    try:
        os.makedirs(loop_dir, mode=0o700, exist_ok=True)
        loop_named = os.lstat(loop_dir)
    except OSError:
        reject()
    if not directory_ok(loop_named):
        reject()
    loop_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    loop_flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        loop_fd = os.open(loop_dir, loop_flags)
    except OSError:
        reject()
    root_fd = -1
    leaf_fd = -1
    try:
        loop_opened = os.fstat(loop_fd)
        if not directory_ok(loop_opened) or inode(loop_opened) != inode(loop_named):
            reject()
        root_name = ".session-claims"
        try:
            os.mkdir(root_name, 0o700, dir_fd=loop_fd)
            root_created = True
        except FileExistsError:
            root_created = False
        except OSError:
            reject()
        root_fd = open_directory(loop_fd, root_name, 0o700)
        if root_created:
            try:
                os.fchmod(root_fd, 0o700)
            except OSError:
                reject()
        if not named_directory_is(loop_fd, root_name, root_fd, 0o700):
            reject()
        try:
            lock_flags = fcntl.LOCK_EX
            if operation == "acquire":
                lock_flags |= fcntl.LOCK_NB
            fcntl.flock(root_fd, lock_flags)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN):
                reject(1)
            reject()
        if inode(os.lstat(loop_dir)) != inode(os.fstat(loop_fd)):
            reject()
        if not named_directory_is(loop_fd, root_name, root_fd, 0o700):
            reject()
        root_metadata = os.fstat(root_fd)
        if expected is not None and inode(root_metadata) != expected[:2]:
            reject()

        if operation == "release-retire":
            retire_release_staging(
                root_fd, root_metadata, session_id, expected_name=raw_binding
            )
            return
        if operation == "acquire":
            retire_release_staging(root_fd, root_metadata, session_id)

        leaf_name = f"{session_id}.lock"
        if operation == "acquire":
            try:
                os.mkdir(leaf_name, 0o700, dir_fd=root_fd)
                leaf_created = True
            except FileExistsError:
                leaf_created = False
            except OSError:
                reject()
        else:
            leaf_created = False
            try:
                os.stat(leaf_name, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                reject(1)
            except OSError:
                reject()

        leaf_fd = open_directory(root_fd, leaf_name, 0o700)
        record_name = (
            ".owner-releasing"
            if operation in {"release-finish", "release-restore"}
            else "owner"
        )
        if operation == "acquire" and not leaf_created:
            try:
                existing_entries = sorted(os.listdir(leaf_fd))
            except OSError:
                reject()
            if existing_entries == [".owner-releasing"]:
                record_name = ".owner-releasing"
        if leaf_created:
            try:
                os.fchmod(leaf_fd, 0o700)
            except OSError:
                reject()
        leaf_metadata = os.fstat(leaf_fd)
        if expected is not None and inode(leaf_metadata) != expected[2:4]:
            reject()
        if not named_directory_is(root_fd, leaf_name, leaf_fd, 0o700):
            reject()

        if leaf_created:
            try:
                if os.listdir(leaf_fd):
                    reject()
            except ClaimFailure:
                raise
            except OSError:
                reject()
            owner_metadata = publish_owner(leaf_fd, raw_pid, token)
        else:
            owner_metadata, fields, old_payload = owner_record(leaf_fd, record_name)
            if expected is not None and inode(owner_metadata) != expected[4:6]:
                reject()
            if operation == "acquire":
                if record_name == ".owner-releasing":
                    if process_is_live(fields[1]):
                        reject(1)
                    try:
                        os.rename(
                            ".owner-releasing",
                            "owner",
                            src_dir_fd=leaf_fd,
                            dst_dir_fd=leaf_fd,
                        )
                    except OSError:
                        reject()
                    owner_metadata, fields, old_payload = owner_record(leaf_fd)
                    record_name = "owner"
                if process_is_live(fields[1]):
                    if fields[1] != raw_pid or fields[2] != token:
                        reject(1)
                else:
                    if not named_directory_is(root_fd, leaf_name, leaf_fd, 0o700):
                        reject()
                    current = os.stat("owner", dir_fd=leaf_fd, follow_symlinks=False)
                    if snapshot(current) != snapshot(owner_metadata):
                        reject()
                    try:
                        os.unlink("owner", dir_fd=leaf_fd)
                    except OSError:
                        reject()
                    try:
                        owner_metadata = publish_owner(leaf_fd, raw_pid, token)
                    except ClaimFailure:
                        try:
                            if not os.listdir(leaf_fd):
                                publish_owner(leaf_fd, fields[1], fields[2], old_payload)
                        except (ClaimFailure, OSError):
                            pass
                        raise
            elif fields[1] != raw_pid or fields[2] != token:
                reject(1)

        if not named_directory_is(root_fd, leaf_name, leaf_fd, 0o700):
            reject()
        verified_owner, verified_fields, verified_payload = owner_record(
            leaf_fd, record_name
        )
        if (
            inode(verified_owner) != inode(owner_metadata)
            or verified_fields[1] != raw_pid
            or verified_fields[2] != token
        ):
            reject()
        if not named_directory_is(loop_fd, root_name, root_fd, 0o700):
            reject()
        if inode(os.lstat(loop_dir)) != inode(os.fstat(loop_fd)):
            reject()

        if operation in {"acquire", "inspect"}:
            output = binding_text(root_metadata, leaf_metadata, verified_owner)
            os.write(1, (output + "\n").encode("ascii"))
            return

        if operation == "release-detach":
            try:
                os.stat(".owner-releasing", dir_fd=leaf_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            except OSError:
                reject()
            else:
                reject()
            current = os.stat("owner", dir_fd=leaf_fd, follow_symlinks=False)
            if snapshot(current) != snapshot(verified_owner):
                reject()
            try:
                os.rename(
                    "owner",
                    ".owner-releasing",
                    src_dir_fd=leaf_fd,
                    dst_dir_fd=leaf_fd,
                )
            except OSError:
                reject(1)
            moved_owner, moved_fields, moved_payload = owner_record(
                leaf_fd, ".owner-releasing"
            )
            if (
                inode(moved_owner) != inode(verified_owner)
                or moved_fields != verified_fields
                or moved_payload != verified_payload
            ):
                reject(1)
            output = binding_text(root_metadata, leaf_metadata, moved_owner)
            os.write(1, (output + "\n").encode("ascii"))
            return

        if operation == "release-restore":
            try:
                os.stat("owner", dir_fd=leaf_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            except OSError:
                reject()
            else:
                reject()
            try:
                os.rename(
                    ".owner-releasing",
                    "owner",
                    src_dir_fd=leaf_fd,
                    dst_dir_fd=leaf_fd,
                )
            except OSError:
                reject(1)
            restored_owner, restored_fields, restored_payload = owner_record(leaf_fd)
            if (
                inode(restored_owner) != inode(verified_owner)
                or restored_fields != verified_fields
                or restored_payload != verified_payload
            ):
                reject(1)
            output = binding_text(root_metadata, leaf_metadata, restored_owner)
            os.write(1, (output + "\n").encode("ascii"))
            return

        staging_name = release_staging_name(
            session_id,
            root_metadata,
            leaf_metadata,
            verified_owner,
            verified_payload,
        )
        try:
            os.stat(staging_name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        except OSError:
            reject()
        else:
            reject()
        try:
            os.rename(
                ".owner-releasing",
                staging_name,
                src_dir_fd=leaf_fd,
                dst_dir_fd=root_fd,
            )
            staged_owner = os.stat(
                staging_name, dir_fd=root_fd, follow_symlinks=False
            )
        except OSError:
            reject(1)
        if (
            not regular_owner_ok(staged_owner)
            or inode(staged_owner) != inode(verified_owner)
            or staged_owner.st_size != verified_owner.st_size
        ):
            reject(1)
        if not named_directory_is(root_fd, leaf_name, leaf_fd, 0o700):
            reject(1)
        try:
            os.rmdir(leaf_name, dir_fd=root_fd)
        except OSError:
            try:
                os.rename(
                    staging_name,
                    "owner",
                    src_dir_fd=root_fd,
                    dst_dir_fd=leaf_fd,
                )
                restored_owner, restored_fields, restored_payload = owner_record(leaf_fd)
                if (
                    inode(restored_owner) != inode(verified_owner)
                    or restored_fields != verified_fields
                    or restored_payload != verified_payload
                ):
                    reject(1)
                output = binding_text(root_metadata, leaf_metadata, restored_owner)
                os.write(1, (output + "\n").encode("ascii"))
            except (ClaimFailure, OSError):
                pass
            reject(1)
        try:
            os.stat(leaf_name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        except OSError:
            reject(1)
        else:
            reject(1)
        if not named_directory_is(loop_fd, root_name, root_fd, 0o700):
            reject(1)
        if inode(os.lstat(loop_dir)) != inode(os.fstat(loop_fd)):
            reject(1)
        os.write(1, (staging_name + "\n").encode("ascii"))
    finally:
        if leaf_fd >= 0:
            os.close(leaf_fd)
        if root_fd >= 0:
            os.close(root_fd)
        os.close(loop_fd)


try:
    main()
except ClaimFailure as failure:
    raise SystemExit(failure.result)
except Exception:
    raise SystemExit(2)
PY
}

__dx_session_claim_checkpoint() {
  : "$@"
}

__dx_session_claim_clear_local() {
  unset DX_SESSION_CLAIM_SESSION DX_SESSION_CLAIM_TOKEN
  unset DX_SESSION_CLAIM_PID DX_SESSION_CLAIM_ROLE
  unset DX_SESSION_CLAIM_BINDING
}

# dx_session_claim_acquire <session_id> <startup|cleanup>
#
# Startup never continues after waiting on another generation. The prior owner
# may have completed cleanup while this process waited, so the caller must
# retry as a fresh command instead of reviving cached state.
dx_session_claim_acquire() {
  [[ $# -eq 2 ]] || return 2
  local session_id="$1" claim_role="$2" claim_token claim_binding=""
  local attempts_raw="${DEX_SESSION_CLAIM_ATTEMPTS:-400}" attempt=0
  local acquire_result=0 contended=0
  dx_session_id_valid "$session_id" || return 2
  case "$claim_role" in startup|cleanup) ;; *) return 2 ;; esac
  [[ "$attempts_raw" =~ ^[0-9]+$ && "$attempts_raw" -ge 1 \
    && "$attempts_raw" -le 4000 ]] || attempts_raw=400

  if [[ -n "${DX_SESSION_CLAIM_SESSION:-}" \
    || -n "${DX_SESSION_CLAIM_TOKEN:-}" \
    || -n "${DX_SESSION_CLAIM_PID:-}" ]]; then
    if [[ "${DX_SESSION_CLAIM_SESSION:-}" == "$session_id" \
      && "${DX_SESSION_CLAIM_PID:-}" == "$$" \
      && "${DX_SESSION_CLAIM_ROLE:-}" == "$claim_role" ]] \
      && dx_session_claim_owned "$session_id"; then
      return 0
    fi
    return 2
  fi

  # Imported empty variables can retain an export attribute. Remove them
  # before assigning the token so child processes cannot inherit it.
  __dx_session_claim_clear_local
  claim_token="$(date +%s)-$$-${RANDOM}-${RANDOM}-${RANDOM}"
  while [[ "$attempt" -lt "$attempts_raw" ]]; do
    acquire_result=0
    claim_binding=$(printf '%s\n' "$claim_token" \
      | __dx_session_claim_filesystem acquire "$session_id" "$$" -) \
      || acquire_result=$?
    if [[ "$acquire_result" -eq 0 ]]; then
      [[ "$claim_binding" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] \
        || return 2
      DX_SESSION_CLAIM_SESSION="$session_id"
      DX_SESSION_CLAIM_TOKEN="$claim_token"
      DX_SESSION_CLAIM_PID="$$"
      DX_SESSION_CLAIM_ROLE="$claim_role"
      DX_SESSION_CLAIM_BINDING="$claim_binding"
      __dx_session_claim_checkpoint "$claim_role" acquired "$session_id" \
        || {
          dx_session_claim_release_checked "$session_id" \
            >/dev/null 2>&1 || true
          __dx_session_claim_clear_local
          return 2
        }
      # The checkpoint is deliberately overridable by race tests. Revalidate
      # the bound directory entries before the caller enters its critical
      # section so a replacement can never inherit this acquisition.
      dx_session_claim_owned "$session_id" || {
        dx_session_claim_release_checked "$session_id" \
          >/dev/null 2>&1 || true
        __dx_session_claim_clear_local
        return 2
      }
      if [[ "$claim_role" == "startup" && "$contended" -eq 1 ]]; then
        dx_session_claim_release_checked "$session_id" >/dev/null 2>&1 \
          || return 2
        return 75
      fi
      return 0
    fi
    [[ "$acquire_result" -eq 1 ]] || return 2
    contended=1
    __dx_session_claim_checkpoint "$claim_role" contended "$session_id" \
      || return 2
    attempt=$((attempt + 1))
    [[ "$attempt" -lt "$attempts_raw" ]] && sleep 0.05
  done
  return 75
}

dx_session_claim_owned() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" inspected_binding="" inspect_result=0
  [[ "${DX_SESSION_CLAIM_SESSION:-}" == "$session_id" \
    && "${DX_SESSION_CLAIM_PID:-}" == "$$" \
    && -n "${DX_SESSION_CLAIM_TOKEN:-}" \
    && "${DX_SESSION_CLAIM_BINDING:-}" \
      =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  inspected_binding=$(printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
    | __dx_session_claim_filesystem inspect "$session_id" "$$" \
      "$DX_SESSION_CLAIM_BINDING") || inspect_result=$?
  [[ "$inspect_result" -eq 0 ]] || return "$inspect_result"
  [[ "$inspected_binding" == "$DX_SESSION_CLAIM_BINDING" ]] || return 2
}

__dx_session_claim_release_once() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" detached_binding="" finish_output=""
  local restored_binding=""
  local finish_result=0
  detached_binding=$(printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
    | __dx_session_claim_filesystem release-detach "$session_id" "$$" \
      "$DX_SESSION_CLAIM_BINDING") || return $?
  [[ "$detached_binding" == "$DX_SESSION_CLAIM_BINDING" ]] || return 2

  if ! __dx_session_claim_checkpoint "$DX_SESSION_CLAIM_ROLE" \
    owner-unlinked "$session_id"; then
    restored_binding=$(printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
      | __dx_session_claim_filesystem release-restore "$session_id" "$$" \
        "$DX_SESSION_CLAIM_BINDING") || return 1
    [[ "$restored_binding" == "$DX_SESSION_CLAIM_BINDING" ]] || return 1
    return 1
  fi

  finish_output=$(printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
    | __dx_session_claim_filesystem release-finish "$session_id" "$$" \
      "$DX_SESSION_CLAIM_BINDING") || finish_result=$?
  if [[ "$finish_result" -eq 0 ]]; then
    [[ "$finish_output" == .claim-release-* \
      && "$finish_output" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
    printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
      | __dx_session_claim_filesystem release-retire "$session_id" "$$" \
        "$finish_output" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ "$finish_output" == "$DX_SESSION_CLAIM_BINDING" ]]; then
    return "$finish_result"
  fi
  restored_binding=$(printf '%s\n' "$DX_SESSION_CLAIM_TOKEN" \
    | __dx_session_claim_filesystem release-restore "$session_id" "$$" \
      "$DX_SESSION_CLAIM_BINDING") || return "$finish_result"
  [[ "$restored_binding" == "$DX_SESSION_CLAIM_BINDING" ]] \
    || return "$finish_result"
  return "$finish_result"
}

dx_session_claim_release_checked() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" release_result=0 owner_result=0
  local claim_role="${DX_SESSION_CLAIM_ROLE:-}"
  dx_session_id_valid "$session_id" || return 2
  dx_session_claim_owned "$session_id" || owner_result=$?
  [[ "$owner_result" -eq 0 ]] || return "$owner_result"
  __dx_session_claim_checkpoint "$claim_role" releasing "$session_id" \
    || return 1
  __dx_session_claim_release_once "$session_id" || release_result=$?
  if [[ "$release_result" -eq 0 ]]; then
    __dx_session_claim_clear_local
    __dx_session_claim_checkpoint "$claim_role" released "$session_id" \
      || return 1
    return 0
  fi

  owner_result=0
  dx_session_claim_owned "$session_id" >/dev/null 2>&1 || owner_result=$?
  if [[ "$owner_result" -ne 0 ]]; then
    __dx_session_claim_clear_local
    if [[ "$owner_result" -eq 1 ]]; then
      __dx_session_claim_checkpoint "$claim_role" released "$session_id" \
        >/dev/null 2>&1 || true
    fi
  fi
  return "$release_result"
}

# dx_owner_file <session_id> — Claude session id that owns this loop's state.
# Session IDs are derived from the repo+worktree/branch path, so an unrelated
# Claude session opened in the same checkout resolves the same session_id. The
# Stop hook records the owning Claude session id here and stays inert in any
# other session, so bystander sessions are never captured by an active loop.
dx_owner_file() { echo "${DX_LOOP_DIR}/${1}.owner"; }

# dx_prompt_file <session_id>  — original prompt file path (for dxloop prompt persistence)
dx_prompt_file() { echo "${DX_LOOP_DIR}/${1}.prompt"; }

# dx_context_file <session_id> — system prompt context file (survives compaction via --append-system-prompt-file)
dx_context_file() { echo "${DX_STATE_DIR}/${1}.system-context"; }

# dx_log_file <session_id> — structured phase execution log (TSV)
dx_log_file() { echo "${DX_STATE_DIR}/${1}.log"; }

# dx_phase_outcomes_file <session_id> — durable terminal outcome ledger for phases 0-6
dx_phase_outcomes_file() { echo "${DX_STATE_DIR}/${1}.phase-outcomes"; }

# dx_branch_file <session_id> — branch last used by this lifecycle session
dx_branch_file() { echo "${DX_STATE_DIR}/${1}.branch"; }

# Write one current-user 0600 state file by replacing its directory entry.
# Existing non-regular paths are never followed or replaced.
dx_session_private_atomic_write() {
  [[ $# -eq 2 ]] || return 1
  local target_file="$1" file_content="$2" target_dir temporary_file
  [[ -n "$target_file" ]] || return 1
  target_dir=$(dirname "$target_file")
  mkdir -p "$target_dir" || return 1
  if [[ ( -e "$target_file" || -L "$target_file" ) \
    && ( ! -f "$target_file" || -L "$target_file" ) ]]; then
    return 1
  fi
  temporary_file=$(mktemp "${target_file}.tmp.XXXXXX") || return 1
  chmod 600 "$temporary_file" 2>/dev/null || true
  # mktemp creates the file; >| also works when an interactive zsh enables
  # noclobber before sourcing Dex.
  if ! printf '%s\n' "$file_content" >| "$temporary_file" \
    || ! command mv -f "$temporary_file" "$target_file"; then
    command rm -f "$temporary_file" 2>/dev/null || true
    return 1
  fi
}

# Read one current-user 0600 regular file only if the named inode remains the
# one opened for the full bounded read. Return 1 when absent and 2 when unsafe.
dx_session_trusted_file_read() {
  [[ $# -eq 2 ]] || return 2
  local state_file="$1" maximum_bytes="$2"
  [[ "$maximum_bytes" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ -e "$state_file" || -L "$state_file" ]] || return 1
  python3 - "$state_file" "$maximum_bytes" <<'PY' || return 2
import os
import stat
import sys

target = sys.argv[1]
maximum = int(sys.argv[2])
try:
    before = os.lstat(target)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_nlink != 1
        or not 1 <= before.st_size <= maximum
    ):
        raise ValueError
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(target, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ValueError
        raw = os.read(descriptor, maximum + 1)
        extra = os.read(descriptor, 1)
        after = os.fstat(descriptor)
        if (
            extra
            or len(raw) != opened.st_size
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        ):
            raise ValueError
    finally:
        os.close(descriptor)
    named = os.lstat(target)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or stat.S_IMODE(named.st_mode) != 0o600
        or named.st_nlink != 1
        or (named.st_dev, named.st_ino, named.st_size, named.st_mtime_ns)
        != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    ):
        raise ValueError
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError
except (OSError, ValueError):
    raise SystemExit(2)
sys.stdout.buffer.write(raw)
PY
}

# Print the exact saved local branch. Missing state is distinct from an unsafe
# inode or a value Git cannot use as a local branch ref.
dx_session_branch_read() {
  [[ $# -eq 1 ]] || return 2
  local session_id="$1" branch_record="" branch_value="" branch_result=0
  dx_session_id_valid "$session_id" || return 2
  branch_record=$(
    dx_session_trusted_file_read "$(dx_branch_file "$session_id")" 1024 \
      || exit $?
    printf '\034'
  ) || branch_result=$?
  [[ "$branch_result" -eq 0 ]] || return "$branch_result"
  [[ "$branch_record" == *$'\034' ]] || return 2
  branch_record=${branch_record%$'\034'}
  [[ "$branch_record" == *$'\n' ]] || return 2
  branch_value=${branch_record%$'\n'}
  [[ -n "$branch_value" && "$branch_value" != *$'\n'* \
    && "$branch_value" != *$'\r'* ]] || return 2
  if ! git check-ref-format "refs/heads/${branch_value}" >/dev/null 2>&1; then
    return 2
  fi
  if ! git check-ref-format --branch "$branch_value" >/dev/null 2>&1; then
    return 2
  fi
  printf '%s\n' "$branch_value"
}

# dx_meta_file <session_id> — per-session metadata sidecar (ticket id, tracker key,
# workspace dir/mode, original input). Used to resume a lifecycle by ticket
# number even when the worktree dir or branch has been renamed.
dx_meta_file() { echo "${DX_STATE_DIR}/${1}.meta"; }

# dx_meta_read <session_id> <key>
# Print the value for <key> from the session meta sidecar, or empty if missing.
dx_meta_read() {
  local session_id="$1" key="$2" meta_file
  [[ -n "$session_id" && -n "$key" ]] || return 0
  meta_file=$(dx_meta_file "$session_id")
  [[ -f "$meta_file" ]] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null
}

# dx_meta_write <session_id> [key=value ...]
# Merge key/value pairs into the session meta sidecar. Existing keys are
# overwritten; unspecified keys are preserved. Creation time is only set the
# first time the file is written. Safe to call repeatedly. Bash/zsh compatible:
# uses awk to merge so we avoid associative arrays.
dx_meta_write() {
  local session_id="$1"; shift
  local meta_file tmp_file overrides_input now_epoch pair
  [[ -n "$session_id" ]] || return 0
  [[ $# -gt 0 ]] || return 0

  meta_file=$(dx_meta_file "$session_id")
  mkdir -p "$(dirname "$meta_file")"
  now_epoch=$(date +%s)

  # Build a TAB-separated key<TAB>value stream of overrides, including
  # updated_at. created_at is added only when the file is new.
  overrides_input=""
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || continue
    local k="${pair%%=*}" v="${pair#*=}"
    [[ -n "$k" ]] || continue
    [[ "$k" == "created_at" || "$k" == "updated_at" ]] && continue
    overrides_input+=$(printf '%s\t%s\n' "$k" "$v")
    overrides_input+=$'\n'
  done
  overrides_input+=$(printf '%s\t%s\n' "updated_at" "$now_epoch")
  overrides_input+=$'\n'
  if [[ ! -f "$meta_file" ]]; then
    overrides_input+=$(printf '%s\t%s\n' "created_at" "$now_epoch")
    overrides_input+=$'\n'
  fi

  tmp_file="${meta_file}.tmp.$$"
  if ! printf '%s' "$overrides_input" | awk -F'\t' -v meta="$meta_file" '
    BEGIN {
      ok = 1
    }
    NF >= 2 {
      key = $1
      val = $0
      sub(/^[^\t]*\t/, "", val)
      overrides[key] = val
      order[++n] = key
    }
    END {
      # First, emit existing lines (preserve order), substituting overridden values
      # and recording which keys we have already written.
      if ((getline _ < meta) >= 0) {
        close(meta)
        while ((getline line < meta) > 0) {
          if (line == "") continue
          eq = index(line, "=")
          if (eq == 0) {
            print line
            continue
          }
          k = substr(line, 1, eq - 1)
          if (k in overrides) {
            print k "=" overrides[k]
            seen[k] = 1
          } else {
            print line
          }
        }
        close(meta)
      }
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!(k in seen)) {
          print k "=" overrides[k]
          seen[k] = 1
        }
      }
    }
  ' > "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi

  if ! command mv -f "$tmp_file" "$meta_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dx_meta_find_workspace_by_ticket <ticket_number>
# Scan meta sidecars in the current repo's session scope and print the first
# match as a TAB-separated record: session_id<TAB>wt_name<TAB>wt_dir<TAB>workspace_mode.
# Used to resume by ticket number when the conventional ticket-N directory
# does not exist (e.g. the worktree was originally named task-*).
dx_meta_find_workspace_by_ticket() {
  local ticket="$1" repo_key match="" match_identity="" candidate candidate_identity
  [[ -n "$ticket" ]] || return 1
  [[ -d "$DX_STATE_DIR" ]] || return 1
  repo_key=$(dx_session_repo_key)

  local meta_file session_id ticket_in_file wt_name wt_dir workspace_mode
  while IFS= read -r meta_file; do
    [[ -n "$meta_file" && -f "$meta_file" ]] || continue
    session_id="$(basename "$meta_file" .meta)"
    ticket_in_file=$(awk -F= '$1 == "ticket_number" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    [[ "$ticket_in_file" == "$ticket" ]] || continue
    wt_name=$(awk -F= '$1 == "wt_name" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    wt_dir=$(awk -F= '$1 == "wt_dir" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    workspace_mode=$(awk -F= '$1 == "workspace_mode" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    [[ -n "$wt_name" && -n "$wt_dir" ]] || continue
    [[ -d "$wt_dir" ]] || continue
    candidate=$(printf '%s\t%s\t%s\t%s' "$session_id" "$wt_name" "$wt_dir" "${workspace_mode:-worktree}")
    candidate_identity=$(printf '%s\t%s\t%s' "$wt_name" "$wt_dir" "${workspace_mode:-worktree}")
    if [[ -z "$match" ]]; then
      match="$candidate"
      match_identity="$candidate_identity"
    elif [[ "$candidate_identity" != "$match_identity" ]]; then
      dx_error "Multiple Dex workspaces are linked to ticket ${ticket}; use a workspace name instead."
      return 2
    fi
  done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" -print 2>/dev/null)
  [[ -n "$match" ]] || return 1
  printf '%s\n' "$match"
}

# dx_findings_file <session_id> — findings hash history for stuck loop detection
dx_findings_file() { echo "${DX_LOOP_DIR}/${1}.findings"; }

# dx_debt_file <session_id> — technical debt ledger (append-only markdown)
dx_debt_file() { echo "${DX_LOOP_DIR}/${1}.debt"; }

# dx_loop_config_file <session_id> — loop configuration (phase:promise:audit_file_path)
dx_loop_config_file() { echo "${DX_LOOP_DIR}/${1}.config"; }

# dx_handoff_mode_file <session_id> — marker for same-session phase handoff
dx_handoff_mode_file() { echo "${DX_LOOP_DIR}/${1}.handoff-mode"; }

# dx_paused_file <session_id> — marker allowing a paused session to exit without success cleanup
dx_paused_file() { echo "${DX_LOOP_DIR}/${1}.paused"; }

# dx_pause_state_file <session_id> — machine-readable reason/source for a pause
dx_pause_state_file() { echo "${DX_LOOP_DIR}/${1}.pause-state"; }

# dx_watch_pause_file <session_id> — marker that scheduled CI/PR watchers should no-op
dx_watch_pause_file() { echo "${DX_LOOP_DIR}/${1}.watch-pause"; }

# dx_watch_pause_ttl_seconds — watch-pause lifetime; 0 means no automatic expiry
dx_watch_pause_ttl_seconds() {
  local session_id="${1:-${DEX_SESSION_ID:-}}"
  local ttl="${DEX_WATCH_PAUSE_TTL_SECONDS:-3600}"
  if dx_session_id_valid "$session_id"; then
    ttl=$(dx_override_effective "$session_id" watch.pause-ttl "$ttl" \
      "${DEX_LOOP_PHASE:--}") || return 1
  fi
  if [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "$ttl"
  else
    echo "3600"
  fi
}

# dx_watch_pause_active <session_id> — true when scheduled watchers should skip work
dx_watch_pause_active() {
  local session_id="$1" pause_file raw epoch now ttl age
  [[ "${DEX_WATCH_IGNORE_PAUSE:-0}" == "1" ]] && return 1

  pause_file=$(dx_watch_pause_file "$session_id")
  [[ -f "$pause_file" ]] || return 1

  raw=$(cat "$pause_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$pause_file" 2>/dev/null || true
    return 1
  fi

  ttl=$(dx_watch_pause_ttl_seconds "$session_id")
  [[ "$ttl" -gt 0 ]] || return 0

  now=$(date +%s)
  age=$((now - epoch))
  if [[ "$age" -lt "$ttl" ]]; then
    return 0
  fi

  rm -f "$pause_file" 2>/dev/null || true
  return 1
}

# dx_write_watch_pause <session_id> [reason] — atomically write a watcher pause marker
dx_write_watch_pause() {
  local session_id="$1" reason="${2:-user-prompt}" pause_file tmp_file
  [[ -n "$session_id" ]] || return 0
  pause_file=$(dx_watch_pause_file "$session_id")
  mkdir -p "$(dirname "$pause_file")"
  tmp_file="${pause_file}.tmp.$$"
  if ! printf '%s\t%s\n' "$(date +%s)" "$reason" > "$tmp_file" || ! command mv -f "$tmp_file" "$pause_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dx_clear_watch_pause <session_id> — remove any watcher pause marker for the session
dx_clear_watch_pause() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0
  rm -f "$(dx_watch_pause_file "$session_id")" 2>/dev/null || true
}

# dx_watch_cycle_timeout_seconds — max runtime for one scheduled watcher cycle
dx_watch_cycle_timeout_seconds() {
  local session_id="${1:-${DEX_SESSION_ID:-}}"
  local timeout="${DEX_WATCH_CYCLE_TIMEOUT_SECONDS:-120}"
  if dx_session_id_valid "$session_id"; then
    timeout=$(dx_override_effective "$session_id" watch.cycle-timeout "$timeout" \
      "${DEX_LOOP_PHASE:--}") || return 1
  fi
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "120"
  fi
}

# dx_watch_command_timeout_seconds — max runtime for a single watcher shell command
dx_watch_command_timeout_seconds() {
  local session_id="${1:-${DEX_SESSION_ID:-}}"
  local timeout="${DEX_WATCH_COMMAND_TIMEOUT_SECONDS:-30}"
  if dx_session_id_valid "$session_id"; then
    timeout=$(dx_override_effective "$session_id" watch.command-timeout "$timeout" \
      "${DEX_LOOP_PHASE:--}") || return 1
  fi
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "30"
  fi
}

# dx_watch_run_command <session_id> <command> [args...]
# Run one watcher command under the live session policy. The wrapper keeps the
# environment default separate so clearing an override restores it immediately.
dx_watch_run_command() {
  [[ $# -ge 2 ]] || return 2
  local session_id="$1" timeout_default="${DEX_WATCH_COMMAND_TIMEOUT_SECONDS:-30}"
  shift
  dx_run_with_live_timeout "$session_id" watch.command-timeout \
    "$timeout_default" 6 1 "$@"
}

# dx_complete_max_cycles [session_id] — Phase 6 idle-cycle budget.
dx_complete_max_cycles() {
  local session_id="${1:-${DEX_SESSION_ID:-}}"
  local cycles="${DEX_COMPLETE_MAX_CYCLES:-3}"
  if dx_session_id_valid "$session_id"; then
    cycles=$(dx_override_effective "$session_id" complete.max-cycles "$cycles" \
      6) || return 1
  fi
  if [[ "$cycles" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$cycles"
  else
    printf '%s\n' "3"
  fi
}

# dx_complete_wait_minutes [session_id] — Phase 6 delay between checks.
dx_complete_wait_minutes() {
  local session_id="${1:-${DEX_SESSION_ID:-}}"
  local minutes="${DEX_COMPLETE_WAIT_MINUTES:-5}"
  if dx_session_id_valid "$session_id"; then
    minutes=$(dx_override_effective "$session_id" complete.wait-minutes \
      "$minutes" 6) || return 1
  fi
  if [[ "$minutes" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$minutes"
  else
    printf '%s\n' "5"
  fi
}

# dx_failure_attempts_per_strategy [session_id] — recovery retries before a
# materially different approach is expected.
dx_failure_attempts_per_strategy() {
  local session_id="${1:-${DEX_SESSION_ID:-}}" attempts="3"
  if dx_session_id_valid "$session_id"; then
    attempts=$(dx_override_effective "$session_id" \
      failure.attempts-per-strategy "$attempts" "${DEX_LOOP_PHASE:--}") \
      || return 1
  fi
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=3
  printf '%s\n' "$attempts"
}

# dx_failure_max_strategies [session_id] — distinct approaches before the
# default escalation point.
dx_failure_max_strategies() {
  local session_id="${1:-${DEX_SESSION_ID:-}}" strategies="2"
  if dx_session_id_valid "$session_id"; then
    strategies=$(dx_override_effective "$session_id" failure.max-strategies \
      "$strategies" "${DEX_LOOP_PHASE:--}") || return 1
  fi
  [[ "$strategies" =~ ^[0-9]+$ ]] || strategies=2
  printf '%s\n' "$strategies"
}

# dx_complete_ci_fix_attempts [session_id] — repeated CI failures before the
# Phase 6 escalation default applies.
dx_complete_ci_fix_attempts() {
  local session_id="${1:-${DEX_SESSION_ID:-}}" attempts="3"
  if dx_session_id_valid "$session_id"; then
    attempts=$(dx_override_effective "$session_id" complete.ci-fix-attempts \
      "$attempts" 6) || return 1
  fi
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=3
  printf '%s\n' "$attempts"
}

# dx_watch_lock_file <session_id> <watch_name> — per-watcher overlap guard
dx_watch_lock_file() { echo "${DX_LOOP_DIR}/${1}.${2}.watch-lock"; }

# dx_watch_lock_acquire <session_id> <watch_name> — acquire or reject active watcher lock
# This is a lease, not one of lib/lock.sh's locks, and the difference is
# deliberate. DEX_WATCH_CYCLE_TIMEOUT_SECONDS is documented as a watcher
# cycle's *runtime budget*: a cycle that outlives it has broken its contract,
# and the next scheduled tick is meant to take over rather than wait behind a
# watcher that may never finish. lock.sh refuses while the owner process is
# alive, which is the right rule for a mutex and the wrong one here — a hung
# watcher would block every later tick.
#
# The cost is the takeover lib/lock.sh's header calls out: two contenders can
# both find the lease expired, both remove it, and the second delete can take
# the first's freshly written replacement with it, leaving two watchers. That
# window stays open, deliberately. It is one printf wide, it did not reproduce
# in 200 rounds of four contenders, and closing it would not buy the property
# it looks like it buys — a cycle that outruns its budget hands the lease to
# the next tick while still running, which is the same two watchers, by design
# and far more often. Serialising the takeover would be precision applied to
# the rarer of two causes of one outcome.
#
# What did need fixing is the case underneath it. Every lease has recorded the
# owner pid since it was written and nothing ever read it, so a watcher that
# crashed held the next tick off for the whole budget — two minutes of nothing.
# That is now checked, and it is the common failure, not the race.
dx_watch_lock_acquire() {
  local session_id="$1" watch_name="$2" lock_file raw epoch owner_pid now age timeout
  [[ -n "$session_id" && -n "$watch_name" ]] || return 1

  lock_file=$(dx_watch_lock_file "$session_id" "$watch_name")
  mkdir -p "$(dirname "$lock_file")"

  if ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null; then
    return 0
  fi

  raw=$(cat "$lock_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  owner_pid="${raw#*$'\t'}"
  owner_pid="${owner_pid%%$'\t'*}"
  timeout=$(dx_watch_cycle_timeout_seconds "$session_id")
  now=$(date +%s)

  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$lock_file" 2>/dev/null || true
  elif [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! __dx_lock_pid_alive "$owner_pid"; then
    # A watcher that is gone will not finish its cycle, whatever is left of the
    # budget. Every lease has recorded this pid from the start and nothing ever
    # read it, so a crashed watcher held the next tick off for the full timeout
    # — two minutes of nothing, by default. lib/lock.sh's helper is used rather
    # than a bare `kill -0`, which reports EPERM for another user's live
    # process and would read it as dead.
    rm -f "$lock_file" 2>/dev/null || true
  else
    age=$((now - epoch))
    # A budget of 0 is no budget, the same as it means to dx_run_with_timeout
    # just above. It read the other way here — 0 skipped the age rule and so
    # took the lease from a live watcher on every tick, which is the opposite
    # of what asking for no limit asks for.
    [[ "$timeout" -eq 0 || "$age" -lt "$timeout" ]] && return 1
    rm -f "$lock_file" 2>/dev/null || true
  fi

  ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null
}

# dx_watch_lock_release <session_id> <watch_name> — release a watcher overlap lock
dx_watch_lock_release() {
  local session_id="$1" watch_name="$2"
  [[ -n "$session_id" && -n "$watch_name" ]] || return 0
  rm -f "$(dx_watch_lock_file "$session_id" "$watch_name")" 2>/dev/null || true
}

dx_kill_process_tree() {
  local pid="$1" signal="${2:-TERM}" child
  [[ -n "$pid" && -n "$signal" ]] || return 0

  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      dx_kill_process_tree "$child" "$signal"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  else
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      dx_kill_process_tree "$child" "$signal"
    done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  fi

  kill "-$signal" "$pid" 2>/dev/null || true
}

# __dx_timeout_token_pids <token_file> — find a supervised command after reparenting
#
# PPID walks stop working as soon as a command exits and one of its background
# children is reparented. Every command launched by dx_run_with_timeout inherits
# a unique token in both its environment and an open file descriptor, so cleanup
# can still identify those children. Linux exposes both through /proc. macOS
# exposes descriptor identity through libproc, with a bounded lsof fallback.
__dx_timeout_token_pids() {
  local token_file="$1" candidates="${2:-}"
  [[ -f "$token_file" ]] || return 0

  DX_TIMEOUT_PID_CANDIDATES="$candidates" python3 - "$token_file" <<'PY'
import ctypes
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


try:
    token = Path(sys.argv[1]).read_bytes().strip()
except OSError:
    raise SystemExit(0)
if not re.fullmatch(rb"[A-Za-z0-9._-]{16,160}", token):
    raise SystemExit(0)
marker = b"DX_TIMEOUT_PROCESS_TOKEN=" + token
candidate_values = os.environ.get("DX_TIMEOUT_PID_CANDIDATES", "").split()
candidates = set()
for value in candidate_values:
    try:
        candidate = int(value)
    except ValueError:
        raise SystemExit(0)
    if candidate > 0:
        candidates.add(candidate)
timeout_text = os.environ.get("DX_TIMEOUT_PROCESS_SCAN_TIMEOUT_SECONDS", "3")
try:
    scan_timeout = int(timeout_text)
except ValueError:
    scan_timeout = 3
if not 1 <= scan_timeout <= 30:
    scan_timeout = 3


def linux_processes(token_path):
    matches = set()
    proc = Path("/proc")
    try:
        token_stat = token_path.stat()
    except OSError:
        return matches
    if candidates:
        entries = tuple(proc / str(process_id) for process_id in candidates)
    else:
        entries = proc.iterdir()
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            environment = (entry / "environ").read_bytes().split(b"\0")
        except OSError:
            environment = ()
        if marker in environment:
            matches.add(int(entry.name))
            continue
        fd_dir = entry / "fd"
        try:
            descriptors = tuple(fd_dir.iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                descriptor_stat = descriptor.stat()
            except OSError:
                continue
            if (
                descriptor_stat.st_dev == token_stat.st_dev
                and descriptor_stat.st_ino == token_stat.st_ino
            ):
                matches.add(int(entry.name))
                break
    return matches


def darwin_processes(token_path):
    matches = set()
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError:
        return None
    libproc.proc_pidfdinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    libproc.proc_pidfdinfo.restype = ctypes.c_int
    process_ids = candidates
    if not process_ids:
        libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        libproc.proc_listallpids.restype = ctypes.c_int
        process_count = libproc.proc_listallpids(None, 0)
        if process_count <= 0:
            return None
        process_buffer = (ctypes.c_int * (process_count + 1024))()
        returned_count = libproc.proc_listallpids(
            process_buffer,
            ctypes.sizeof(process_buffer),
        )
        if returned_count <= 0:
            return None
        process_ids = {
            process_id
            for process_id in process_buffer[:returned_count]
            if process_id > 0
        }
    resolved_path = os.fsencode(token_path.resolve())
    for process_id in process_ids:
        buffer = ctypes.create_string_buffer(4096)
        byte_count = libproc.proc_pidfdinfo(
            process_id,
            9,
            2,  # PROC_PIDFDVNODEPATHINFO
            buffer,
            len(buffer),
        )
        if byte_count > 0 and resolved_path in buffer.raw[:byte_count]:
            matches.add(process_id)
    return matches


def lsof_processes(token_path, selected_candidates=None):
    target_candidates = candidates if selected_candidates is None else selected_candidates
    lsof = shutil.which("lsof")
    if not lsof and sys.platform == "darwin":
        lsof = "/usr/sbin/lsof"
    if not lsof or not Path(lsof).is_file():
        return set()
    try:
        command = [lsof]
        if target_candidates:
            command.extend(
                [
                    "-a",
                    "-p",
                    ",".join(str(pid) for pid in sorted(target_candidates)),
                    "-d",
                    "9",
                    "-Fpn",
                ]
            )
        else:
            command.extend(["-t", "--", str(token_path)])
        output = subprocess.check_output(
            command,
            stderr=subprocess.DEVNULL,
            timeout=scan_timeout,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return set()
    if target_candidates:
        matches = set()
        selected_pid = None
        resolved_path = os.fsencode(token_path.resolve())
        for line in output.splitlines():
            if line.startswith(b"p") and line[1:].isdigit():
                selected_pid = int(line[1:])
            elif line.startswith(b"n") and line[1:] == resolved_path:
                if selected_pid is not None:
                    matches.add(selected_pid)
        return matches
    matches = set()
    for raw_pid in output.split():
        try:
            matches.add(int(raw_pid))
        except ValueError:
            continue
    return matches


if sys.platform.startswith("linux"):
    matches = linux_processes(Path(sys.argv[1]))
elif sys.platform == "darwin":
    token_path = Path(sys.argv[1])
    matches = darwin_processes(token_path)
    if matches is None:
        matches = lsof_processes(token_path)
else:
    matches = lsof_processes(Path(sys.argv[1]))

for process_id in sorted(matches):
    print(process_id)
PY
}

# Enumerate a still-owned command root before signalling it. Each candidate is
# revalidated against the invocation token, so a concurrent exit or PID reuse
# cannot turn this ancestry snapshot into authority over another process.
__dx_timeout_process_tree_pids() {
  local root_pid="${1:-}" child
  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 0
  printf '%s\n' "$root_pid"
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      __dx_timeout_process_tree_pids "$child"
    done < <(pgrep -P "$root_pid" 2>/dev/null || true)
  else
    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      __dx_timeout_process_tree_pids "$child"
    done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$root_pid" '$2 == parent { print $1 }')
  fi
}

# Preserve the last owned ancestry snapshot before a supervised shell exits.
# This avoids a host-wide descriptor scan when a successful command leaves a
# background child behind. Token validation still happens before any signal.
__dx_timeout_record_candidates() {
  local root_pid="$1" candidate_file="$2" candidate_tmp
  [[ "$root_pid" =~ ^[0-9]+$ && -n "$candidate_file" ]] || return 0
  candidate_tmp="${candidate_file}.tmp.${root_pid}"
  (
    umask 077
    __dx_timeout_process_tree_pids "$root_pid" > "$candidate_tmp"
  ) || {
    command rm -f "$candidate_tmp" 2>/dev/null || true
    return 0
  }
  command mv "$candidate_tmp" "$candidate_file" 2>/dev/null || {
    command rm -f "$candidate_tmp" 2>/dev/null || true
  }
}

# __dx_timeout_signal_pid_list <pids> <root_pid> <signal>
__dx_timeout_signal_pid_list() {
  local pids="$1" root_pid="${2:-}" signal="${3:-TERM}" pid
  [[ -n "$root_pid" ]] && kill "-$signal" "$root_pid" 2>/dev/null || true
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done <<EOF
$pids
EOF
}

__dx_timeout_pid_list_alive() {
  local pids="$1" pid process_state
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    process_state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$process_state" && "$process_state" != Z* ]] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# __dx_timeout_terminate_processes <token_file> [root_pid] [candidate_file]
__dx_timeout_terminate_processes() {
  local token_file="$1" root_pid="${2:-}" candidate_file="${3:-}"
  local candidates="" pids
  local fresh_candidates="" fresh_pids candidate_pid

  if [[ -n "$root_pid" ]]; then
    candidates=$(__dx_timeout_process_tree_pids "$root_pid" 2>/dev/null || true)
    # The root is the command process created by this supervisor, so it is safe
    # to terminate before token validation. Descendants still require the token
    # check because they may exit and have their PIDs reused during cleanup.
    __dx_timeout_signal_pid_list "" "$root_pid" TERM
  elif [[ -f "$candidate_file" ]]; then
    candidates=$(cat "$candidate_file" 2>/dev/null || true)
  fi
  pids=$(__dx_timeout_token_pids "$token_file" "$candidates" \
    2>/dev/null || true)
  if [[ -z "$root_pid" && -n "$candidates" && -z "$pids" ]]; then
    # A child shell can daemonize its own child before the wrapper's EXIT
    # snapshot runs. Fall back to the invocation token only when the retained
    # ancestry no longer contains a matching process.
    pids=$(__dx_timeout_token_pids "$token_file" 2>/dev/null || true)
  fi
  __dx_timeout_signal_pid_list "$pids" "" TERM
  if __dx_timeout_pid_list_alive "$pids"; then
    sleep 2 2>/dev/null || true
    if __dx_timeout_pid_list_alive "$pids"; then
      # The original list is safe for deciding whether to spend the grace
      # period, but not for signalling afterward: an exited PID may already
      # belong to another process. Rescan the invocation token and signal only
      # processes that still carry it. Do not reuse root_pid here either.
      fresh_candidates=$(
        while IFS= read -r candidate_pid; do
          [[ "$candidate_pid" =~ ^[0-9]+$ ]] || continue
          __dx_timeout_process_tree_pids "$candidate_pid"
        done <<EOF
$pids
EOF
      )
      fresh_pids=$(__dx_timeout_token_pids "$token_file" "$fresh_candidates" \
        2>/dev/null || true)
      __dx_timeout_signal_pid_list "$fresh_pids" "" KILL
    fi
  fi
}

__dx_timeout_stop_watchdog() {
  local watchdog_pid="${1:-}"
  [[ -n "$watchdog_pid" ]] || return 0
  dx_kill_process_tree "$watchdog_pid" TERM
  wait "$watchdog_pid" 2>/dev/null || true
}

__dx_timeout_remove_state() {
  local temp_dir="${1:-}" marker_file="${2:-}" token_file="${3:-}"
  local candidate_file="${4:-}"
  command rm -f "$marker_file" "$token_file" "$candidate_file" 2>/dev/null || true
  [[ -n "$temp_dir" ]] && command rmdir "$temp_dir" 2>/dev/null || true
}

__dx_timeout_abort() {
  local exit_status="$1" temp_dir="$2" marker_file="$3" token_file="$4"
  local candidate_file="$5" cmd_pid="${6:-}" watchdog_pid="${7:-}"
  __dx_timeout_stop_watchdog "$watchdog_pid"
  __dx_timeout_terminate_processes "$token_file" "$cmd_pid" "$candidate_file"
  [[ -n "$cmd_pid" ]] && wait "$cmd_pid" 2>/dev/null || true
  __dx_timeout_remove_state "$temp_dir" "$marker_file" "$token_file" \
    "$candidate_file"
  exit "$exit_status"
}

# __dx_run_with_timeout_core <seconds> <command> [args...] — isolated supervisor
__dx_run_with_timeout_core() {
  local timeout="$1" temp_dir="" marker="" token_file="" token=""
  local candidate_file="" command_root_pid=""
  local cmd_pid="" watchdog_pid="" cmd_status timeout_enabled=0
  local started_at="" now="" elapsed="" last_policy_check=""
  local policy_value="" live_timeout="" timeout_marker=""
  local policy_session="${DX_TIMEOUT_POLICY_SESSION_ID:-}"
  local policy_gate="${DX_TIMEOUT_POLICY_GATE:-}"
  local policy_default="${DX_TIMEOUT_POLICY_DEFAULT_VALUE:-}"
  local policy_phase="${DX_TIMEOUT_POLICY_PHASE:--}"
  local policy_multiplier="${DX_TIMEOUT_POLICY_MULTIPLIER:-1}"
  shift
  [[ $# -gt 0 ]] || return 2

  if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
    timeout_enabled=1
  fi
  if [[ -n "$policy_session" && -n "$policy_gate" ]]; then
    timeout_enabled=1
  fi

  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-timeout.XXXXXX") || return 2
  marker="$temp_dir/expired"
  token_file="$temp_dir/token"
  candidate_file="$temp_dir/candidates"
  token="dx-${$}-${RANDOM}-${RANDOM}-$(date +%s)"
  (umask 077 && printf '%s\n' "$token" > "$token_file") || {
    __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file" \
      "$candidate_file"
    return 2
  }

  trap '__dx_timeout_abort 130 "$temp_dir" "$marker" "$token_file" "$candidate_file" "$cmd_pid" "$watchdog_pid"' INT
  trap '__dx_timeout_abort 143 "$temp_dir" "$marker" "$token_file" "$candidate_file" "$cmd_pid" "$watchdog_pid"' TERM
  trap '__dx_timeout_abort 129 "$temp_dir" "$marker" "$token_file" "$candidate_file" "$cmd_pid" "$watchdog_pid"' HUP
  # Explicit subshell preserves full function execution and exit status when the
  # command is a shell function with invocation-scoped environment variables.
  (
    # Bash 3.2 and zsh both keep $$ fixed across subshells. A short child can
    # report its real parent PID portably before the supervised command starts.
    command_root_pid=$(/bin/sh -c 'printf "%s\n" "$PPID"')
    trap '__dx_timeout_record_candidates "$command_root_pid" "$candidate_file"' EXIT
    export DX_TIMEOUT_PROCESS_TOKEN="$token"
    unset DX_TIMEOUT_POLICY_SESSION_ID DX_TIMEOUT_POLICY_GATE \
      DX_TIMEOUT_POLICY_DEFAULT_VALUE DX_TIMEOUT_POLICY_PHASE \
      DX_TIMEOUT_POLICY_MULTIPLIER
    # A low, explicitly opened descriptor survives ordinary shell fork/exec
    # chains on both supported platforms and is discoverable after reparenting.
    exec 9< "$token_file"
    "$@"
  ) &
  cmd_pid=$!

  if [[ $timeout_enabled -eq 1 ]]; then
    # Keep deadline ownership in the supervisor that also reaps the command.
    # A separate timer process can lose a scheduling race to an outer lifecycle
    # fence under load, turning an internal timeout into a misleading SIGTERM.
    # Poll command liveness cheaply and re-read live policy at most once per
    # wall-clock second.
    started_at=$(date +%s)
    while kill -0 "$cmd_pid" 2>/dev/null; do
      now=$(date +%s)
      if [[ "$now" != "$last_policy_check" ]]; then
        last_policy_check="$now"
        live_timeout="$timeout"
        if [[ -n "$policy_session" && -n "$policy_gate" ]]; then
          if ! policy_value=$(dx_override_effective "$policy_session" \
            "$policy_gate" "$policy_default" "$policy_phase" \
            2>/dev/null); then
            printf 'policy-invalid\n' > "$marker"
            __dx_timeout_terminate_processes "$token_file" "$cmd_pid" \
              "$candidate_file"
            break
          fi
          if [[ ! "$policy_value" =~ ^[0-9]+$ \
            || ! "$policy_multiplier" =~ ^[1-9][0-9]*$ ]]; then
            printf 'policy-invalid\n' > "$marker"
            __dx_timeout_terminate_processes "$token_file" "$cmd_pid" \
              "$candidate_file"
            break
          fi
          live_timeout=$((10#$policy_value * 10#$policy_multiplier))
        fi
        elapsed=$((now - started_at))
        if [[ "$live_timeout" -gt 0 \
          && "$elapsed" -ge "$live_timeout" ]]; then
          printf 'timeout\n' > "$marker"
          __dx_timeout_terminate_processes "$token_file" "$cmd_pid" \
            "$candidate_file"
          break
        fi
      fi
      sleep 0.1 2>/dev/null || true
    done
  fi

  cmd_status=0
  wait "$cmd_pid" 2>/dev/null || cmd_status=$?

  if [[ -f "$marker" ]]; then
    timeout_marker=$(cat "$marker" 2>/dev/null || true)
    __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file" \
      "$candidate_file"
    [[ "$timeout_marker" == "policy-invalid" ]] && return 125
    return 124
  fi

  # A natural command exit may still leave background children. Terminate every
  # process that inherited this invocation's token before returning its status.
  __dx_timeout_terminate_processes "$token_file" "" "$candidate_file"
  __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file" \
    "$candidate_file"
  return "$cmd_status"
}

# dx_run_with_live_timeout <session> <gate> <default-value> <phase|->
#   <seconds-per-value> <command> [args...]
# Re-resolve the policy once per second so an in-session override can extend,
# shorten, disable, or restore the deadline of a running provider command.
dx_run_with_live_timeout() {
  [[ $# -ge 6 ]] || return 2
  local policy_session="$1" policy_gate="$2" policy_default="$3"
  local policy_phase="$4" policy_multiplier="$5" initial_value initial_timeout
  shift 5
  dx_session_id_valid "$policy_session" || return 2
  dx_override_gate_supported "$policy_gate" || return 2
  dx_override_phase_valid "$policy_phase" || return 2
  [[ "$policy_default" =~ ^[0-9]+$ && ${#policy_default} -le 15 ]] || return 2
  [[ "$policy_multiplier" =~ ^[1-9][0-9]*$ \
    && ${#policy_multiplier} -le 4 ]] || return 2
  initial_value=$(dx_override_effective "$policy_session" "$policy_gate" \
    "$policy_default" "$policy_phase") || return 125
  [[ "$initial_value" =~ ^[0-9]+$ && ${#initial_value} -le 15 ]] || return 2
  initial_timeout=$((10#$initial_value * 10#$policy_multiplier))
  DX_TIMEOUT_POLICY_SESSION_ID="$policy_session" \
  DX_TIMEOUT_POLICY_GATE="$policy_gate" \
  DX_TIMEOUT_POLICY_DEFAULT_VALUE="$policy_default" \
  DX_TIMEOUT_POLICY_PHASE="$policy_phase" \
  DX_TIMEOUT_POLICY_MULTIPLIER="$policy_multiplier" \
    dx_run_with_timeout "$initial_timeout" "$@"
}

# dx_run_with_timeout <seconds> <command> [args...] — portable timeout wrapper
dx_run_with_timeout() {
  local timeout_supervisor_pid="" timeout_status=0 timeout_signal_status=0
  local timeout_prior_int="" timeout_prior_term="" timeout_prior_hup=""

  # zsh can scope traps to this function. Bash 3.2 cannot, so preserve and
  # restore its caller's handlers explicitly after the supervisor exits.
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions localtraps
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    timeout_prior_int=$(trap -p INT)
    timeout_prior_term=$(trap -p TERM)
    timeout_prior_hup=$(trap -p HUP)
  fi

  trap 'timeout_signal_status=130; if [[ -n "$timeout_supervisor_pid" ]]; then kill -INT "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' INT
  trap 'timeout_signal_status=143; if [[ -n "$timeout_supervisor_pid" ]]; then kill -TERM "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' TERM
  trap 'timeout_signal_status=129; if [[ -n "$timeout_supervisor_pid" ]]; then kill -HUP "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' HUP

  (
    local timeout_core_status=0
    __dx_run_with_timeout_core "$@" || timeout_core_status=$?
    exit "$timeout_core_status"
  ) &
  timeout_supervisor_pid=$!
  wait "$timeout_supervisor_pid" 2>/dev/null || timeout_status=$?
  [[ $timeout_signal_status -ne 0 ]] && timeout_status=$timeout_signal_status

  trap - INT TERM HUP
  if [[ -n "${BASH_VERSION:-}" ]]; then
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_int" ]] && eval "$timeout_prior_int"
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_term" ]] && eval "$timeout_prior_term"
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_hup" ]] && eval "$timeout_prior_hup"
  fi

  return "$timeout_status"
}

# dx_review_state_file <session_id> — review sub-loop clean pass counter (survives interrupts)
dx_review_state_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-state"; }

# dx_review_result_file <session_id> — per-iteration review result
dx_review_result_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-result"; }

# dx_review_context_file <session_id> — compact context pack for review waves
dx_review_context_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-context"; }

# dx_review_criteria_file <session_id> — approved lifecycle requirements for review
dx_review_criteria_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-criteria.json"; }

# dx_review_criteria_approval_file <session_id> — sealed Phase 1 criteria hash and revision
dx_review_criteria_approval_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-criteria-approval"; }

# A review context pack must expose the four auditable sections used by the
# evidence gate. This rejects placeholder sentinels while keeping the body
# human-readable for later diagnostics.
dx_review_context_valid() {
  local context_file="$1" expected_binding="${2:-}"
  [[ -f "$context_file" ]] || return 1
  [[ $(wc -c < "$context_file" 2>/dev/null | tr -d ' ') -ge 160 ]] || return 1
  LC_ALL=C grep -q '^## Scope' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Deterministic Checks' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Review Coverage' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Verification' "$context_file" 2>/dev/null || return 1
  if [[ -n "$expected_binding" ]]; then
    [[ "$expected_binding" == "standalone" || "$expected_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
    LC_ALL=C grep -q '^## Acceptance Criteria' "$context_file" 2>/dev/null &&
      LC_ALL=C grep -Fqx "Criteria binding: ${expected_binding}" "$context_file" 2>/dev/null
  fi
}

# Each pass owns one 16-character lowercase SHA-256 prefix.
dx_review_findings_hash_valid() {
  local findings_file="$1"
  [[ -f "$findings_file" ]] || return 1
  LC_ALL=C awk '
    END {
      valid = (NR == 1 && length($0) == 16 && $0 !~ /[^0-9a-f]/)
      exit !valid
    }
  ' "$findings_file" 2>/dev/null
}

# dx_review_selection_file <session_id> — persisted risk tier chosen before review
dx_review_selection_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-selection"; }

# dx_review_evidence_file <session_id> — versioned machine-readable pass evidence
dx_review_evidence_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-evidence.json"; }

# dx_review_ledger_file <session_id> — accepted consecutive clean-pass records
dx_review_ledger_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-ledger"; }

# dx_review_receipt_file <session_id> — machine-readable successful review gate
dx_review_receipt_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-receipt"; }

# dx_review_lock_dir <repo_dir> — checkout-scoped review-loop ownership lock
dx_review_lock_dir() {
  local repo_dir="${1:-$PWD}" lock_key
  lock_key=$(DX_REVIEW_LOCK_REPO_DIR="$repo_dir" python3 - <<'PY'
import hashlib
import os
import subprocess
from pathlib import Path

requested = Path(os.environ["DX_REVIEW_LOCK_REPO_DIR"]).resolve()
probe = subprocess.run(
    ["git", "-C", str(requested), "rev-parse", "--show-toplevel"],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
if probe.returncode != 0:
    raise SystemExit(1)
root = os.path.realpath(os.fsdecode(probe.stdout.rstrip(b"\n")))
print(hashlib.sha256(os.fsencode(root)).hexdigest()[:24])
PY
  ) || return 1
  [[ "$lock_key" =~ ^[a-f0-9]{24}$ ]] || return 1
  printf '%s/review-checkout-%s.lock\n' "$DX_LOOP_DIR" "$lock_key"
}

# The review-loop checkout lock is lib/lock.sh's lock. It used to be a copy of
# it — the same reaper mutex, the same owner record, the same return codes,
# about a hundred lines of it — and the two had drifted in opposite directions.
# This copy tested liveness with a bare `kill -0`, which reports EPERM for a
# live process owned by another user and so read it as dead; lock.sh followed
# symlinks when ageing a path. Neither was the good one, which is the argument
# for keeping one.

# dx_review_lock_acquire <repo_dir> <owner_token> [owner_pid] — atomically own one checkout
dx_review_lock_acquire() {
  local repo_dir="$1" owner_token="$2" caller_pid="${3:-$$}" lock_dir
  lock_dir=$(dx_review_lock_dir "$repo_dir") || return 2
  dx_lock_acquire "$lock_dir" "$owner_token" "$caller_pid" 30
}

# dx_review_lock_release <repo_dir> <owner_token> — release only our own lock
dx_review_lock_release() {
  local repo_dir="$1" owner_token="$2" lock_dir
  [[ -n "$owner_token" ]] || return 0
  lock_dir=$(dx_review_lock_dir "$repo_dir" 2>/dev/null) || return 0
  dx_lock_release "$lock_dir" "$owner_token"
}

# Release a checkout lock without losing the first failure signal. The shared
# lock primitive restores the verified owner when directory removal fails, so
# this retry can safely clean a transient failure without stealing a peer's
# lock.
dx_review_lock_release_checked() {
  local repo_dir="$1" owner_token="$2" lock_dir
  [[ -n "$owner_token" ]] || return 0
  lock_dir=$(dx_review_lock_dir "$repo_dir" 2>/dev/null) || return 1
  dx_lock_release_checked "$lock_dir" "$owner_token"
}

# dx_complete_state_file <session_id> — Phase 6 cycle bookkeeping ("cycle_count:last_check_epoch")
# Survives interrupts so resuming Phase 6 picks up the same cycle counter.
dx_complete_state_file() { echo "${DX_LOOP_DIR}/${1}.complete-state"; }

# dx_provider_state_file <session_id> — resolved provider engine for hook fallback
dx_provider_state_file() { echo "${DX_LOOP_DIR}/${1}.provider"; }

# dx_phase_started_file <session_id> <phase> — marker that the phase skill/workflow started
dx_phase_started_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.started"; }

# dx_phase_ready_file <session_id> <phase> — marker that a pre-audit phase gate is satisfied
dx_phase_ready_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.ready"; }

# dx_phase_busy_file <session_id> <phase> — marker that async phase work is still running
dx_phase_busy_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy"; }

# dx_phase_busy_notice_file <session_id> <phase> — last busy-gate notice timestamp
dx_phase_busy_notice_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-notice"; }

# dx_phase_busy_cancel_file <session_id> <phase> — cancellation request for the busy owner
dx_phase_busy_cancel_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-cancel"; }

# dx_phase_busy_quiesced_file <session_id> <phase> — matching owner acknowledgement
dx_phase_busy_quiesced_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-quiesced"; }

# dx_log_phase <session_id> <step> <phase_name> <start_epoch> <end_epoch> <duration_s> <iterations> <status> <exit_code>
# Append a TSV row to the structured phase log. Creates the header on first write.
dx_log_phase() {
  local session_id="$1" step="$2" phase_name="$3"
  local start_epoch="$4" end_epoch="$5" duration_s="$6"
  local iterations="$7" phase_status="$8" exit_code="$9"
  local log_file
  log_file=$(dx_log_file "$session_id")

  mkdir -p "$(dirname "$log_file")"
  if [[ ! -f "$log_file" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "session_id" "phase" "phase_name" "start_epoch" "end_epoch" \
      "duration_s" "iterations" "status" "exit_code" > "$log_file"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session_id" "$step" "$phase_name" "$start_epoch" "$end_epoch" \
    "$duration_s" "$iterations" "$phase_status" "$exit_code" >> "$log_file"
}

# dx_phase_result_data — the phase.completed / phase.failed event payload.
#
# Reads the same nine values dx_log_phase writes, from the environment:
# DX_PHASE_NAME, DX_PHASE_START_EPOCH, DX_PHASE_END_EPOCH, DX_PHASE_DURATION,
# DX_PHASE_ITERATIONS, DX_PHASE_STATUS, DX_PHASE_EXIT_CODE. Anything that is
# not a whole number becomes 0 rather than breaking the JSON.
#
# It lives here, beside dx_log_phase, because the two describe one phase result
# and drifting apart would give the log and the event different answers. Until
# now it was written out twice — once in dx.sh for the inline lifecycle and once
# in hooks/phase-loop.sh for the Stop hook — as byte-identical copies defining a
# format that consumers read.
dx_phase_result_data() {
  python3 - <<'PY'
import json
import os


def as_int(name):
    try:
        return int(os.environ.get(name, "0"))
    except ValueError:
        return 0


print(json.dumps({
    "phase_name": os.environ.get("DX_PHASE_NAME", ""),
    "start_epoch": as_int("DX_PHASE_START_EPOCH"),
    "end_epoch": as_int("DX_PHASE_END_EPOCH"),
    "duration_s": as_int("DX_PHASE_DURATION"),
    "iterations": as_int("DX_PHASE_ITERATIONS"),
    "status": os.environ.get("DX_PHASE_STATUS", ""),
    "exit_code": as_int("DX_PHASE_EXIT_CODE"),
}, sort_keys=True, separators=(",", ":")))
PY
}

# dx_phase_outcome_record <session_id> <phase> <outcome> <source> <generation> <reason>
# Atomically append one idempotent phase outcome. Returns 3 when the same
# phase/generation receipt is already present.
dx_phase_outcome_record() {
  local session_id="$1" phase="$2" outcome="$3" source="$4" generation="$5" reason="$6"
  local outcome_file tmp_file recorded_at existing_status
  dx_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  case "$outcome" in
    completed|skipped|waived|invalidated) ;;
    *) return 1 ;;
  esac
  [[ "$source" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$generation" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  outcome_file=$(dx_phase_outcomes_file "$session_id")
  mkdir -p "$(dirname "$outcome_file")" || return 1
  if [[ ( -e "$outcome_file" || -L "$outcome_file" ) \
    && ( ! -f "$outcome_file" || -L "$outcome_file" ) ]]; then
    return 1
  fi
  if [[ -f "$outcome_file" ]]; then
    existing_status=$(awk -F '\t' -v phase="$phase" -v generation="$generation" \
      -v outcome="$outcome" -v source="$source" -v reason="$reason" '
      NR > 1 && $2 == phase && $5 == generation {
        found = 1
        if ($3 != outcome || $4 != source || $6 != reason) conflict = 1
      }
      END {
        if (conflict) print "conflict"
        else if (found) print "exact"
      }
    ' "$outcome_file" 2>/dev/null || true)
    [[ "$existing_status" == "exact" ]] && return 3
    [[ "$existing_status" == "conflict" ]] && return 1
  fi

  tmp_file=$(mktemp "${outcome_file}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp_file" 2>/dev/null || true
  # >| because mktemp already created the file (noclobber-safe under zsh).
  if [[ -f "$outcome_file" ]]; then
    if ! command cat "$outcome_file" >| "$tmp_file"; then
      command rm -f "$tmp_file" 2>/dev/null || true
      return 1
    fi
  elif ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    recorded_at phase outcome source generation reason >| "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi

  recorded_at=$(date +%s)
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$recorded_at" "$phase" "$outcome" "$source" "$generation" "$reason" \
    >> "$tmp_file" || ! command mv -f "$tmp_file" "$outcome_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

# dx_phase_outcome_latest <session_id> <phase>
# Prefer the explicit ledger, then recognize successful legacy TSV phase rows.
dx_phase_outcome_latest() {
  local session_id="$1" phase="$2" outcome_file log_file outcome=""
  local run_id="" events_file=""
  dx_session_id_valid "$session_id" || return 0
  [[ "$phase" =~ ^[0-6]$ ]] || return 0

  outcome_file=$(dx_phase_outcomes_file "$session_id")
  if [[ -f "$outcome_file" && ! -L "$outcome_file" ]]; then
    outcome=$(awk -F '\t' -v phase="$phase" '
      NR > 1 && $2 == phase { outcome = $3 }
      END { print outcome }
    ' "$outcome_file" 2>/dev/null || true)
  fi
  if [[ "$outcome" == "completed" || "$outcome" == "skipped" || "$outcome" == "waived" ]]; then
    printf '%s\n' "$outcome"
    return 0
  fi
  # An explicit invalidation is a durable rollback fence. Do not fall back to
  # an older successful phase log after a terminal transaction returned the
  # lifecycle to Phase 6.
  [[ "$outcome" == "invalidated" ]] && return 0

  log_file=$(dx_log_file "$session_id")
  if [[ -f "$log_file" && ! -L "$log_file" ]]; then
    outcome=$(awk -F '\t' -v phase="$phase" '
      NR > 1 && $2 == phase && $8 == "advance" && $9 == "0" { outcome = "completed" }
      END { print outcome }
    ' "$log_file" 2>/dev/null || true)
    if [[ "$outcome" == "completed" ]]; then
      printf '%s\n' "$outcome"
      return 0
    fi
  fi

  # Older sessions may retain their run journal after the compact phase log
  # has been cleaned up. Reconcile the latest validated event for this phase;
  # PR state and other external artifacts are never completion evidence.
  if type dx_run_read_for_session >/dev/null 2>&1 \
    && type dx_run_events_file >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1; then
    run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
    [[ -n "$run_id" ]] && events_file=$(dx_run_events_file "$run_id" 2>/dev/null || true)
  fi
  if [[ -n "$events_file" && -f "$events_file" && ! -L "$events_file" ]]; then
    outcome=$(python3 - "$events_file" "$phase" "$run_id" <<'PY' 2>/dev/null || true
import json
import sys

events_path, expected_phase, expected_run = sys.argv[1:]
relevant_types = {
    "phase.started",
    "phase.completed",
    "phase.failed",
    "phase.skipped",
    "phase.waived",
}
terminal_outcomes = {
    "phase.completed": "completed",
    "phase.skipped": "skipped",
    "phase.waived": "waived",
}
latest_sequence = -1
latest_type = ""
with open(events_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        if len(raw_line) > 1_048_576:
            continue
        try:
            event = json.loads(raw_line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        sequence = event.get("sequence")
        event_id = event.get("id")
        if event_type not in relevant_types or event.get("phase") != expected_phase:
            continue
        if event.get("run_id") != expected_run or event.get("severity") not in {"info", "warn", "error"}:
            continue
        if not isinstance(sequence, int) or sequence <= 0:
            continue
        if not isinstance(event_id, str) or not event_id.startswith(f"evt_{sequence:06d}_"):
            continue
        if sequence > latest_sequence:
            latest_sequence = sequence
            latest_type = event_type
outcome = terminal_outcomes.get(latest_type)
if outcome:
    print(outcome)
PY
)
    case "$outcome" in
      completed|skipped|waived) printf '%s\n' "$outcome" ;;
    esac
  fi
  return 0
}

# dx_record_session_branch <session_id> [repo_dir]
# Persist the branch used by this lifecycle. In-place sessions need this to
# resume safely because the checkout can be moved to a different branch between
# runs. Worktree sessions record it too for diagnostics.
dx_record_session_branch() {
  local session_id="$1" repo_dir="${2:-.}" branch="" saved_branch=""
  dx_session_id_valid "$session_id" || return 1
  branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD \
    2>/dev/null || true)
  [[ -n "$branch" ]] || return 0
  if ! git check-ref-format "refs/heads/${branch}" >/dev/null 2>&1; then
    return 1
  fi
  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    return 1
  fi
  dx_session_private_atomic_write "$(dx_branch_file "$session_id")" "$branch" \
    || return 1
  saved_branch=$(dx_session_branch_read "$session_id" 2>/dev/null) || return 1
  [[ "$saved_branch" == "$branch" ]]
}

# dx_cleanup_session <session_id>
# Remove all loop and phase state files for a session. Safe to call when dirs don't exist.
dx_cleanup_session() {
  local sid="$1" completion_revoke_result=0
  dx_session_id_valid "$sid" || return 2
  if command -v dx_completion_cleanup >/dev/null 2>&1; then
    if ! dx_completion_cleanup "$sid" 2>/dev/null; then
      __dx_completion_recover_cleanup "$sid" 2>/dev/null || completion_revoke_result=1
    fi
  fi
  if [[ -d "$DX_LOOP_DIR" ]]; then
    dx_review_ledger_reset "$sid" 2>/dev/null || true
    rm -f "$(dx_loop_file "$sid")" "$(dx_complete_file "$sid")" "$(dx_active_file "$sid")" "$(dx_owner_file "$sid")" "$(dx_prompt_file "$sid")" "$(dx_findings_file "$sid")" "$(dx_debt_file "$sid")" "$(dx_loop_config_file "$sid")" "$(dx_handoff_mode_file "$sid")" "$(dx_paused_file "$sid")" "$(dx_pause_state_file "$sid")" "$(dx_watch_pause_file "$sid")" "${DX_LOOP_DIR}/${sid}.control" "$(dx_watch_lock_file "$sid" ci)" "$(dx_watch_lock_file "$sid" pr)" "$(dx_review_state_file "$sid")" "$(dx_review_result_file "$sid")" "$(dx_review_context_file "$sid")" "$(dx_review_criteria_file "$sid")" "$(dx_review_criteria_approval_file "$sid")" "$(dx_review_evidence_file "$sid")" "$(dx_review_selection_file "$sid")" "${DX_LOOP_DIR}/${sid}.review-selection.revoked" "$(dx_review_receipt_file "$sid")" "${DX_LOOP_DIR}/${sid}.review-receipt.revoked" "$(dx_complete_state_file "$sid")" "$(dx_provider_state_file "$sid")" 2>/dev/null
    rm -f "${DX_LOOP_DIR}/${sid}.control-lock/owner" 2>/dev/null || true
    rmdir "${DX_LOOP_DIR}/${sid}.control-lock" 2>/dev/null || true
    find "$DX_LOOP_DIR" -maxdepth 1 -type f \( -name "${sid}.phase-*.started" -o -name "${sid}.phase-*.ready" -o -name "${sid}.phase-*.busy" -o -name "${sid}.phase-*.busy-notice" -o -name "${sid}.phase-*.busy-cancel" -o -name "${sid}.phase-*.busy-quiesced" \) -exec rm -f {} + 2>/dev/null || true
  fi
  # `&&` here would make a missing state directory the function's exit status,
  # which contradicts the promise above and would abort a `set -e` caller.
  if [[ -d "$DX_STATE_DIR" ]]; then
    rm -f "$(dx_state_file "$sid")" "$(dx_times_file "$sid")" "$(dx_context_file "$sid")" "$(dx_log_file "$sid")" "$(dx_phase_outcomes_file "$sid")" "$(dx_branch_file "$sid")" "$(dx_meta_file "$sid")" "${DX_STATE_DIR}/${sid}.interventions" "${DX_STATE_DIR}/${sid}.human-complete" "${DX_STATE_DIR}/${sid}.terminal-commit" "${DX_STATE_DIR}/${sid}.overrides" 2>/dev/null || true
    rm -f "${DX_STATE_DIR}/${sid}.override-lock/owner" 2>/dev/null || true
    rmdir "${DX_STATE_DIR}/${sid}.override-lock" 2>/dev/null || true
  fi
  return "$completion_revoke_result"
}

__dx_review_credit_session_from_path() {
  [[ $# -eq 1 ]] || return 1
  local name="${1##*/}" session_id
  case "$name" in
    *.review-ledger) session_id="${name%.review-ledger}" ;;
    *.review-proofs) session_id="${name%.review-proofs}" ;;
    *) return 1 ;;
  esac
  dx_session_id_valid "$session_id" || return 1
  printf '%s\n' "$session_id"
}

# dx_cleanup_stale_review_credit <max-age-days>
# Remove stale ledgers and their retained proof bundles as one unit.
dx_cleanup_stale_review_credit() {
  [[ $# -eq 1 ]] || return 1
  local max_age_days="$1" credit_path session_id cleanup_count=0 cleanup_status=0
  case "$max_age_days" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [[ -d "$DX_LOOP_DIR" ]] || {
    printf '%s\n' "0"
    return 0
  }

  while IFS= read -r -d '' credit_path; do
    session_id=$(__dx_review_credit_session_from_path "$credit_path") || {
      cleanup_status=1
      continue
    }
    if dx_review_ledger_reset "$session_id"; then
      cleanup_count=$((cleanup_count + 1))
    else
      cleanup_status=1
    fi
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -name '*.review-ledger' -mtime +"$max_age_days" -print0 2>/dev/null)

  while IFS= read -r -d '' credit_path; do
    session_id=$(__dx_review_credit_session_from_path "$credit_path") || {
      cleanup_status=1
      continue
    }
    if dx_review_ledger_reset "$session_id"; then
      cleanup_count=$((cleanup_count + 1))
    else
      cleanup_status=1
    fi
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 \( -type d -o -type l \) \
    -name '*.review-proofs' -mtime +"$max_age_days" -print0 2>/dev/null)

  printf '%s\n' "$cleanup_count"
  return "$cleanup_status"
}

# Remove every phase and loop artifact scoped to the current repository. This
# also covers in-place sessions and worktrees that no longer exist on disk.
dx_cleanup_repo_sessions() {
  local repo_key last_session_file last_info last_path repo_root remainder state_dir prefix
  local credit_path credit_session

  repo_key=$(dx_session_repo_key) || return 1
  if [[ -d "$DX_LOOP_DIR" ]]; then
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      while IFS= read -r -d '' credit_path; do
        credit_session=$(__dx_review_credit_session_from_path "$credit_path") || return 1
        dx_review_ledger_reset "$credit_session" || return 1
      done < <(find "$DX_LOOP_DIR" -maxdepth 1 \
        \( -name "${prefix}${repo_key}-*.review-ledger" -o \
           -name "${prefix}${repo_key}-*.review-proofs" \) -print0)
    done
  fi
  for state_dir in "$DX_LOOP_DIR" "$DX_STATE_DIR"; do
    [[ -d "$state_dir" ]] || continue
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      find "$state_dir" -maxdepth 1 -type f -name "${prefix}${repo_key}-*" \
        -exec rm -f {} + || return $?
    done
  done

  last_session_file="$DX_STATE_DIR/last-session"
  [[ -f "$last_session_file" ]] || return 0
  last_info=$(cat "$last_session_file" 2>/dev/null) || return 0
  remainder=${last_info#*:}
  [[ "$remainder" != "$last_info" ]] || return 0
  last_path=${remainder%%:*}
  last_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$last_path" 2>/dev/null) || return 0
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  repo_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 0
  if [[ "$last_path" == "$repo_root" || "$last_path" == "$repo_root/.dex/worktrees/"* ]]; then
    rm -f "$last_session_file"
  fi
}

__dx_session_artifact_matches_checkout() {
  local artifact_name="$1" checkout_session="$2" prefix

  for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
    case "$artifact_name" in
      "${prefix}${checkout_session}".*|"${prefix}${checkout_session}"-*) return 0 ;;
    esac
  done
  return 1
}

# Remove state tied to the checkout running uninit without disturbing another
# initialized worktree in the same repository.
dx_cleanup_current_checkout_sessions() {
  local current_root base_session repo_key meta_file session_id meta_root worktree_output
  local last_session_file last_info remainder last_path state_dir prefix
  local candidate name stem suffix pid epoch tail random line worktree_path sibling_root
  local sibling_session protected_sessions="" git_status protected

  current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  current_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$current_root" 2>/dev/null) || return 1
  base_session=$(dx_session_id) || return 1
  repo_key=$(dx_session_repo_key) || return 1
  if worktree_output=$(git worktree list --porcelain 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree_path=${line#worktree }
        sibling_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
          "$worktree_path" 2>/dev/null) || continue
        [[ "$sibling_root" != "$current_root" ]] || continue
        # A pruned or manually deleted worktree still appears in the porcelain
        # listing; skip it rather than abandoning the whole cleanup.
        sibling_session=$(cd "$worktree_path" 2>/dev/null && dx_session_id) || continue
        protected_sessions="${protected_sessions}${sibling_session}
"
        ;;
    esac
  done < <(printf '%s\n' "$worktree_output")

  for state_dir in "$DX_LOOP_DIR" "$DX_STATE_DIR"; do
    [[ -d "$state_dir" ]] || continue
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      stem="${prefix}${base_session}"
      while IFS= read -r candidate; do
        name=$(basename "$candidate")
        protected=0
        while IFS= read -r sibling_session; do
          [[ -n "$sibling_session" ]] || continue
          if __dx_session_artifact_matches_checkout "$name" "$sibling_session"; then
            protected=1
            break
          fi
        done <<EOF
$protected_sessions
EOF
        [[ "$protected" == "0" ]] || continue
        case "$name" in
          "$stem".*)
            rm -f "$candidate"
            ;;
          "$stem"-*)
            suffix=${name#"$stem"-}
            pid=${suffix%%-*}
            tail=${suffix#*-}
            [[ "$tail" != "$suffix" ]] || continue
            epoch=${tail%%-*}
            tail=${tail#*-}
            [[ "$tail" != "$epoch" ]] || continue
            random=${tail%%.*}
            [[ "$random" != "$tail" ]] || continue
            case "$pid" in ""|*[!0-9]*) continue ;; esac
            case "$epoch" in ""|*[!0-9]*) continue ;; esac
            case "$random" in ""|*[!0-9]*) continue ;; esac
            rm -f "$candidate"
            ;;
        esac
      done < <(find "$state_dir" -maxdepth 1 -type f -print 2>/dev/null)
    done
  done

  if [[ -d "$DX_STATE_DIR" ]]; then
    while IFS= read -r meta_file; do
      meta_root=$(awk -F= '$1 == "wt_dir" { sub(/^[^=]*=/, ""); print; exit }' \
        "$meta_file" 2>/dev/null)
      [[ -n "$meta_root" ]] || continue
      meta_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
        "$meta_root" 2>/dev/null) || continue
      [[ "$meta_root" == "$current_root" ]] || continue
      session_id=$(basename "$meta_file" .meta)
      dx_cleanup_session "$session_id"
    done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" \
      -print 2>/dev/null)
  fi

  last_session_file="$DX_STATE_DIR/last-session"
  [[ -f "$last_session_file" ]] || return 0
  last_info=$(cat "$last_session_file" 2>/dev/null) || return 0
  remainder=${last_info#*:}
  [[ "$remainder" != "$last_info" ]] || return 0
  last_path=${remainder%%:*}
  last_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$last_path" 2>/dev/null) || return 0
  if [[ "$last_path" == "$current_root" ]]; then
    rm -f "$last_session_file"
  fi
}

# Atomic state-file writer, moved out of dx.sh: it is a generic helper with
# no lifecycle knowledge and several callers.

# __dx_write_state <file> <content>
# Atomic file write via temp+mv — crash-safe (same pattern as phase-loop.sh).
# On crash mid-write, the temp file is lost and the original is untouched.
__dx_write_state() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  if ! printf '%s\n' "$content" >| "$tmp" || ! command mv -f "$tmp" "$file"; then
    command rm -f "$tmp" 2>/dev/null
    return 1
  fi
}
