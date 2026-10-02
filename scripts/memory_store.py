#!/usr/bin/env python3
"""The external memory store: observations before they are promoted.

    memory_store.py <store-dir> ingest --repo DIR [--source LABEL] [--revision SHA] <file|->
    memory_store.py <store-dir> retrieve --repo DIR --paths a,b [--session S] [--role R]
                                [--phase P] [--limit N] [--include-measurements]
    memory_store.py <store-dir> recheck --repo DIR
    memory_store.py <store-dir> maintain --repo DIR [--now ISO] [--stale-days N]
                                [--idle-days N] [--unused-days N]
    memory_store.py <store-dir> review-export --repo DIR [--now ISO]
                                [--min-changes N] [--max-age-days N]
    memory_store.py <store-dir> curate-apply --repo DIR --actor NAME [--now ISO] <decisions.json>
    memory_store.py <store-dir> materialize --repo DIR --out-repo DIR [--now ISO] [--write]
    memory_store.py <store-dir> mark-landed --commit SHA [--pr URL] [--now ISO] <plan.json>
    memory_store.py <store-dir> verify | show

prompts/sync-memory.md says raw observations are not trusted memory and live
outside the repository. This is that place. One store per repository identity
(lib/memory.sh picks the directory). Files:

  observations.jsonl   every ingested row, append-only, with its id and source
  entries.json         one entry per distinct (scope, lesson): type, trust,
                       status, evidence, what it depends on, how often seen
  curated-overlay.json status overrides for .dex/memory entries (needs-recheck)
  retrieval.log        one JSON line per retrieval: what was loaded and why not

Ingest validates each row (lesson, evidence, scope, type), checks the evidence
against the repository, and records `path@blob` dependencies for every file it
names. A fact, procedure or decision whose evidence names a real file is
active; a hypothesis, or a fact with nothing checkable, is a candidate; a
measurement is calibration, kept but not retrieved by default. Missing
evidence is rejected. Repeats of the same lesson raise `seen`; they do not
become new entries.

Retrieve reads the curated domain files (`.dex/memory/domains/*.md`) and the
store, returns the active entries whose paths match, and writes a trace. An
entry marked needs-recheck is named as stale rather than shown as current.
Recheck compares each dependency's current blob with the recorded one.

The store keeps itself in check; no human queue sits behind it. Maintain
promotes a candidate that two independent sessions reported, retires an
entry that stayed stale past its window, an idle candidate, or an active
entry no session retrieved in a long time, and reopens a retired lesson when
it is observed again. Review-export is what the curator (a fresh, bounded
model session run by bin/memory.sh) reads, with a `due` verdict so the model
is asked only when enough changed. Curate-apply validates each decision (an
id the store has, a reason, a live merge target) and applies the valid ones.
Decisions about `.dex/memory` entries go to the overlay.

Trusted memory lands in the repository on its own. Materialize renders each
curator-promoted entry that names at least one file into the entry format of
`.dex/memory/domains/<domain>.md`, adds its index row, and applies the
overlay's status decisions to existing entries as itemised edits; it never
rewrites a block it did not create. `bin/memory.sh land` runs it in a
throwaway worktree and commits; mark-landed then records the commit (or
`working-tree` for an in-place landing) so nothing lands twice. Once the
tracked entry is in the checkout, retrieval serves it and skips the store copy.

Standard library only. Exit 0 ok, 1 verify failed or unusable input, 2 usage.
"""

import argparse
import fnmatch
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dex_private_files import PrivateFileError, append_line, atomic_write, private_file_ok  # noqa: E402

SCHEMA_VERSION = 1
SCOPES = ("repo", "environment", "mission")
TYPES = ("fact", "decision", "procedure", "measurement", "hypothesis")
RETRIEVABLE_TYPES = ("fact", "decision", "procedure")
PATH_RE = re.compile(r"(?<![\w@/])((?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,8})(?:@([0-9a-f]{7,40})|:(\d+)|#L(\d+))?")


class StoreError(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def private_path_ok(path):
    try:
        return private_file_ok(path)
    except PrivateFileError as error:
        raise StoreError(str(error))


def ensure_store(store_dir):
    os.makedirs(store_dir, mode=0o700, exist_ok=True)
    os.chmod(store_dir, 0o700)


def load_json(path, default):
    if not private_path_ok(path):
        return default
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path, data):
    atomic_write(path, json.dumps(data, sort_keys=True, indent=1) + "\n")


def entries_path(store_dir):
    return os.path.join(store_dir, "entries.json")


def load_entries(store_dir):
    data = load_json(entries_path(store_dir), None)
    if data is None:
        return {"schema_version": SCHEMA_VERSION, "entries": {}}
    return data


def git_blob(repo, relpath):
    try:
        out = subprocess.run(
            ["git", "-C", repo, "hash-object", "--", relpath],
            capture_output=True, text=True, check=True, timeout=10,
        )
        return out.stdout.strip() or None
    except (subprocess.SubprocessError, OSError):
        return None


def evidence_dependencies(repo, evidence):
    """Files the evidence names that exist in the repository, as path@blob."""
    found = []
    seen = set()
    for match in PATH_RE.finditer(evidence or ""):
        relpath = match.group(1).lstrip("./")
        if not relpath or relpath in seen:
            continue
        absolute = os.path.join(repo, relpath)
        if not os.path.isfile(absolute):
            continue
        blob = git_blob(repo, relpath)
        if not blob:
            continue
        seen.add(relpath)
        found.append(f"{relpath}@{blob}")
    return found


def lesson_key(scope, lesson):
    normalised = re.sub(r"\s+", " ", lesson.strip().lower())
    return hashlib.sha256(f"{scope}|{normalised}".encode("utf-8")).hexdigest()[:16]


