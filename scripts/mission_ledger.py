#!/usr/bin/env python3
"""Mission ledger: the durable record a Dex mission is rebuilt from.

    mission_ledger.py <ledger-dir> init --mission-id ID --brief-file PATH --workspace PATH
                      --branch NAME --base-revision SHA [--source-tickets A,B] [--actor WHO]
    mission_ledger.py <ledger-dir> record <kind> --json '{...}' [--actor WHO]
    mission_ledger.py <ledger-dir> lease acquire --holder WHO --scope a,b --revision SHA [--actor WHO]
    mission_ledger.py <ledger-dir> lease release --holder WHO [--revision-after SHA] [--actor WHO]
    mission_ledger.py <ledger-dir> lease show
    mission_ledger.py <ledger-dir> show | verify | rebuild

`records.jsonl` is append-only and is the truth; `current.json` is a snapshot
folded from it and can be rebuilt at any time. Every record carries a
generation that only ever grows, the actor who wrote it, and a UTC timestamp.
Writes hold a lock, append with fsync, then replace the snapshot the way
completion receipts are written (temp file, fsync, replace, mode 0600). Reads
refuse a snapshot that is no longer a private regular file. The write lease is
exclusive: one holder at a time, released only by that holder.

Write commands print {"event_type", "generation", "record"} so a shell caller
can journal the change. Exit codes: 0 ok, 1 verification failed, 2 usage or an
unsafe or unreadable ledger, 3 refused (lease held by someone else, or init on
an existing ledger).
"""

import argparse
import fcntl
import json
import os
import stat
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dex_private_files import append_line, atomic_write  # noqa: E402

SCHEMA_VERSION = 1
KINDS = (
    "mission",
    "assignment",
    "write-lease",
    "decision",
    "evidence-link",
    "selfcheck",
    "observation-ref",
    "feedback-ref",
    "note",
)
EXIT_VERIFY = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3


class LedgerError(Exception):
    def __init__(self, message, code=EXIT_USAGE):
        super().__init__(message)
        self.code = code


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def records_path(ledger_dir):
    return os.path.join(ledger_dir, "records.jsonl")


def current_path(ledger_dir):
    return os.path.join(ledger_dir, "current.json")


