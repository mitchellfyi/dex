#!/usr/bin/env python3
"""The feedback outbox: bounded, sanitised candidates for the Dex research consumer.

    feedback_outbox.py <dir> submit --json '{...}' [--patch FILE] [--reproduction FILE] [--reopen REASON]
    feedback_outbox.py <dir> list [--state STATE]
    feedback_outbox.py <dir> claim <id> --owner WHO [--ttl-seconds N]
    feedback_outbox.py <dir> release <id> --owner WHO
    feedback_outbox.py <dir> attach <id> --owner WHO [--reproduction FILE] [--patch FILE] [--source KIND]
    feedback_outbox.py <dir> attempt <id> --owner WHO
    feedback_outbox.py <dir> decide <id> --owner WHO --decision validated|rejected|inconclusive --evaluation FILE
    feedback_outbox.py <dir> retire <id> --owner WHO --reason TEXT [--evaluation FILE]
    feedback_outbox.py <dir> activate <id> --owner WHO --dex-dir DIR
    feedback_outbox.py <dir> revert <id> --owner WHO --reason TEXT
    feedback_outbox.py <dir> show <id>

One directory per mechanism: `manifest.json` (versioned), `evidence-summary.md`,
`metrics.json`, optional `reproduction/check.sh` and `proposed-change.patch`.
The id is derived from the mechanism, so a second report of the same
mechanism adds support to the existing candidate instead of opening another.

States. A candidate is `eligible` when it has an evidence summary and either a
reproduction or a patch; otherwise it is `captured` and names what is missing.
A claim is a lease one owner holds until it expires or releases it, and every
transition below needs it. `decide` records validated or rejected and leaves
the candidate `evaluated`; an inconclusive decision instead spends one
`attempts` and returns it to `eligible`, so the next run looks again. The
terminal states are `activated` (a validated patch applied, unstaged, to a
live Dex checkout, with the rollback recorded), `reverted` (that patch taken
back out) and `retired` (given up on, with the reason). A rejected candidate
is final too: it stays `evaluated` and cannot be claimed. A validated one can
be claimed again, for activation. `list` reports the effective state, so a
claim whose lease lapsed no longer hides the candidate from a consumer.

Feedback submitted while the research consumer runs
(DX_RESEARCH_CONSUMER_ACTIVE=1) is tagged `origin: research` so a campaign does
not feed itself. The patch and reproduction are untrusted input: stored,
never executed here. `activate` and `revert` run `git apply` in the named
checkout and nothing else; no commit is ever made.

Exit 0 ok, 2 usage or unsafe files, 3 refused.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dex_private_files import PrivateFileError, atomic_write, private_file_ok  # noqa: E402

SCHEMA_VERSION = 1
DECISIONS = ("validated", "rejected", "inconclusive")
TERMINAL_STATES = ("activated", "reverted", "retired")
STATES = ("captured", "eligible", "claimed", "evaluated") + TERMINAL_STATES
MAX_PATCH_BYTES = 1_000_000


class OutboxError(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def check_private(path):
    try:
        return private_file_ok(path)
    except PrivateFileError as error:
        raise OutboxError(str(error))


def candidate_id(mechanism):
    normalised = re.sub(r"\s+", " ", mechanism.strip().lower())
    return "fb-" + hashlib.sha256(normalised.encode("utf-8")).hexdigest()[:12]


def manifest_path(outbox, identity):
    return os.path.join(outbox, identity, "manifest.json")


def load_manifest(outbox, identity):
    path = manifest_path(outbox, identity)
    if not re.fullmatch(r"fb-[0-9a-f]{12}", identity) or not check_private(path):
        raise OutboxError(f"no candidate {identity}")
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save_manifest(outbox, manifest):
    manifest["updated_at"] = utc_now()
    atomic_write(manifest_path(outbox, manifest["id"]), json.dumps(manifest, sort_keys=True, indent=1) + "\n")


def copy_private(source, destination, executable=False):
    size = os.path.getsize(source)
    if size > MAX_PATCH_BYTES:
        raise OutboxError(f"{source}: larger than {MAX_PATCH_BYTES} bytes")
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o700 if executable else 0o600)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def patch_strip(path):
    """1 when the headers carry git's a/ b/ prefixes, else 0: the rule the consumer applies too."""
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("+++ b/"):
                return 1
    return 0


