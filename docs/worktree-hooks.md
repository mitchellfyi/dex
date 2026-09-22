# Worktree hooks

A Dex worktree is not only a directory. Depending on the repository it may also
be a database, a port, a container, a seeded fixture set, a compiled artifact
tree. Dex creates and removes the directory; it cannot guess what else your
repository stood up beside it, and it will not run a command you did not ask
for.

So the repository says. A fenced YAML block under `## Worktree Hooks` in
`.dex/dex.md` names the commands Dex runs at the moments it owns:

```yaml
after_create: bin/dex-worktree up
before_remove: bin/dex-worktree down
on_session_end: bin/dex-worktree release-ports
orphan_resources: bin/dex-worktree orphans
```

Every key is optional, and so is the whole section. With none of it, every
path below still works and runs nothing.

## The four keys

| Key | When Dex runs it |
|-----|------------------|
| `after_create` | Once, right after a new worktree is created and its shared caches are linked. Not on resume — an existing worktree was already stood up. |
| `before_remove` | Before a worktree is removed, on every removal path Dex has. |
| `on_session_end` | When a provider session ends — which in a lifecycle is once per phase, not once per ticket. It runs before the session reaps its processes, so whatever the hook starts is reaped with the rest. |
| `orphan_resources` | On demand, by `dx worktree audit` and by `dxclean`. It prints one orphan per line and removes nothing. Scope what it enumerates to `DX_REPO_ROOT`: the live-worktree guard is checkout-scoped, so a probe that names another checkout's resources would offer them for teardown. |

Each value is **one shell command string**. A list is refused with a warning
rather than run as a sequence, because "run these in order" and "here are four
names" read the same in YAML and only one of them is safe to guess at. Put the
sequence in a script and name the script.

## What the command gets

| Variable | Value |
|----------|-------|
| `DX_WORKTREE_NAME` | The worktree's directory name (`ticket-142`, `task-fix-login`). For an in-place session (`dx --no-worktree`) there is no worktree, so it is the repository directory's own name. |
| `DX_WORKTREE_PATH` | Its absolute path, whether or not the directory still exists |
| `DX_TICKET` | The ticket ID when Dex knows one, empty otherwise |
| `DX_REPO_ROOT` | The main checkout, which is where `.dex/dex.md` lives |

The command runs in the worktree. When the directory is already gone — an
orphan the audit found, a removal that raced — it runs in the main checkout
instead, because a teardown still has a database or a port to free.

It also inherits the session ownership token, so anything it leaves running is
still the session's and is reaped at session end like everything else. See
[host-budget.md](host-budget.md) for what else a session accounts for.

## Failure is not fatal

A hook gets `DEX_WORKTREE_HOOK_TIMEOUT` seconds (300 by default; `0` removes
the deadline). Past that its process tree is stopped.

`on_session_end` is the exception: the host gives the whole SessionEnd hook
ten seconds, and the process reap and temp-root cleanup the session depends on
run after the project's command. So that one call is capped at **five
seconds** whatever `DEX_WORKTREE_HOOK_TIMEOUT` says — a smaller value is still
honoured, a larger one and `0` are not. A command that needs longer than five
seconds at session end belongs in `before_remove`, or should hand off to
something the reap can see and stop.

A hook that fails, and a hook that runs long, each produce one warning and are
then stepped over. Removal continues either way. The alternative — a teardown
command that can stop a worktree from being removed — leaves the repository
holding both the resource and the directory that was supposed to free it,
which is the failure this section exists to prevent.

A `## Worktree Hooks` block Dex cannot parse as a flat mapping warns once and
is ignored whole. Read it back the way Dex does:

```bash
python3 scripts/project-contract.py .dex/dex.md "Worktree Hooks" before_remove
```

## Where the hooks run from

`before_remove` is called by `dx_wt_remove` in `lib/worktree.sh`, not by its
callers, so `dxrm`, `dxrm --all` and `dxclean` all reach it and a removal path
added later cannot forget to. The paths outside that function:

| Path | Hook |
|------|------|
| `dx <ticket>` creating a new worktree | `after_create` |
| `dx worktree add-baseline` (the UI-proof before-state checkout) | `after_create` |
| `dx maintain` cutting its run or respond worktree | `after_create` |
| `dxrm`, `dxrm --all`, `dxclean` | `before_remove`, through `dx_wt_remove` |
| `dx worktree remove-baseline` | `before_remove` |
| `dx maintain` removing its respond worktree, including on exit | `before_remove` |
| `dx worktree audit --apply` | `before_remove` |
| `hooks/session-end.sh`, before the reap | `on_session_end` |