def validate(row):
    if not isinstance(row, dict):
        return None, "not an object"
    lesson = row.get("lesson")
    if not isinstance(lesson, str) or len(lesson.strip()) < 8:
        return None, "missing lesson"
    evidence = row.get("evidence")
    if not isinstance(evidence, str) or len(evidence.strip()) < 4:
        return None, "missing evidence"
    scope = str(row.get("scope", "mission"))
    if scope not in SCOPES:
        return None, f"unknown scope {scope}"
    kind = str(row.get("type", "hypothesis"))
    if kind not in TYPES:
        return None, f"unknown type {kind}"
    return {"lesson": lesson.strip()[:600], "evidence": evidence.strip()[:600], "scope": scope, "type": kind}, None


def cmd_ingest(store_dir, args):
    ensure_store(store_dir)
    repo = os.path.abspath(args.repo)
    source = args.source or "manual"
    handle = sys.stdin if args.file == "-" else open(args.file, encoding="utf-8")
    data = load_entries(store_dir)
    entries = data["entries"]
    ingested = duplicates = 0
    rejected = []
    now = utc_now()
    with handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except ValueError:
                rejected.append({"lesson": raw[:80], "reason": "not JSON"})
                append_line(os.path.join(store_dir, "observations.jsonl"), json.dumps({
                    "lesson": raw[:120], "rejected": "not JSON", "source": source, "ingested_at": now,
                }, sort_keys=True))
                continue
            clean, reason = validate(row)
            if clean is None:
                lesson_text = str(row.get("lesson", "") if isinstance(row, dict) else raw)[:120]
                rejected.append({"lesson": lesson_text, "reason": reason})
                # Kept in the raw log with its reason: a rejection is evidence too.
                append_line(os.path.join(store_dir, "observations.jsonl"), json.dumps({
                    "lesson": lesson_text, "rejected": reason, "source": source, "ingested_at": now,
                }, sort_keys=True))
                continue
            if clean["type"] == "measurement" and clean["scope"] == "repo":
                clean["scope"] = "environment"
            identity = lesson_key(clean["scope"], clean["lesson"])
            depends = evidence_dependencies(repo, clean["evidence"])
            source_checked = bool(depends)
            if clean["type"] == "hypothesis" or (clean["type"] in RETRIEVABLE_TYPES and not source_checked):
                status = "candidate"
            else:
                status = "active"
            observation = dict(clean)
            observation.update({
                "id": identity, "source": source, "ingested_at": now,
                "revision": args.revision or (row.get("revision") if isinstance(row, dict) else None),
                "agent_id": row.get("agent_id") if isinstance(row, dict) else None,
            })
            append_line(os.path.join(store_dir, "observations.jsonl"), json.dumps(observation, sort_keys=True))
            if identity in entries:
                entry = entries[identity]
                entry["seen"] = int(entry.get("seen", 1)) + 1
                entry["last_seen"] = now
                if entry.get("status") == "retired":
                    # Observed again after retirement: the lesson is back on
                    # probation, with its history kept.
                    entry["status"] = status
                    entry["reopened_at"] = now
                    for key in ("retired_reason", "retired_at", "retired_by", "merged_into"):
                        entry.pop(key, None)
                if source not in entry.setdefault("sources", []):
                    entry["sources"].append(source)
                if depends and not entry.get("depends_on"):
                    entry["depends_on"] = depends
                    entry["source_checked"] = True
                    if entry.get("status") == "candidate" and entry["type"] in RETRIEVABLE_TYPES:
                        entry["status"] = "active"
                duplicates += 1
                ingested += 1
            else:
                entries[identity] = {
                    "id": identity, "lesson": clean["lesson"], "evidence": clean["evidence"],
                    "scope": clean["scope"], "type": clean["type"], "status": status,
                    "trust": "verified" if source_checked else "candidate",
                    "source_checked": source_checked, "depends_on": depends,
                    "seen": 1, "sources": [source], "first_seen": now, "last_seen": now,
                    "repo": repo,
                }
                ingested += 1
    save_json(entries_path(store_dir), data)
    print(json.dumps({"ingested": ingested, "duplicates": duplicates, "rejected": rejected,
                      "store_entries": len(entries)}, sort_keys=True))


FIELD_RE = re.compile(r"^([A-Z][A-Za-z ]+):\s*(.*)$")


def parse_curated(repo):
    """Entries from .dex/memory/domains/*.md: id, title, fields, lesson."""
    results = []
    for path in sorted(glob.glob(os.path.join(repo, ".dex", "memory", "domains", "*.md"))):
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        blocks = re.split(r"^## (M-\d+):\s*(.*)$", text, flags=re.M)
        for index in range(1, len(blocks) - 2, 3):
            identity, title, body = blocks[index], blocks[index + 1].strip(), blocks[index + 2]
            fields = {}
            lesson = ""
            section = None
            for line in body.splitlines():
                if line.strip() in ("Lesson:", "Evidence:", "Future agent behavior:"):
                    section = line.strip()[:-1]
                    continue
                if section is None:
                    match = FIELD_RE.match(line.strip())
                    if match:
                        fields[match.group(1).strip().lower()] = match.group(2).strip()
                elif section == "Lesson" and line.strip():
                    lesson += (" " if lesson else "") + line.strip()
            results.append({
                "id": identity, "title": title, "file": os.path.relpath(path, repo),
                "status": fields.get("status", "unknown").lower(),
                "paths": [p.strip() for p in fields.get("applies to paths", "").split(",") if p.strip()],
                "phases": [p.strip() for p in fields.get("applies to phases", "").split(",") if p.strip()],
                "recheck": fields.get("recheck when", ""),
                "depends_on": [p.strip() for p in fields.get("depends on", "").split(",") if p.strip()],
                "lesson": lesson,
            })
    return results


def path_matches(patterns, paths):
    for pattern in patterns:
        for path in paths:
            if pattern.endswith("/") and (path.startswith(pattern) or path.rstrip("/") == pattern.rstrip("/")):
                return True
            if fnmatch.fnmatch(path, pattern) or path == pattern or path.startswith(pattern.rstrip("/") + "/"):
                return True
    return False


# Path words too common to tie a lesson to a file on their own.
PATH_STOPWORDS = {"tests", "hooks", "index", "utils", "common", "scripts", "script", "docs", "readme",
                  "config", "setup", "build", "source", "types", "models", "views", "assets", "public"}