def run_git(directory, *args):
    completed = subprocess.run(["git", "-C", directory, *args], capture_output=True, text=True, check=False)
    return completed.returncode, completed.stdout.strip(), completed.stderr.strip()


def attempts_of(manifest):
    return int(manifest.get("attempts") or 0)


def eligibility(manifest, directory):
    missing = []
    if not manifest.get("evidence_summary"):
        missing.append("evidence_summary")
    has_repro = os.path.isfile(os.path.join(directory, "reproduction", "check.sh"))
    has_patch = os.path.isfile(os.path.join(directory, "proposed-change.patch"))
    if not (has_repro or has_patch):
        missing.append("reproduction")
    return ("eligible" if not missing else "captured"), missing


def resting_state(manifest, directory):
    """The state a candidate has when nobody holds it."""
    if manifest.get("state") in TERMINAL_STATES:
        return manifest["state"], manifest.get("missing", [])
    if manifest.get("decision") in ("rejected", "validated"):
        return "evaluated", []
    return eligibility(manifest, directory)


def effective_state(manifest, directory):
    """What `list` reports: a lease that lapsed no longer hides the candidate."""
    if manifest.get("state") == "claimed" and not claim_live(manifest, time.time()):
        return resting_state(manifest, directory)[0]
    return manifest.get("state")


def refuse_terminal(manifest):
    state = manifest.get("state")
    if state in TERMINAL_STATES:
        detail = f": {manifest.get('retired_reason')}" if state == "retired" and manifest.get("retired_reason") else ""
        raise OutboxError(f"{manifest['id']} is {state}{detail}", 3)


def refuse_final(manifest):
    refuse_terminal(manifest)
    if manifest.get("state") == "evaluated" and manifest.get("decision") != "validated":
        raise OutboxError(f"{manifest['id']} is already evaluated ({manifest.get('decision')})", 3)