def check_private(path, kind="file"):
    """Refuse anything that is not our own private regular file or directory."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISLNK(info.st_mode):
        raise LedgerError(f"{path}: symlinks are not trusted")
    if kind == "dir" and not stat.S_ISDIR(info.st_mode):
        raise LedgerError(f"{path}: not a directory")
    if kind == "file" and not stat.S_ISREG(info.st_mode):
        raise LedgerError(f"{path}: not a regular file")
    if info.st_uid != os.getuid():
        raise LedgerError(f"{path}: owned by another user")
    if info.st_mode & 0o077:
        raise LedgerError(f"{path}: not private (mode {oct(info.st_mode & 0o777)})")
    if kind == "file" and info.st_nlink != 1:
        raise LedgerError(f"{path}: hard-linked")
    return info


def ensure_dir(ledger_dir):
    if check_private(ledger_dir, "dir") is None:
        os.makedirs(ledger_dir, mode=0o700, exist_ok=True)
        os.chmod(ledger_dir, 0o700)
        check_private(ledger_dir, "dir")


class Lock:
    def __init__(self, ledger_dir):
        self.path = os.path.join(ledger_dir, ".lock")
        self.descriptor = None

    def __enter__(self):
        self.descriptor = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.descriptor, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        os.close(self.descriptor)


def empty_state():
    return {
        "schema_version": SCHEMA_VERSION,
        "generation": 0,
        "mission": None,
        "lease": None,
        "lease_generations": 0,
        "assignments": {},
        "decisions": [],
        "selfchecks": [],
        "evidence": [],
        "counts": {kind: 0 for kind in KINDS},
    }


def apply_record(state, record):
    kind = record["kind"]
    fields = record.get("fields", {})
    state["counts"][kind] = state["counts"].get(kind, 0) + 1
    if kind == "mission":
        state["mission"] = dict(fields)
    elif kind == "decision":
        state["decisions"].append(
            {"generation": record["generation"], "recorded_at": record["recorded_at"], **fields}
        )
    elif kind == "assignment":
        identity = str(fields.get("id") or record["generation"])
        merged = dict(state["assignments"].get(identity, {}))
        merged.update(fields)
        merged["updated_generation"] = record["generation"]
        state["assignments"][identity] = merged
    elif kind == "write-lease":
        if fields.get("action") == "acquire":
            state["lease_generations"] += 1
            state["lease"] = {
                "holder": fields["holder"],
                "scope": fields.get("scope", []),
                "revision_before": fields.get("revision"),
                "lease_generation": state["lease_generations"],
                "acquired_generation": record["generation"],
                "acquired_at": record["recorded_at"],
            }
        elif fields.get("action") == "release":
            state["lease"] = None
    elif kind == "selfcheck":
        state["selfchecks"].append({"generation": record["generation"], **fields})
    elif kind == "evidence-link":
        state["evidence"].append({"generation": record["generation"], **fields})
    state["generation"] = record["generation"]
    return state


def read_records(ledger_dir):
    path = records_path(ledger_dir)
    if check_private(path) is None:
        return []
    records = []
    expected = 0
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError as error:
                raise LedgerError(f"records.jsonl line {number}: not JSON ({error})", EXIT_VERIFY)
            if record.get("schema_version") != SCHEMA_VERSION or record.get("kind") not in KINDS:
                raise LedgerError(f"records.jsonl line {number}: unknown schema or kind", EXIT_VERIFY)
            expected += 1
            if record.get("generation") != expected:
                raise LedgerError(
                    f"records.jsonl line {number}: generation {record.get('generation')} is not {expected}",
                    EXIT_VERIFY,
                )
            records.append(record)
    return records


def fold(records):
    state = empty_state()
    for record in records:
        apply_record(state, record)
    return state


def load_state(ledger_dir):
    path = current_path(ledger_dir)
    if check_private(path) is None:
        return None
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_state(ledger_dir, state):
    state = dict(state)
    state["snapshot_at"] = utc_now()
    atomic_write(current_path(ledger_dir), json.dumps(state, sort_keys=True, indent=1) + "\n")


def write_record(ledger_dir, kind, fields, actor):
    if kind not in KINDS:
        raise LedgerError(f"unknown record kind: {kind}")
    ensure_dir(ledger_dir)
    with Lock(ledger_dir):
        state = load_state(ledger_dir)
        if state is None:
            state = fold(read_records(ledger_dir))
        generation = int(state.get("generation", 0)) + 1
        record = {
            "schema_version": SCHEMA_VERSION,
            "kind": kind,
            "generation": generation,
            "recorded_at": utc_now(),
            "actor": actor,
            "fields": fields,
        }
        append_line(records_path(ledger_dir), json.dumps(record, sort_keys=True))
        state.pop("snapshot_at", None)
        apply_record(state, record)
        write_state(ledger_dir, state)
    return record, state


def event_type_for(record):
    kind = record["kind"]
    fields = record.get("fields", {})
    if kind == "mission":
        return "mission.started"
    if kind == "write-lease":
        return f"mission.lease.{'acquired' if fields.get('action') == 'acquire' else 'released'}"
    if kind == "assignment":
        state = str(fields.get("status") or "updated").lower()
        return f"mission.assignment.{state}"
    return {
        "decision": "mission.decision",
        "selfcheck": "mission.selfcheck",
        "evidence-link": "mission.evidence.linked",
        "observation-ref": "mission.observation",
        "feedback-ref": "mission.feedback",
        "note": "mission.note",
    }[kind]


def emit(record, state):
    print(
        json.dumps(
            {
                "event_type": event_type_for(record),
                "generation": record["generation"],
                "record": record,
                "lease": state.get("lease"),
            },
            sort_keys=True,
        )
    )


def parse_json_arg(text):
    try:
        value = json.loads(text or "{}")
    except ValueError as error:
        raise LedgerError(f"--json is not valid JSON: {error}")
    if not isinstance(value, dict):
        raise LedgerError("--json must be an object")
    return value


def split_list(text):
    return [item for item in (text or "").split(",") if item]


def cmd_init(ledger_dir, args):
    if check_private(records_path(ledger_dir)) is not None:
        raise LedgerError("ledger already initialised; refusing to overwrite", EXIT_REFUSED)
    with open(args.brief_file, encoding="utf-8") as handle:
        brief = handle.read()
    fields = {
        "mission_id": args.mission_id,
        "brief_file": os.path.abspath(args.brief_file),
        "brief_sha256": __import__("hashlib").sha256(brief.encode("utf-8")).hexdigest(),
        "workspace": args.workspace,
        "branch": args.branch,
        "base_revision": args.base_revision,
        "source_tickets": split_list(args.source_tickets),
        "dex_version": args.dex_version,
    }
    record, state = write_record(ledger_dir, "mission", fields, args.actor)
    emit(record, state)


def cmd_record(ledger_dir, args):
    record, state = write_record(ledger_dir, args.kind, parse_json_arg(args.json), args.actor)
    emit(record, state)


def current_state(ledger_dir):
    state = load_state(ledger_dir)
    if state is None:
        state = fold(read_records(ledger_dir))
    return state


def cmd_lease(ledger_dir, args):
    if args.lease_command == "show":
        print(json.dumps(current_state(ledger_dir).get("lease") or {}, sort_keys=True))
        return
    ensure_dir(ledger_dir)
    with Lock(ledger_dir):
        state = current_state(ledger_dir)
        lease = state.get("lease")
        if args.lease_command == "acquire":
            if lease and lease.get("holder") != args.holder:
                raise LedgerError(
                    f"write lease held by {lease['holder']} since {lease['acquired_at']}; "
                    f"{args.holder} must wait or return a patch",
                    EXIT_REFUSED,
                )
            fields = {
                "action": "acquire",
                "holder": args.holder,
                "scope": split_list(args.scope),
                "revision": args.revision,
            }
        else:
            if not lease:
                raise LedgerError("no write lease is held", EXIT_REFUSED)
            if lease.get("holder") != args.holder:
                raise LedgerError(
                    f"write lease is held by {lease['holder']}, not {args.holder}", EXIT_REFUSED
                )
            fields = {
                "action": "release",
                "holder": args.holder,
                "revision_after": args.revision_after,
                "lease_generation": lease.get("lease_generation"),
            }
    record, state = write_record(ledger_dir, "write-lease", fields, args.actor or args.holder)
    emit(record, state)


def cmd_show(ledger_dir, _args):
    print(json.dumps(current_state(ledger_dir), sort_keys=True, indent=1))


def cmd_verify(ledger_dir, _args):
    records = read_records(ledger_dir)
    rebuilt = fold(records)
    snapshot = load_state(ledger_dir)
    if snapshot is not None:
        snapshot = dict(snapshot)
        snapshot.pop("snapshot_at", None)
        if snapshot != rebuilt:
            raise LedgerError("current.json does not match the records", EXIT_VERIFY)
    print(json.dumps({"ok": True, "records": len(records), "generation": rebuilt["generation"]}))


def cmd_rebuild(ledger_dir, _args):
    ensure_dir(ledger_dir)
    with Lock(ledger_dir):
        state = fold(read_records(ledger_dir))
        write_state(ledger_dir, state)
    print(json.dumps({"rebuilt": True, "generation": state["generation"]}))


def build_parser():
    parser = argparse.ArgumentParser(description="Dex mission ledger")
    parser.add_argument("ledger_dir")
    sub = parser.add_subparsers(dest="command", required=True)
    default_actor = os.environ.get("DX_MISSION_ACTOR", "lead")

    init = sub.add_parser("init")
    init.add_argument("--mission-id", required=True)
    init.add_argument("--brief-file", required=True)
    init.add_argument("--workspace", required=True)
    init.add_argument("--branch", required=True)
    init.add_argument("--base-revision", required=True)
    init.add_argument("--source-tickets", default="")
    init.add_argument("--dex-version", default=os.environ.get("DX_DEX_VERSION"))
    init.add_argument("--actor", default=default_actor)
    init.set_defaults(func=cmd_init)

    record = sub.add_parser("record")
    record.add_argument("kind")
    record.add_argument("--json", default="{}")
    record.add_argument("--actor", default=default_actor)
    record.set_defaults(func=cmd_record)

    lease = sub.add_parser("lease")
    lease.add_argument("lease_command", choices=("acquire", "release", "show"))
    lease.add_argument("--holder")
    lease.add_argument("--scope", default="")
    lease.add_argument("--revision")
    lease.add_argument("--revision-after")
    lease.add_argument("--actor", default=None)
    lease.set_defaults(func=cmd_lease)

    for name, func in (("show", cmd_show), ("verify", cmd_verify), ("rebuild", cmd_rebuild)):
        sub.add_parser(name).set_defaults(func=func)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "lease" and args.lease_command != "show" and not args.holder:
        print("mission_ledger: lease acquire/release need --holder", file=sys.stderr)
        return EXIT_USAGE
    try:
        args.func(os.path.abspath(args.ledger_dir), args)
    except LedgerError as error:
        print(f"mission_ledger: {error}", file=sys.stderr)
        return error.code
    except (OSError, ValueError) as error:
        print(f"mission_ledger: {error}", file=sys.stderr)
        return EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main())