def path_tokens(path):
    """Directory names and file stems of a path worth matching as words."""
    tokens = set()
    for part in re.split(r"[/\\]+", path.lower()):
        if not part:
            continue
        stem = part.rsplit(".", 1)[0] if "." in part else part
        for token in re.split(r"[-_.]+", stem):
            if len(token) >= 5 and token not in PATH_STOPWORDS:
                tokens.add(token)
    return tokens


def text_mentions_paths(text, paths):
    """True when the text names one of the paths, or a distinctive word of one.

    An entry whose evidence is a failure rather than a file has no dependency
    to match on; "the deploy script needs the flag" should still surface for a
    session editing scripts/deploy.sh."""
    lowered = text.lower()
    words = set(re.findall(r"[a-z0-9]+", lowered))
    for path in paths:
        if path in text:
            return True
        if path_tokens(path) & words:
            return True
    return False


def cmd_retrieve(store_dir, args):
    repo = os.path.abspath(args.repo)
    paths = [p.strip() for p in (args.paths or "").split(",") if p.strip()]
    overlay = load_json(os.path.join(store_dir, "curated-overlay.json"), {}) if os.path.isdir(store_dir) else {}
    loaded, skipped, stale, lines = [], [], [], []

    for entry in parse_curated(repo):
        override = overlay.get(entry["id"], {})
        status = override.get("status", entry["status"])
        if status != "active":
            skipped.append({"id": entry["id"], "reason": f"status {status}"})
            if status == "needs-recheck":
                stale.append(entry["id"])
            continue
        if not paths or not path_matches(entry["paths"], paths):
            skipped.append({"id": entry["id"], "reason": "paths do not match"})
            continue
        if args.phase and entry["phases"] and args.phase not in entry["phases"]:
            skipped.append({"id": entry["id"], "reason": f"phase {args.phase} not listed"})
            continue
        loaded.append(entry["id"])
        recheck = f"; recheck when {entry['recheck']}" if entry["recheck"] else ""
        lines.append(f"- [{entry['id']}] {entry['title']}: {entry['lesson'][:300]} (see {entry['file']}{recheck})")

    data = load_entries(store_dir) if os.path.isdir(store_dir) else {"entries": {}}
    tracked_ids = {entry["id"] for entry in parse_curated(repo)}
    observation_lines = []
    for identity, entry in sorted(data["entries"].items()):
        if entry.get("type") == "measurement" and not args.include_measurements:
            continue
        landed_id = (entry.get("landed") or {}).get("id")
        if landed_id and landed_id in tracked_ids:
            skipped.append({"id": f"obs:{identity}", "reason": f"landed as {landed_id}"})
            continue
        if entry.get("scope") not in ("repo", "mission"):
            if not args.include_measurements:
                continue
        dep_paths = [d.split("@", 1)[0] for d in entry.get("depends_on", [])]
        mentions = text_mentions_paths(entry.get("lesson", "") + " " + entry.get("evidence", ""), paths)
        if paths and not (path_matches(dep_paths, paths) or mentions):
            skipped.append({"id": f"obs:{identity}", "reason": "paths do not match"})
            continue
        if entry.get("status") == "needs-recheck":
            stale.append(f"obs:{identity}")
            skipped.append({"id": f"obs:{identity}", "reason": "needs recheck"})
            continue
        if entry.get("status") != "active" or entry.get("type") not in RETRIEVABLE_TYPES:
            skipped.append({"id": f"obs:{identity}", "reason": f"{entry.get('status')} {entry.get('type')}"})
            continue
        loaded.append(f"obs:{identity}")
        label = "curated; " if entry.get("curated") else ""
        line = f"- [obs:{identity}] {entry['lesson']} ({label}evidence: {entry['evidence'][:200]}; seen {entry.get('seen', 1)}x)"
        if entry.get("curated"):
            observation_lines.insert(0, line)
        else:
            observation_lines.append(line)

    if args.limit and len(lines) + len(observation_lines) > args.limit:
        keep = max(args.limit - len(lines), 0)
        dropped = observation_lines[keep:]
        observation_lines = observation_lines[:keep]
        for _ in dropped:
            skipped.append({"id": loaded.pop(), "reason": "limit"})

    output = []
    if lines:
        output.append("Repo memory for these paths (active entries; read the file before relying on one):")
        output.extend(lines)
    if observation_lines:
        output.append("Verified observations not yet promoted to .dex/memory (validated against source when recorded):")
        output.extend(observation_lines)
    if stale:
        output.append(f"Stale, needs recheck before use: {', '.join(stale)}")
    if not output:
        output.append("No scoped memory entries for these paths.")
    text = "\n".join(output)
    print(text)
    if os.path.isdir(store_dir):
        append_line(os.path.join(store_dir, "retrieval.log"), json.dumps({
            "ts": utc_now(), "session": args.session, "role": args.role, "phase": args.phase,
            "paths": paths, "loaded": loaded, "skipped": skipped, "stale": stale, "chars": len(text),
        }, sort_keys=True))


