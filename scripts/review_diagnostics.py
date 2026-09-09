"""Keep bounded, private failure evidence before a review child is cleaned up."""

import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time

from review_acceptance import AcceptanceError, directory, read, remove, safe_name, sync_dir, write


SUFFIXES = (
    "review-result", "review-context", "review-evidence.json", "findings",
    "review-metrics.json", "review-criteria.json", "config", "completion-expectation",
    "pause-state", "paused",
)
MAX_ARTIFACT = 262144
MAX_BUNDLE = 2097152
KEEP_BUNDLES = 4
BUNDLE_NAME = re.compile(r"[0-9]{1,20}-[a-f0-9]{32}")


def validate_bundle(bundle, parent, child):
    directory(bundle)
    data = json.loads(read(bundle / "manifest.json"))
    if data["parent_session"] != parent or data["child_session"] != child:
        raise AcceptanceError("diagnostic identity changed")
    artifacts = data["artifacts"]
    if not isinstance(artifacts, dict) or len(artifacts) > len(SUFFIXES) + 6:
        raise AcceptanceError("invalid diagnostic manifest")
    for name, expected in artifacts.items():
        if name not in (*SUFFIXES, "parent-control", "parent-control.json") \
                and not re.fullmatch(r"completion-receipt\.[a-f0-9]{32}", name):
            raise AcceptanceError("invalid diagnostic artifact name")
        content = read(bundle / name)
        if len(content) != expected["bytes"] or hashlib.sha256(content).hexdigest() != expected["sha256"]:
            raise AcceptanceError("retained diagnostic artifact changed")


def capture(base, parent, child, reason):
    safe_name(child)
    if not re.fullmatch(r"[a-z0-9_-]{1,100}", reason):
        raise AcceptanceError("invalid diagnostic reason")
    root = base / (parent + ".review-diagnostics")
    root.mkdir(mode=0o700, exist_ok=True)
    directory(root)
    sync_dir(base)
    child_key = hashlib.sha256(child.encode()).hexdigest()[:32]
    bundles = sorted(item for item in root.iterdir() if BUNDLE_NAME.fullmatch(item.name))
    for bundle in bundles:
        if bundle.name.endswith("-" + child_key):
            validate_bundle(bundle, parent, child)
            return bundle
    temporary = Path(tempfile.mkdtemp(prefix=".pending-", dir=root))
    total = 0
    manifest = {"version": 1, "parent_session": parent, "child_session": child,
                "reason": reason, "artifacts": {}, "missing": [], "errors": {}}

    def retain(source, name):
        nonlocal total
        try:
            content = read(source)
            if len(content) > MAX_ARTIFACT or total + len(content) > MAX_BUNDLE:
                raise AcceptanceError("diagnostic size limit")
            write(temporary / name, content)
            total += len(content)
            manifest["artifacts"][name] = {"bytes": len(content),
                                           "sha256": hashlib.sha256(content).hexdigest()}
        except FileNotFoundError:
            manifest["missing"].append(name)
        except (AcceptanceError, OSError) as error:
            manifest["errors"][name] = str(error)

    try:
        for suffix in SUFFIXES:
            retain(base / (child + "." + suffix), suffix)
        receipts = []
        for candidate in base.glob(child + ".completion-receipt.*"):
            if re.fullmatch(r"[a-f0-9]{32}", candidate.name.rsplit(".", 1)[-1]):
                receipts.append(candidate)
                if len(receipts) == 4:
                    break
        if not receipts:
            manifest["missing"].append("completion-receipt")
        for receipt in receipts:
            retain(receipt, "completion-receipt." + receipt.name.rsplit(".", 1)[-1])
        retain(base / (parent + ".review-control.json"), "parent-control.json")
        retain(base / (parent + ".control"), "parent-control")
        created = max(time.time_ns(), max((int(item.name.split("-", 1)[0]) for item in bundles), default=0) + 1)
        if created >= 10 ** 20:
            raise AcceptanceError("invalid diagnostic sequence")
        manifest["created_at_ns"] = created
        write(temporary / "manifest.json", json.dumps(manifest, sort_keys=True).encode())
        target = root / (str(created) + "-" + child_key)
        os.rename(temporary, target)
        sync_dir(root)
        bundles.append(target)
        for old in sorted(bundles)[:-KEEP_BUNDLES]:
            remove(old)
        sync_dir(root)
        return target
    finally:
        remove(temporary)


def main(operation, base, parent, *args):
    base = Path(base)
    directory(base)
    safe_name(parent)
    if operation == "capture":
        print(capture(base, parent, *args))
    elif operation == "remove":
        remove(base / (parent + ".review-diagnostics"))
        sync_dir(base)
    else:
        raise AcceptanceError("unknown diagnostic operation")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:])
    except (AcceptanceError, OSError, ValueError, TypeError, KeyError) as error:
        print("Review diagnostics: " + str(error), file=sys.stderr)
        raise SystemExit(1)