Two worktrees deliberately get no `after_create`: the short-lived checkouts
`dx maintain publish` and `dx maintain publish-response` cut to apply a patch
and push it. Nothing builds or tests in them, so standing up a database for
one is pure cost.

## Auditing

Three catalogues drift apart: the directories under `.dex/worktrees/`, the
worktrees git has registered, and whatever the repository stood up alongside
them. `dx worktree audit` prints all three.

```
$ dx worktree audit
Dex — worktree audit: /home/me/app

Worktrees git has registered:
  /home/me/app                                               main checkout
  /home/me/app/.dex/worktrees/ticket-142                     Dex lifecycle worktree

Directories under .dex/worktrees/:
  task-old-spike                                             git does not know it
  ticket-142                                                 registered with git

Orphans this project reports (orphan_resources):
  task-retired-experiment
  ticket-142                    reported, but Dex still has this worktree — not touched

[info]  1 reported name(s) belong to a worktree Dex or git still lists; --apply leaves those alone
[info]  1 unregistered director(ies), 0 stale git registration(s), 1 reported orphan(s)
[info]  Nothing was removed. Re-run as 'dx worktree audit --apply' to run this
        project's before_remove hook for those entries and remove them.
```

**A live worktree is never an orphan.** A probe cannot be expected to know
which worktrees are checked out right now, so Dex checks. Any reported line
that names a directory under `.dex/worktrees/` or a worktree git has
registered is printed as live and is not acted on. Without that check a probe
that listed every database it could see would have `--apply` drop the one
belonging to the worktree someone is working in.

The comparison is deliberately generous, because a wrong answer here deletes a
checkout someone is using. It matches the basename and the full path, in both
the recorded and the physically resolved spelling (`/var/…` and `/private/var/…`
are the same directory), ignores a trailing slash, and folds case — so
`Ticket-142` is held back alongside `ticket-142` even on a case-sensitive
filesystem where they could in principle be two directories. `dx worktree
audit --apply` and `dxclean --apply` both go through
`dx_worktree_name_is_live` in `lib/worktree.sh`, so one rule decides for both.

The probe's own outcome is reported as one of four things, because "clean"
and "Dex could not tell" are different answers:

| Output | Meaning |
|--------|---------|
| the lines | the probe ran and reported these |
| `(this project declares no orphan_resources probe)` | there is nothing to run |
| `(the probe ran and reported nothing)` | it ran, and this repository is clean |
| `(the probe failed; Dex cannot tell whether this project is clean)` | it crashed or hit the deadline; the warning above says which |

`--apply` acts on exactly what was printed as an orphan, and only inside
`.dex/worktrees/`: it runs `before_remove` for each unregistered directory and
then removes it, runs `before_remove` for each stale registration and prunes
it, and runs `before_remove` once per reported orphan. A registration outside
`.dex/worktrees/` is listed and left alone.

**What the probe prints is what comes back.** Each line that survives the live
check becomes `DX_WORKTREE_NAME` on a `before_remove` run, verbatim, from the
main checkout. So print the identifier your own `before_remove` keys on —
normally the worktree name that no longer exists — rather than the resource's
internal spelling, or the hook will derive a name from a name it already
derived.

## Writing one

The hook is a command in your repository, so keep the naming derivable from
`DX_WORKTREE_NAME` and make it idempotent — `after_create` may run against a
half-built worktree, and `before_remove` may run twice if a removal was
interrupted.

```bash
#!/usr/bin/env bash
# bin/dex-worktree — stand a worktree's database up and take it down again
set -euo pipefail
db="app_dev_${DX_WORKTREE_NAME//-/_}"
case "${1:-}" in
  up)      createdb "$db" 2>/dev/null || true; DATABASE_NAME="$db" bin/setup ;;
  down)    dropdb --if-exists "$db" ;;
  # Print worktree names, not database names: `dx worktree audit --apply`
  # hands each line straight back to the `down` arm above.
  orphans)
    psql -Atc "SELECT datname FROM pg_database WHERE datname LIKE 'app_dev_%'" \
      | sed 's/^app_dev_//; s/_/-/g' \
      | while read -r name; do
          [ -d "$DX_REPO_ROOT/.dex/worktrees/$name" ] || printf '%s\n' "$name"
        done
    ;;
esac
```

The `orphans` arm answers a different question from the other two: not "what
does this worktree own" but "what does this repository still hold that no
worktree owns". Filtering it against the live worktrees is the probe's job —
Dex prints what the probe reports and hands it back unchanged.