def cmd_recheck(store_dir, args):
    repo = os.path.abspath(args.repo)
    data = load_entries(store_dir)
    stale = []
    restored = []
    checked = 0
    now = utc_now()
    for identity, entry in data["entries"].items():
        drifted = False
        for dependency in entry.get("depends_on", []):
            relpath, _, blob = dependency.partition("@")
            checked += 1
            current = git_blob(repo, relpath) if os.path.isfile(os.path.join(repo, relpath)) else None
            if current != blob:
                if entry.get("status") != "needs-recheck":
                    entry["status"] = "needs-recheck"
                    entry["stale_reason"] = f"{relpath} changed" if current else f"{relpath} missing"
                    entry["stale_at"] = now
                stale.append(identity)
                drifted = True
                break
        # Content back to what was verified: the verification stands again.
        if not drifted and entry.get("status") == "needs-recheck" and entry.get("depends_on"):
            entry["status"] = "active" if entry.get("type") in RETRIEVABLE_TYPES else "candidate"
            entry.pop("stale_reason", None)
            entry.pop("stale_at", None)
            entry["restored_at"] = now
            restored.append(identity)
    overlay_path = os.path.join(store_dir, "curated-overlay.json")
    overlay = load_json(overlay_path, {}) if os.path.isdir(store_dir) else {}
    tracked = parse_curated(repo)
    tracked_ids = {entry["id"] for entry in tracked}
    for entry in data["entries"].values():
        landed = entry.get("landed") or {}
        if landed.get("commit") == "working-tree" and landed.get("id") not in tracked_ids:
            entry.pop("landed", None)
    for entry in tracked:
        for dependency in entry["depends_on"]:
            relpath, _, blob = dependency.partition("@")
            if not blob:
                continue
            checked += 1
            current = git_blob(repo, relpath) if os.path.isfile(os.path.join(repo, relpath)) else None
            if current != blob:
                overlay[entry["id"]] = {"status": "needs-recheck", "reason": f"{relpath} changed", "at": now}
                stale.append(entry["id"])
                break
    ensure_store(store_dir)
    save_json(entries_path(store_dir), data)
    save_json(overlay_path, overlay)
    print(json.dumps({"checked": checked, "stale": sorted(set(stale)), "restored": sorted(set(restored))}, sort_keys=True))