def cmd_submit(outbox, args):
    try:
        fields = json.loads(args.json)
    except ValueError as error:
        raise OutboxError(f"--json is not valid JSON: {error}")
    if not isinstance(fields, dict):
        raise OutboxError("--json must be an object")
    if args.reopen is not None and not args.reopen.strip():
        raise OutboxError("--reopen needs a reason")
    mechanism = str(fields.get("mechanism", "")).strip()
    symptom = str(fields.get("symptom", "")).strip()
    if len(mechanism) < 8 or not symptom:
        raise OutboxError("a candidate needs 'mechanism' (a portable description) and 'symptom'")
    os.makedirs(outbox, mode=0o700, exist_ok=True)
    os.chmod(outbox, 0o700)
    identity = candidate_id(mechanism)
    directory = os.path.join(outbox, identity)
    now = utc_now()
    origin = "research" if os.environ.get("DX_RESEARCH_CONSUMER_ACTIVE") == "1" else "project"
    support_entry = {
        "submitted_at": now, "symptom": symptom[:500],
        "evidence_summary": str(fields.get("evidence_summary", ""))[:2000],
        "metrics": fields.get("metrics") if isinstance(fields.get("metrics"), dict) else {},
        "origin": origin,
    }
    if os.path.isfile(manifest_path(outbox, identity)):
        manifest = load_manifest(outbox, identity)
        manifest["support"] = int(manifest.get("support", 1)) + 1
        manifest.setdefault("supports", []).append(support_entry)
        reopened = False
        if manifest.get("state") == "retired" and args.reopen:
            # A retirement is undone only on request. The reason sits beside the
            # one it undoes, and the attempt budget starts over.
            manifest.setdefault("reopened", []).append({
                "at": now, "reason": args.reopen.strip()[:500],
                "previous_retired_reason": manifest.get("retired_reason"),
                "previous_attempts": attempts_of(manifest),
                "previous_decision": manifest.get("decision"),
            })
            manifest.update({"retired_reason": None, "retired_at": None, "retired_by": None,
                             "decision": None, "attempts": 0})
            if args.patch:
                copy_private(args.patch, os.path.join(directory, "proposed-change.patch"))
                manifest["has_patch"] = True
            if args.reproduction:
                copy_private(args.reproduction, os.path.join(directory, "reproduction", "check.sh"), executable=True)
                manifest["has_reproduction"] = True
            manifest["state"], manifest["missing"] = eligibility(manifest, directory)
            reopened = True
        elif manifest.get("state") in ("captured", "eligible"):
            manifest["state"], manifest["missing"] = eligibility(manifest, directory)
        save_manifest(outbox, manifest)
        print(json.dumps({"id": identity, "deduplicated": True, "support": manifest["support"],
                          "state": manifest["state"], "reopened": reopened}))
        return
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    if args.patch:
        copy_private(args.patch, os.path.join(directory, "proposed-change.patch"))
    if args.reproduction:
        copy_private(args.reproduction, os.path.join(directory, "reproduction", "check.sh"), executable=True)
    evidence = str(fields.get("evidence_summary", ""))
    summary_lines = [f"# {mechanism}", "", f"Symptom: {symptom}", "", evidence]
    for key in ("impact", "suspected_cause", "candidate_mechanism", "applicability", "exclusions", "reproduction_gap"):
        value = fields.get(key)
        if value:
            summary_lines += ["", f"{key.replace('_', ' ').capitalize()}: {value}"]
    atomic_write(os.path.join(directory, "evidence-summary.md"), "\n".join(summary_lines) + "\n")
    atomic_write(os.path.join(directory, "metrics.json"), json.dumps(support_entry["metrics"], sort_keys=True, indent=1) + "\n")
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "id": identity,
        "dedup_key": identity,
        "mechanism": mechanism[:500],
        "symptom": symptom[:500],
        "evidence_summary": evidence[:2000],
        "impact": str(fields.get("impact", ""))[:500],
        "suspected_cause": str(fields.get("suspected_cause", ""))[:500],
        "candidate_mechanism": str(fields.get("candidate_mechanism", ""))[:500],
        "applicability": str(fields.get("applicability", ""))[:500],
        "exclusions": str(fields.get("exclusions", ""))[:500],
        "export_class": fields.get("export_class") if fields.get("export_class") in ("local", "exportable") else "local",
        "delivery": "local",
        "origin": origin,
        "source_is_synthetic": bool(fields.get("source_is_synthetic", False)),
        "versions": {"dex_version": fields.get("dex_version"), "recorded_by": fields.get("recorded_by")},
        "has_patch": bool(args.patch),
        "has_reproduction": bool(args.reproduction),
        "support": 1,
        "supports": [support_entry],
        "claim": None,
        "decision": None,
        "attempts": 0,
        "retired_reason": None,
        "activation": None,
        "created_at": now,
    }
    manifest["state"], manifest["missing"] = eligibility(manifest, directory)
    save_manifest(outbox, manifest)
    print(json.dumps({"id": identity, "deduplicated": False, "support": 1, "state": manifest["state"]}))


def iter_manifests(outbox):
    if not os.path.isdir(outbox):
        return
    for name in sorted(os.listdir(outbox)):
        if re.fullmatch(r"fb-[0-9a-f]{12}", name) and os.path.isfile(manifest_path(outbox, name)):
            try:
                yield load_manifest(outbox, name)
            except OutboxError:
                continue


def cmd_list(outbox, args):
    rows = []
    for manifest in iter_manifests(outbox):
        state = effective_state(manifest, os.path.join(outbox, manifest["id"]))
        if args.state and state != args.state:
            continue
        row = {key: manifest.get(key) for key in (
            "id", "mechanism", "origin", "support", "decision", "has_patch", "has_reproduction", "created_at", "retired_reason")}
        row["state"] = state
        row["attempts"] = attempts_of(manifest)
        rows.append(row)
    print(json.dumps(rows, sort_keys=True))


def claim_live(manifest, now_epoch):
    claim = manifest.get("claim")
    return bool(claim) and float(claim.get("expires_epoch", 0)) > now_epoch