def parse_time(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def days_between(later, earlier):
    a, b = parse_time(later), parse_time(earlier)
    if a is None or b is None:
        return None
    return (a - b).total_seconds() / 86400.0


def retrieval_history(store_dir):
    """Per entry id: how often it was loaded and when last."""
    history = {}
    path = os.path.join(store_dir, "retrieval.log")
    if not os.path.isfile(path):
        return history
    try:
        private_ok = private_path_ok(path)
    except StoreError:
        private_ok = False
    if not private_ok:
        return history
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ts = row.get("ts") or ""
            for loaded in row.get("loaded", []):
                record = history.setdefault(loaded, {"count": 0, "last": ""})
                record["count"] += 1
                if ts > record["last"]:
                    record["last"] = ts
    return history


def distinct_sessions(entry):
    return {source for source in entry.get("sources", []) if source}


def retire(entry, reason, now, actor="maintain"):
    entry["status"] = "retired"
    entry["retired_reason"] = reason
    entry["retired_at"] = now
    entry["retired_by"] = actor


def cmd_maintain(store_dir, args):
    ensure_store(store_dir)
    now = args.now or utc_now()
    if parse_time(now) is None:
        raise StoreError(f"--now must be an ISO UTC time, got {now}")
    data = load_entries(store_dir)
    history = retrieval_history(store_dir)
    promoted, retired = [], []
    for identity, entry in sorted(data["entries"].items()):
        status = entry.get("status")
        if status == "retired":
            continue
        kind = entry.get("type")
        # Two sessions reporting the same lesson independently is the support a
        # checkable file would otherwise give. A session repeating itself is not.
        if status == "candidate" and kind in RETRIEVABLE_TYPES and len(distinct_sessions(entry)) >= 2:
            entry["status"] = "active"
            entry["trust"] = "corroborated"
            entry["promoted_at"] = now
            promoted.append(identity)
            continue
        if status == "needs-recheck":
            age = days_between(now, entry.get("stale_at") or entry.get("last_seen") or "")
            if age is not None and age > args.stale_days:
                reason = entry.get("stale_reason") or "dependency changed"
                retire(entry, f"stale: {reason} {int(age)} days ago, never reverified", now)
                retired.append(identity)
            continue
        used = history.get(f"obs:{identity}", {"count": 0, "last": ""})
        last_touch = max(filter(None, [entry.get("last_seen", ""), used["last"], entry.get("reopened_at", "")]), default="")
        idle = days_between(now, last_touch) if last_touch else None
        if idle is None:
            continue
        if status == "candidate" and idle > args.idle_days:
            retire(entry, f"idle candidate: not observed or retrieved for {int(idle)} days", now)
            retired.append(identity)
        elif status == "active" and not entry.get("curated") and idle > args.unused_days:
            retire(entry, f"unused: not observed or retrieved for {int(idle)} days", now)
            retired.append(identity)
    data["last_maintained_at"] = now
    save_json(entries_path(store_dir), data)
    summary = {"now": now, "promoted": promoted, "retired": retired,
               "active": sum(1 for e in data["entries"].values() if e.get("status") == "active"),
               "entries": len(data["entries"])}
    append_line(os.path.join(store_dir, "maintenance.log"), json.dumps(summary, sort_keys=True))
    print(json.dumps(summary, sort_keys=True))


def entry_changed_after(entry, marker):
    stamps = [entry.get(key, "") for key in ("first_seen", "last_seen", "restored_at", "reopened_at", "promoted_at")]
    return any(stamp and stamp > marker for stamp in stamps)


def cmd_review_export(store_dir, args):
    repo = os.path.abspath(args.repo)
    now = args.now or utc_now()
    data = load_entries(store_dir) if os.path.isdir(store_dir) else {"entries": {}}
    history = retrieval_history(store_dir) if os.path.isdir(store_dir) else {}
    last_curated = data.get("last_curated_at") or ""
    entries, retired_count, changed = [], 0, 0
    for identity, entry in sorted(data["entries"].items()):
        if entry.get("status") == "retired":
            retired_count += 1
            continue
        if entry_changed_after(entry, last_curated):
            changed += 1
        used = history.get(f"obs:{identity}", {"count": 0, "last": ""})
        view = {key: entry.get(key) for key in (
            "lesson", "evidence", "scope", "type", "status", "trust", "seen", "sources",
            "first_seen", "last_seen", "depends_on", "curated", "stale_reason", "reopened_at")}
        view.update({"id": f"obs:{identity}", "retrievals": used["count"], "last_retrieved": used["last"] or None})
        entries.append(view)
    overlay = load_json(os.path.join(store_dir, "curated-overlay.json"), {}) if os.path.isdir(store_dir) else {}
    curated = []
    for entry in parse_curated(repo):
        override = overlay.get(entry["id"], {})
        used = history.get(entry["id"], {"count": 0, "last": ""})
        curated.append({
            "id": entry["id"], "title": entry["title"], "file": entry["file"],
            "status": override.get("status", entry["status"]), "paths": entry["paths"],
            "lesson": entry["lesson"], "retrievals": used["count"], "last_retrieved": used["last"] or None,
        })
    truncated = 0
    if args.max_entries and len(entries) > args.max_entries:
        # Most recently touched first; the rest wait for the next review.
        entries.sort(key=lambda e: max(e.get("last_seen") or "", e.get("last_retrieved") or ""), reverse=True)
        truncated = len(entries) - args.max_entries
        entries = entries[:args.max_entries]
    domains = index_domains(repo)
    age = days_between(now, last_curated) if last_curated else None
    due = changed >= args.min_changes or (age is not None and changed >= 1 and age >= args.max_age_days)
    reasons = []
    if changed >= args.min_changes:
        reasons.append(f"{changed} entries changed since the last curation (threshold {args.min_changes})")
    if age is not None and changed >= 1 and age >= args.max_age_days:
        reasons.append(f"last curation {int(age)} days ago with {changed} changed entries")
    print(json.dumps({
        "schema_version": SCHEMA_VERSION, "repo": repo, "now": now, "last_curated_at": last_curated or None,
        "changed_since_curation": changed, "retired_count": retired_count, "due": due, "reasons": reasons,
        "truncated": truncated, "entries": entries, "curated": curated,
        "domains": [{"name": name, "file": info["file"], "loads_for": info["loads_for"]} for name, info in sorted(domains.items())],
    }, sort_keys=True, indent=1))


CURATE_STORE_ACTIONS = ("keep", "retire", "merge", "rewrite", "promote")
CURATE_OVERLAY_ACTIONS = ("keep", "retire", "needs-recheck")


def cmd_curate_apply(store_dir, args):
    repo = os.path.abspath(args.repo)
    now = args.now or utc_now()
    actor = args.actor
    try:
        with open(args.file, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as error:
        raise StoreError(f"decisions file unreadable: {error}", 1)
    decisions = payload.get("decisions") if isinstance(payload, dict) else None
    if not isinstance(decisions, list):
        raise StoreError("decisions file has no 'decisions' list", 1)
    ensure_store(store_dir)
    data = load_entries(store_dir)
    entries = data["entries"]
    overlay_path = os.path.join(store_dir, "curated-overlay.json")
    overlay = load_json(overlay_path, {})
    curated_ids = {entry["id"] for entry in parse_curated(repo)}
    applied, rejected = [], []

    def reject(decision, reason):
        rejected.append({"id": str(decision.get("id", "")) if isinstance(decision, dict) else "", "reason": reason})

    for decision in decisions:
        if not isinstance(decision, dict):
            reject({}, "not an object")
            continue
        identity = str(decision.get("id", ""))
        action = str(decision.get("action", ""))
        reason = str(decision.get("reason", "") or "").strip()
        if len(reason) < 8:
            reject(decision, "missing reason")
            continue
        if identity.startswith("M-"):
            if identity not in curated_ids:
                reject(decision, f"unknown id {identity}")
                continue
            if action not in CURATE_OVERLAY_ACTIONS:
                reject(decision, f"unknown action {action}")
                continue
            if action == "keep":
                overlay.pop(identity, None)
            else:
                status = "retired" if action == "retire" else action
                overlay[identity] = {"status": status, "reason": reason, "at": now, "actor": actor}
            applied.append({"id": identity, "action": action})
            append_line(os.path.join(store_dir, "curation.log"), json.dumps(
                {"ts": now, "actor": actor, "id": identity, "action": action, "reason": reason}, sort_keys=True))
            continue
        key = identity[4:] if identity.startswith("obs:") else identity
        entry = entries.get(key)
        if entry is None:
            reject(decision, f"unknown id {identity}")
            continue
        if action not in CURATE_STORE_ACTIONS:
            reject(decision, f"unknown action {action}")
            continue
        if entry.get("status") == "retired" and action != "keep":
            reject(decision, f"{identity} is already retired")
            continue
        if action == "keep":
            entry["last_reviewed_at"] = now
        elif action == "retire":
            retire(entry, f"curator: {reason}", now, actor)
        elif action == "promote":
            domain = str(decision.get("domain", "") or "").strip().lower()
            if domain and not DOMAIN_RE.match(domain):
                reject(decision, f"domain must be kebab-case, got {domain}")
                continue
            entry["curated"] = True
            entry["trust"] = "curated"
            entry["promoted_at"] = now
            if domain:
                entry["domain"] = domain
            if entry.get("type") in RETRIEVABLE_TYPES:
                entry["status"] = "active"
        elif action == "merge":
            target_id = str(decision.get("into", ""))
            target_key = target_id[4:] if target_id.startswith("obs:") else target_id
            target = entries.get(target_key)
            if target is None or target_key == key:
                reject(decision, f"merge target {target_id} unknown")
                continue
            if target.get("status") == "retired":
                reject(decision, f"merge target {target_id} is retired")
                continue
            target["seen"] = int(target.get("seen", 1)) + int(entry.get("seen", 1))
            for source in entry.get("sources", []):
                if source not in target.setdefault("sources", []):
                    target["sources"].append(source)
            target.setdefault("aliases", []).append(entry.get("lesson", ""))
            retire(entry, f"merged into {target_key}: {reason}", now, actor)
            entry["merged_into"] = target_key
        elif action == "rewrite":
            lesson = str(decision.get("lesson", "") or "").strip()
            if len(lesson) < 8:
                reject(decision, "rewrite needs a lesson")
                continue
            kind = str(decision.get("type", entry.get("type")))
            if kind not in TYPES:
                reject(decision, f"unknown type {kind}")
                continue
            evidence = str(decision.get("evidence", "") or "").strip() or entry.get("evidence", "")
            entry["rewritten_from"] = entry.get("lesson", "")
            entry["rewritten_at"] = now
            entry["lesson"] = lesson[:600]
            entry["evidence"] = evidence[:600]
            entry["type"] = kind
            depends = evidence_dependencies(repo, evidence)
            entry["depends_on"] = depends
            entry["source_checked"] = bool(depends)
            if kind in RETRIEVABLE_TYPES and (depends or entry.get("curated")):
                entry["status"] = "active"
                entry["trust"] = entry.get("trust") if entry.get("curated") else "verified"
            elif kind in RETRIEVABLE_TYPES and entry.get("status") == "needs-recheck":
                entry["status"] = "candidate"
            elif kind not in RETRIEVABLE_TYPES:
                entry["status"] = "candidate"
            entry.pop("stale_reason", None)
            entry.pop("stale_at", None)
        applied.append({"id": identity, "action": action})
        append_line(os.path.join(store_dir, "curation.log"), json.dumps(
            {"ts": now, "actor": actor, "id": identity, "action": action, "reason": reason}, sort_keys=True))
    data["last_curated_at"] = now
    data["curations"] = int(data.get("curations", 0)) + 1
    save_json(entries_path(store_dir), data)
    save_json(overlay_path, overlay)
    print(json.dumps({"applied": applied, "rejected": rejected, "now": now, "actor": actor}, sort_keys=True))


DOMAIN_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+){0,5}$")
INDEX_DOMAIN_ROW = re.compile(r"^\|\s*([a-z0-9-]+)\s*\|\s*(domains/[A-Za-z0-9_.-]+\.md)\s*\|\s*(.*?)\s*\|\s*([a-z-]+)\s*\|\s*$")
INDEX_ENTRY_ROW = re.compile(r"^\|\s*(M-\d+)\s*\|\s*([a-z0-9-]+)\s*\|\s*(.*?)\s*\|\s*$")
ENTRY_HEADING = re.compile(r"^## (M-\d+):\s*(.*)$", re.M)
DEFAULT_PHASES = "plan, implement, review, verify"


def index_path(repo):
    return os.path.join(repo, ".dex", "memory", "index.md")


def index_domains(repo):
    """Domain rows of .dex/memory/index.md: name -> {file, loads_for, status}."""
    domains = {}
    try:
        text = open(index_path(repo), encoding="utf-8").read()
    except OSError:
        return domains
    for line in text.splitlines():
        match = INDEX_DOMAIN_ROW.match(line)
        if match:
            domains[match.group(1)] = {"file": match.group(2), "loads_for": match.group(3), "status": match.group(4)}
    return domains


def next_entry_number(repo, extra_texts=()):
    highest = 0
    texts = list(extra_texts)
    try:
        texts.append(open(index_path(repo), encoding="utf-8").read())
    except OSError:
        pass
    for path in glob.glob(os.path.join(repo, ".dex", "memory", "domains", "*.md")):
        try:
            texts.append(open(path, encoding="utf-8").read())
        except OSError:
            continue
    for text in texts:
        for match in re.finditer(r"\bM-(\d+)\b", text):
            highest = max(highest, int(match.group(1)))
    return highest + 1


def entry_title(lesson):
    first = re.split(r"(?<=[.;:])\s", lesson.strip(), maxsplit=1)[0].strip().rstrip(".;:")
    if len(first) > 80:
        cut = first[:80].rsplit(" ", 1)[0]
        first = cut.rstrip(",;:- ")
    return first[:1].upper() + first[1:] if first else lesson[:80]


def entry_paths(entry):
    paths = [d.split("@", 1)[0] for d in entry.get("depends_on", [])]
    if not paths:
        seen = set()
        for match in PATH_RE.finditer(entry.get("lesson", "") + " " + entry.get("evidence", "")):
            relpath = match.group(1).lstrip("./")
            if relpath and relpath not in seen:
                seen.add(relpath)
                paths.append(relpath)
    return paths


def render_entry(identity, number, entry, now):
    paths = entry_paths(entry)
    day = now[:10]
    lines = [
        f"## {number}: {entry_title(entry['lesson'])}",
        "",
        f"Domain: {entry.get('domain') or 'general'}",
        "Status: active",
        f"Scope: {', '.join(paths)}",
        f"Applies to phases: {DEFAULT_PHASES}",
        f"Applies to paths: {', '.join(paths)}",
        f"Last verified: {day}",
        f"Recheck when: {', '.join(paths)} change",
    ]
    if entry.get("depends_on"):
        lines.append(f"Depends on: {', '.join(entry['depends_on'])}")
    sources = len(distinct_sessions(entry))
    lines.append(f"Source: dex memory store obs:{identity}; seen {entry.get('seen', 1)}x by {sources} session(s); curated {day}")
    lines += ["", "Lesson:", entry["lesson"].strip(), "", "Evidence:", f"- {entry['evidence'].strip()}", "",
              "Future agent behavior:",
              f"Apply this before editing {', '.join(paths)}; re-verify it against those files first if their recorded blobs changed.", ""]
    return "\n".join(lines) + "\n"


def add_index_rows(text, domain_rows, entry_rows):
    """Insert rows at the end of the Domains and Entries tables, in place."""
    lines = text.split("\n")

    def last_row_after(header_predicate):
        start = None
        for index, line in enumerate(lines):
            if start is None and header_predicate(line):
                start = index
                continue
            if start is not None and index > start + 1 and not line.startswith("|"):
                return index
        return len(lines) if start is not None else None

    if domain_rows:
        at = last_row_after(lambda line: line.startswith("| Domain") and "| File" in line)
        if at is None:
            lines += ["", "## Domains", "", "| Domain | File | Loads For | Status |", "|--------|------|-----------|--------|"]
            at = len(lines)
        lines[at:at] = domain_rows
    if entry_rows:
        at = last_row_after(lambda line: line.startswith("| ID") and "| Domain" in line)
        if at is None:
            lines += ["", "## Entries", "", "| ID | Domain | Summary |", "|----|--------|---------|"]
            at = len(lines)
        lines[at:at] = entry_rows
    return "\n".join(lines)


def set_entry_status(text, identity, new_status):
    """Change the Status line inside one entry block; True when it changed."""
    headings = list(ENTRY_HEADING.finditer(text))
    for index, match in enumerate(headings):
        if match.group(1) != identity:
            continue
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        block = text[match.start():end]
        new_block, count = re.subn(r"^Status:\s*.*$", f"Status: {new_status}", block, count=1, flags=re.M)
        if count == 0 or new_block == block:
            return text, False
        return text[:match.start()] + new_block + text[end:], True
    return text, False


def cmd_materialize(store_dir, args):
    repo = os.path.abspath(args.repo)
    out_repo = os.path.abspath(args.out_repo or args.repo)
    now = args.now or utc_now()
    data = load_entries(store_dir)
    overlay = load_json(os.path.join(store_dir, "curated-overlay.json"), {}) if os.path.isdir(store_dir) else {}
    candidates = [(identity, entry) for identity, entry in data["entries"].items()
                  if entry.get("curated") and entry.get("status") == "active"
                  and entry.get("type") in RETRIEVABLE_TYPES and not entry.get("landed")]
    candidates.sort(key=lambda pair: (pair[1].get("promoted_at") or "", pair[0]))
    domains = index_domains(out_repo)
    # Numbers already given out by earlier landings count even when their
    # branch has not merged yet, so two pending landings never share an id.
    allocated = [int(m.group(1)) for entry in data["entries"].values()
                 for m in [re.match(r"M-(\d+)$", str((entry.get("landed") or {}).get("id", "")))] if m]
    number = max(next_entry_number(out_repo), max(allocated, default=0) + 1)
    file_texts = {}
    files_touched = []
    landed, skipped, rendered = [], [], []
    domain_rows, entry_rows = [], []

    def read_file(relpath):
        if relpath not in file_texts:
            absolute = os.path.join(out_repo, relpath)
            file_texts[relpath] = open(absolute, encoding="utf-8").read() if os.path.isfile(absolute) else None
        return file_texts[relpath]

    for identity, entry in candidates:
        paths = entry_paths(entry)
        if not paths:
            skipped.append({"store_id": identity, "reason": "no paths to scope the entry to"})
            continue
        domain = entry.get("domain") or "general"
        relfile = domains.get(domain, {}).get("file") or f"domains/{domain}.md"
        relpath = os.path.join(".dex", "memory", relfile)
        entry_id = f"M-{number:03d}"
        number += 1
        block = render_entry(identity, entry_id, entry, now)
        current = read_file(relpath)
        if current is None:
            title = domain.replace("-", " ").title()
            current = f"# {title}\n\n"
            if domain not in domains:
                domain_rows.append(f"| {domain} | {relfile} | {', '.join(paths)} | active |")
                domains[domain] = {"file": relfile, "loads_for": ", ".join(paths), "status": "active"}
        file_texts[relpath] = current.rstrip("\n") + "\n\n" + block
        entry_rows.append(f"| {entry_id} | {domain} | {entry_title(entry['lesson'])} |")
        landed.append({"id": entry_id, "store_id": identity, "domain": domain, "file": relpath,
                       "title": entry_title(entry["lesson"])})
        rendered.append(block)
        if relpath not in files_touched:
            files_touched.append(relpath)

    status_changes = []
    for curated_id, record in sorted(overlay.items()):
        status = record.get("status")
        if status not in ("retired", "needs-recheck") or record.get("landed_commit"):
            continue
        for relfile in [info["file"] for info in domains.values()] + [
            os.path.relpath(path, os.path.join(out_repo, ".dex", "memory"))
            for path in glob.glob(os.path.join(out_repo, ".dex", "memory", "domains", "*.md"))]:
            relpath = os.path.join(".dex", "memory", relfile)
            current = read_file(relpath)
            if current is None or f"## {curated_id}:" not in current:
                continue
            new_text, changed = set_entry_status(current, curated_id, status)
            if changed:
                file_texts[relpath] = new_text
                status_changes.append({"id": curated_id, "status": status, "file": relpath, "reason": record.get("reason", "")})
                if relpath not in files_touched:
                    files_touched.append(relpath)
            break

    if domain_rows or entry_rows:
        index_rel = os.path.join(".dex", "memory", "index.md")
        current = read_file(index_rel)
        if current is None:
            current = "# Dex Memory Index\n"
        file_texts[index_rel] = add_index_rows(current, domain_rows, entry_rows)
        if index_rel not in files_touched:
            files_touched.append(index_rel)

    plan = {"schema_version": SCHEMA_VERSION, "repo": repo, "out_repo": out_repo, "now": now,
            "landed": landed, "status_changes": status_changes, "skipped": skipped,
            "files": files_touched, "rendered": rendered, "written": bool(args.write)}
    if args.write and files_touched:
        for relpath in files_touched:
            absolute = os.path.join(out_repo, relpath)
            os.makedirs(os.path.dirname(absolute), exist_ok=True)
            with open(absolute, "w", encoding="utf-8") as handle:
                handle.write(file_texts[relpath])
    print(json.dumps(plan, sort_keys=True, indent=1))


def cmd_mark_landed(store_dir, args):
    now = args.now or utc_now()
    try:
        plan = json.load(open(args.file, encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise StoreError(f"plan unreadable: {error}", 1)
    data = load_entries(store_dir)
    overlay_path = os.path.join(store_dir, "curated-overlay.json")
    overlay = load_json(overlay_path, {})
    marked = []
    for item in plan.get("landed", []):
        entry = data["entries"].get(item.get("store_id"))
        if entry is None:
            continue
        record = {"id": item["id"], "commit": args.commit, "at": now, "file": item.get("file")}
        if args.pr:
            record["pr"] = args.pr
        entry["landed"] = record
        marked.append(item["id"])
    for change in plan.get("status_changes", []):
        record = overlay.setdefault(change["id"], {"status": change["status"]})
        record["landed_commit"] = args.commit
        record["landed_at"] = now
    save_json(entries_path(store_dir), data)
    save_json(overlay_path, overlay)
    print(json.dumps({"marked": marked, "status_changes": [c["id"] for c in plan.get("status_changes", [])],
                      "commit": args.commit}, sort_keys=True))


def dex_fingerprint(repo):
    """A hash of the tracked and untracked files under .dex (not worktrees)."""
    digest = hashlib.sha256()
    base = os.path.join(repo, ".dex")
    for root, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d != "worktrees")
        for name in sorted(files):
            path = os.path.join(root, name)
            try:
                with open(path, "rb") as handle:
                    digest.update(os.path.relpath(path, base).encode("utf-8"))
                    digest.update(handle.read())
            except OSError:
                continue
    return digest.hexdigest()


def cmd_sync_check(store_dir, args):
    """Is there anything for `dx sync` to promote since its last write run?"""
    repo = os.path.abspath(args.repo)
    data = load_entries(store_dir) if os.path.isdir(store_dir) else {"entries": {}}
    last = data.get("last_synced_at") or ""
    changed = 0
    for entry in data["entries"].values():
        if entry.get("status") == "retired" and not entry_changed_after(entry, last):
            continue
        stamps = [entry.get(key, "") for key in ("first_seen", "last_seen", "restored_at", "reopened_at",
                                                 "promoted_at", "rewritten_at", "retired_at")]
        stamps.append((entry.get("landed") or {}).get("at", ""))
        if any(stamp and stamp > last for stamp in stamps):
            changed += 1
    fingerprint = dex_fingerprint(repo)
    dex_changed = fingerprint != data.get("last_synced_dex_fingerprint")
    due = (not last) or changed > 0 or dex_changed
    reasons = []
    if not last:
        reasons.append("never synced")
    if changed:
        reasons.append(f"{changed} store entries changed since the last sync")
    if last and dex_changed:
        reasons.append(".dex files changed since the last sync")
    print(json.dumps({"due": due, "changed_since_sync": changed, "dex_changed": dex_changed,
                      "last_synced_at": last or None, "reasons": reasons}, sort_keys=True))


def cmd_sync_mark(store_dir, args):
    repo = os.path.abspath(args.repo)
    ensure_store(store_dir)
    data = load_entries(store_dir)
    data["last_synced_at"] = args.now or utc_now()
    data["last_synced_dex_fingerprint"] = dex_fingerprint(repo)
    save_json(entries_path(store_dir), data)
    print(json.dumps({"last_synced_at": data["last_synced_at"]}))


def cmd_verify(store_dir, _args):
    path = os.path.join(store_dir, "observations.jsonl")
    count = 0
    if private_path_ok(path):
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    json.loads(line)
                except ValueError as error:
                    raise StoreError(f"observations.jsonl line {number}: not JSON ({error})", 1)
                count += 1
    data = load_entries(store_dir)
    print(json.dumps({"ok": True, "observations": count, "entries": len(data["entries"])}))


def cmd_show(store_dir, _args):
    print(json.dumps(load_entries(store_dir), sort_keys=True, indent=1))


def build_parser():
    parser = argparse.ArgumentParser(description="Dex external memory store")
    parser.add_argument("store_dir")
    sub = parser.add_subparsers(dest="command", required=True)
    ingest = sub.add_parser("ingest")
    ingest.add_argument("file")
    ingest.add_argument("--repo", required=True)
    ingest.add_argument("--source")
    ingest.add_argument("--revision")
    ingest.set_defaults(func=cmd_ingest)
    retrieve = sub.add_parser("retrieve")
    retrieve.add_argument("--repo", required=True)
    retrieve.add_argument("--paths", default="")
    retrieve.add_argument("--session")
    retrieve.add_argument("--role", default="lead")
    retrieve.add_argument("--phase")
    retrieve.add_argument("--limit", type=int, default=12)
    retrieve.add_argument("--include-measurements", action="store_true")
    retrieve.set_defaults(func=cmd_retrieve)
    recheck = sub.add_parser("recheck")
    recheck.add_argument("--repo", required=True)
    recheck.set_defaults(func=cmd_recheck)
    maintain = sub.add_parser("maintain")
    maintain.add_argument("--repo", required=True)
    maintain.add_argument("--now")
    maintain.add_argument("--stale-days", type=float, default=14)
    maintain.add_argument("--idle-days", type=float, default=45)
    maintain.add_argument("--unused-days", type=float, default=90)
    maintain.set_defaults(func=cmd_maintain)
    export = sub.add_parser("review-export")
    export.add_argument("--repo", required=True)
    export.add_argument("--now")
    export.add_argument("--min-changes", type=int, default=5)
    export.add_argument("--max-age-days", type=float, default=7)
    export.add_argument("--max-entries", type=int, default=200)
    export.set_defaults(func=cmd_review_export)
    apply = sub.add_parser("curate-apply")
    apply.add_argument("file")
    apply.add_argument("--repo", required=True)
    apply.add_argument("--actor", default="curator")
    apply.add_argument("--now")
    apply.set_defaults(func=cmd_curate_apply)
    materialize = sub.add_parser("materialize")
    materialize.add_argument("--repo", required=True)
    materialize.add_argument("--out-repo")
    materialize.add_argument("--now")
    materialize.add_argument("--write", action="store_true")
    materialize.set_defaults(func=cmd_materialize)
    landed = sub.add_parser("mark-landed")
    landed.add_argument("file")
    landed.add_argument("--commit", required=True)
    landed.add_argument("--pr")
    landed.add_argument("--now")
    landed.set_defaults(func=cmd_mark_landed)
    sync_check = sub.add_parser("sync-check")
    sync_check.add_argument("--repo", required=True)
    sync_check.set_defaults(func=cmd_sync_check)
    sync_mark = sub.add_parser("sync-mark")
    sync_mark.add_argument("--repo", required=True)
    sync_mark.add_argument("--now")
    sync_mark.set_defaults(func=cmd_sync_mark)
    sub.add_parser("verify").set_defaults(func=cmd_verify)
    sub.add_parser("show").set_defaults(func=cmd_show)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(os.path.abspath(args.store_dir), args)
    except StoreError as error:
        print(f"memory_store: {error}", file=sys.stderr)
        return error.code
    except (OSError, ValueError) as error:
        print(f"memory_store: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