def cmd_claim(outbox, args):
    manifest = load_manifest(outbox, args.id)
    refuse_final(manifest)
    now_epoch = time.time()
    if claim_live(manifest, now_epoch) and manifest["claim"].get("owner") != args.owner:
        raise OutboxError(f"{args.id} is claimed by {manifest['claim']['owner']} until {manifest['claim']['expires_at']}", 3)
    generation = int((manifest.get("claim") or {}).get("generation", manifest.get("claim_generation", 0))) + 1
    manifest["claim_generation"] = generation
    manifest["claim"] = {
        "owner": args.owner, "generation": generation, "claimed_at": utc_now(),
        "expires_epoch": now_epoch + args.ttl_seconds,
        "expires_at": datetime.fromtimestamp(now_epoch + args.ttl_seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    manifest["state"] = "claimed"
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "claim": manifest["claim"]}))


def require_claim(manifest, owner):
    claim = manifest.get("claim")
    if not claim or claim.get("owner") != owner:
        raise OutboxError(f"{manifest['id']} is not claimed by {owner}", 3)


def cmd_release(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    manifest["claim"] = None
    manifest["state"], manifest["missing"] = resting_state(manifest, os.path.join(outbox, args.id))
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "state": manifest["state"]}))


def cmd_attach(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    refuse_terminal(manifest)
    if not (args.reproduction or args.patch):
        raise OutboxError("attach needs --reproduction and/or --patch")
    directory = os.path.join(outbox, args.id)
    now = utc_now()
    if args.reproduction:
        target = os.path.join(directory, "reproduction", "check.sh")
        copy_private(args.reproduction, target, executable=True)
        manifest["has_reproduction"] = True
        manifest["reproduction_source"] = {"kind": args.source, "attached_at": now, "attached_by": args.owner,
                                           "sha256": sha256_file(target)}
    if args.patch:
        target = os.path.join(directory, "proposed-change.patch")
        copy_private(args.patch, target)
        manifest["has_patch"] = True
        manifest["patch_source"] = {"kind": args.source, "attached_at": now, "attached_by": args.owner,
                                    "sha256": sha256_file(target)}
    # The claim is still held, so the state stays `claimed`; `missing` says what the files changed.
    _, manifest["missing"] = eligibility(manifest, directory)
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "state": manifest["state"], "missing": manifest["missing"]}))


def cmd_attempt(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    manifest["attempts"] = attempts_of(manifest) + 1
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "attempts": manifest["attempts"]}))


def load_evaluation(path):
    with open(path, encoding="utf-8") as handle:
        evaluation = json.load(handle)
    if not isinstance(evaluation, dict):
        raise OutboxError("evaluation must be a JSON object")
    return evaluation


def write_evaluation(outbox, identity, evaluation):
    atomic_write(os.path.join(outbox, identity, "evaluation.json"), json.dumps(evaluation, sort_keys=True, indent=1) + "\n")


def annotate_evaluation(outbox, identity, key, value):
    """The manifest is the record; evaluation.json mirrors it when it exists."""
    path = os.path.join(outbox, identity, "evaluation.json")
    try:
        if not check_private(path):
            return
        evaluation = load_evaluation(path)
        evaluation[key] = value
        write_evaluation(outbox, identity, evaluation)
    except (OutboxError, OSError, ValueError) as error:
        print(f"feedback_outbox: evaluation.json not updated: {error}", file=sys.stderr)


def cmd_decide(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    if args.decision not in DECISIONS:
        raise OutboxError(f"decision must be one of {', '.join(DECISIONS)}")
    evaluation = load_evaluation(args.evaluation)
    now = utc_now()
    if args.decision == "inconclusive":
        manifest["attempts"] = attempts_of(manifest) + 1
    evaluation.update({"decision": args.decision, "decided_at": now, "decided_by": args.owner,
                       "attempts": attempts_of(manifest)})
    write_evaluation(outbox, args.id, evaluation)
    manifest["decision"] = args.decision
    manifest["evaluated_at"] = now
    manifest["claim"] = None
    if args.decision == "inconclusive":
        # Not an answer: back to the queue with one attempt spent.
        manifest["state"], manifest["missing"] = eligibility(manifest, os.path.join(outbox, args.id))
    else:
        manifest["state"] = "evaluated"
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "decision": args.decision, "state": manifest["state"],
                      "attempts": attempts_of(manifest)}))


def cmd_retire(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    refuse_terminal(manifest)
    reason = args.reason.strip()
    if not reason:
        raise OutboxError("retire needs a --reason")
    now = utc_now()
    if args.evaluation:
        evaluation = load_evaluation(args.evaluation)
        evaluation.update({"retired_at": now, "retired_by": args.owner, "retired_reason": reason})
        evaluation.setdefault("decided_at", now)
        evaluation.setdefault("decided_by", args.owner)
        write_evaluation(outbox, args.id, evaluation)
        if evaluation.get("decision") in DECISIONS:
            manifest["decision"] = evaluation["decision"]
            manifest["evaluated_at"] = now
    manifest.update({"state": "retired", "retired_reason": reason[:500], "retired_at": now,
                     "retired_by": args.owner, "claim": None})
    save_manifest(outbox, manifest)
    print(json.dumps({"id": args.id, "state": "retired", "reason": manifest["retired_reason"]}))


def cmd_activate(outbox, args):
    manifest = load_manifest(outbox, args.id)
    require_claim(manifest, args.owner)
    refuse_terminal(manifest)
    if manifest.get("decision") != "validated":
        raise OutboxError(f"{args.id} is not validated (decision: {manifest.get('decision')})", 3)
    patch = os.path.join(outbox, args.id, "proposed-change.patch")
    if not check_private(patch):
        raise OutboxError(f"{args.id} has no proposed-change.patch to activate", 3)
    dex_dir = os.path.abspath(args.dex_dir)
    code, top, _ = run_git(dex_dir, "rev-parse", "--show-toplevel")
    if code != 0 or os.path.realpath(top) != os.path.realpath(dex_dir):
        raise OutboxError(f"{dex_dir} is not the top of a git checkout", 3)
    code, head, _ = run_git(dex_dir, "rev-parse", "HEAD")
    if code != 0:
        raise OutboxError(f"{dex_dir}: cannot read HEAD", 3)
    strip = patch_strip(patch)
    code, numstat, err = run_git(dex_dir, "apply", "--numstat", f"-p{strip}", patch)
    changed = [line.split("\t")[2] for line in numstat.splitlines() if line.count("\t") >= 2]
    if code != 0 or not changed:
        raise OutboxError(f"patch names no files git apply can read: {err}", 3)
    code, _, err = run_git(dex_dir, "apply", "--check", f"-p{strip}", patch)
    if code != 0:
        raise OutboxError(f"patch does not apply cleanly to {dex_dir}: {err}", 3)
    code, _, err = run_git(dex_dir, "apply", f"-p{strip}", patch)
    if code != 0:
        raise OutboxError(f"patch failed to apply to {dex_dir} after a clean check: {err}", 3)
    rollback = ["git", "-C", dex_dir, "apply", "-R"] + ([f"-p{strip}"] if strip != 1 else []) + [patch]
    activation = {
        "activated_at": utc_now(), "activated_by": args.owner, "dex_dir": dex_dir, "head": head,
        "patch_sha256": sha256_file(patch), "patch_strip": strip, "changed_paths": changed,
        "rollback": shlex.join(rollback),
    }
    manifest["activation"] = activation
    manifest["state"] = "activated"
    manifest["claim"] = None
    save_manifest(outbox, manifest)
    annotate_evaluation(outbox, args.id, "activation", activation)
    print(json.dumps({"id": args.id, "state": "activated", "activation": activation}))


def cmd_revert(outbox, args):
    manifest = load_manifest(outbox, args.id)
    if manifest.get("state") != "activated":
        raise OutboxError(f"{args.id} is {manifest.get('state')}, not activated", 3)
    reason = args.reason.strip()
    if not reason:
        raise OutboxError("revert needs a --reason")
    activation = manifest.get("activation") or {}
    dex_dir = activation.get("dex_dir")
    patch = os.path.join(outbox, args.id, "proposed-change.patch")
    if not dex_dir or not check_private(patch):
        raise OutboxError(f"{args.id} has no activation to revert", 3)
    if sha256_file(patch) != activation.get("patch_sha256"):
        raise OutboxError(f"{args.id}: proposed-change.patch changed since activation; recorded rollback: {activation.get('rollback')}", 3)
    strip = int(activation.get("patch_strip", patch_strip(patch)))
    code, _, err = run_git(dex_dir, "apply", "-R", "--check", f"-p{strip}", patch)
    if code != 0:
        raise OutboxError(f"reverse patch does not apply cleanly to {dex_dir}: {err}", 3)
    code, _, err = run_git(dex_dir, "apply", "-R", f"-p{strip}", patch)
    if code != 0:
        raise OutboxError(f"reverse patch failed to apply to {dex_dir} after a clean check: {err}", 3)
    _, head, _ = run_git(dex_dir, "rev-parse", "HEAD")
    revert = {"reverted_at": utc_now(), "reverted_by": args.owner, "reason": reason[:500], "head": head}
    manifest["revert"] = revert
    manifest["state"] = "reverted"
    save_manifest(outbox, manifest)
    annotate_evaluation(outbox, args.id, "revert", revert)
    print(json.dumps({"id": args.id, "state": "reverted", "revert": revert}))


def cmd_show(outbox, args):
    print(json.dumps(load_manifest(outbox, args.id), sort_keys=True, indent=1))


def build_parser():
    parser = argparse.ArgumentParser(description="Dex feedback outbox")
    parser.add_argument("outbox")
    sub = parser.add_subparsers(dest="command", required=True)
    submit = sub.add_parser("submit")
    submit.add_argument("--json", required=True)
    submit.add_argument("--patch")
    submit.add_argument("--reproduction")
    submit.add_argument("--reopen", metavar="REASON")
    submit.set_defaults(func=cmd_submit)
    listing = sub.add_parser("list")
    listing.add_argument("--state", choices=STATES)
    listing.set_defaults(func=cmd_list)
    claim = sub.add_parser("claim")
    claim.add_argument("id")
    claim.add_argument("--owner", required=True)
    claim.add_argument("--ttl-seconds", type=int, default=3600)
    claim.set_defaults(func=cmd_claim)
    release = sub.add_parser("release")
    release.add_argument("id")
    release.add_argument("--owner", required=True)
    release.set_defaults(func=cmd_release)
    attach = sub.add_parser("attach")
    attach.add_argument("id")
    attach.add_argument("--owner", required=True)
    attach.add_argument("--reproduction")
    attach.add_argument("--patch")
    attach.add_argument("--source", default="attached")
    attach.set_defaults(func=cmd_attach)
    attempt = sub.add_parser("attempt")
    attempt.add_argument("id")
    attempt.add_argument("--owner", required=True)
    attempt.set_defaults(func=cmd_attempt)
    decide = sub.add_parser("decide")
    decide.add_argument("id")
    decide.add_argument("--owner", required=True)
    decide.add_argument("--decision", required=True)
    decide.add_argument("--evaluation", required=True)
    decide.set_defaults(func=cmd_decide)
    retire = sub.add_parser("retire")
    retire.add_argument("id")
    retire.add_argument("--owner", required=True)
    retire.add_argument("--reason", required=True)
    retire.add_argument("--evaluation")
    retire.set_defaults(func=cmd_retire)
    activate = sub.add_parser("activate")
    activate.add_argument("id")
    activate.add_argument("--owner", required=True)
    activate.add_argument("--dex-dir", required=True)
    activate.set_defaults(func=cmd_activate)
    revert = sub.add_parser("revert")
    revert.add_argument("id")
    revert.add_argument("--owner", required=True)
    revert.add_argument("--reason", required=True)
    revert.set_defaults(func=cmd_revert)
    show = sub.add_parser("show")
    show.add_argument("id")
    show.set_defaults(func=cmd_show)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(os.path.abspath(args.outbox), args)
    except OutboxError as error:
        print(f"feedback_outbox: {error}", file=sys.stderr)
        return error.code
    except (OSError, ValueError) as error:
        print(f"feedback_outbox: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
