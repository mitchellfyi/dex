#!/usr/bin/env python3
"""Select and consume GitHub requests within one serialized maintenance job.

Issue and scheduled runs must share the workflow's repository concurrency group.
Comments persist consumption across runners; GitHub has no atomic comment claim.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote
import uuid


class IntakeError(Exception):
    """Ticket intake could not establish a pending request."""


class GitHub:
    def __init__(self, repo):
        self.repo = repo

    def api(self, endpoint, payload=None):
        command = ["gh", "api", f"repos/{self.repo}/{endpoint}"]
        if payload is not None:
            command += ["--method", "POST", "--input", "-"]
        try:
            result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                                    text=True, capture_output=True, timeout=60, check=True)
            return json.loads(result.stdout)
        except (OSError, subprocess.SubprocessError, ValueError) as exc:
            raise IntakeError("GitHub request evidence is unavailable; ticket intake skipped.") from exc

    def pages(self, endpoint):
        items = []
        separator = "&" if "?" in endpoint else "?"
        for page in range(1, 1001):
            batch = self.api(f"{endpoint}{separator}per_page=100&page={page}")
            if not isinstance(batch, list) or any(not isinstance(item, dict) for item in batch):
                raise IntakeError("GitHub returned invalid request evidence.")
            items.extend(batch)
            if len(batch) < 100:
                return items
        raise IntakeError("Request history exceeded the scan limit; ticket intake skipped.")


def positive(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def marker(request_id):
    return f"<!-- dex-maintenance-request:v1:{request_id} -->"


def claim_record(comment, request_id, requester):
    """Accept complete records from Actions or the already-verified requester.

    Binding human records to the label applier avoids making old claims depend
    on another user's changing repository permissions. Workflow claims use the
    repository GITHUB_TOKEN, whose author is GitHub Actions.
    """
    user = comment.get("user") or {}
    actor = user.get("login", "").casefold()
    if actor != requester.casefold() and not (actor == "github-actions[bot]" and user.get("type") == "Bot"):
        return False
    lines = (comment.get("body") or "").splitlines()
    return (positive(comment.get("id")) and bool(comment.get("html_url"))
            and len(lines) == 4 and lines[1] == "" and lines[2] == marker(request_id)
            and re.fullmatch(r"<!-- dex-maintenance-attempt:[0-9a-f]{32} -->", lines[3]) is not None)


def request(github, number, label):
    """Read current issue state, label history, requester access, and consumption."""
    issue = github.api(f"issues/{number}")
    if (not isinstance(issue, dict) or issue.get("number") != number
            or issue.get("state") != "open" or "pull_request" in issue):
        raise IntakeError("The requested issue is closed, unavailable, or a pull request.")
    labels = issue.get("labels", [])
    if not any(isinstance(item, dict) and item.get("name", "").casefold() == label.casefold()
               for item in labels):
        raise IntakeError("The execution label is absent; no pending request.")
    events = github.pages(f"issues/{number}/events")
    label_events = [item for item in events if item.get("event") in ("labeled", "unlabeled")
                    and (item.get("label") or {}).get("name", "").casefold() == label.casefold()]
    if not label_events or any(not positive(item.get("id")) for item in label_events):
        raise IntakeError("The execution-label history could not be verified.")
    latest = max(label_events, key=lambda item: item["id"])
    if latest["event"] != "labeled":
        raise IntakeError("The execution request was cancelled.")
    actor = (latest.get("actor") or {}).get("login")
    created = latest.get("created_at", "")
    if not isinstance(actor, str) or not actor or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", created):
        raise IntakeError("The request's original label applier or time is unavailable.")
    permission = github.api(f"collaborators/{quote(actor, safe='')}/permission")
    if not isinstance(permission, dict) or permission.get("permission") not in ("admin", "maintain", "write"):
        raise IntakeError("The execution-label applier needs write, maintain, or admin access.")
    request_id = f"{github.repo.lower()}:{number}:{latest['id']}"
    comments = github.pages(f"issues/{number}/comments")
    if any(claim_record(comment, request_id, actor) for comment in comments):
        raise IntakeError("This request already used its attempt; remove and reapply the execution label to retry.")
    issue["comments"] = comments
    return {"issue_number": number, "request_id": request_id, "requester": actor,
            "request_time": created, "issue": issue}


def claim(github, candidate, label):
    current = request(github, candidate["issue_number"], label)
    if current["request_id"] != candidate["request_id"]:
        raise IntakeError("The request changed after selection; the new request remains pending.")
    attempt = uuid.uuid4().hex
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    run_url = ""
    if run_id.isdigit():
        run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{github.repo}/actions/runs/{run_id}"
    run_link = f"[Maintenance attempt]({run_url})" if run_url else "Maintenance attempt"
    body = (f"{run_link} claimed. Remove and reapply the execution label to request another attempt.\n\n"
            f"{marker(current['request_id'])}\n<!-- dex-maintenance-attempt:{attempt} -->")
    try:
        github.api(f"issues/{current['issue_number']}/comments", {"body": body})
    except IntakeError:
        # A timeout can follow a successful write. Never retry it blindly.
        pass
    comments = github.pages(f"issues/{current['issue_number']}/comments")
    records = [item for item in comments if claim_record(item, current["request_id"], current["requester"])]
    if len(records) != 1 or records[0].get("body") != body or not records[0].get("html_url"):
        raise IntakeError("The attempt claim could not be verified; no ticket work will launch. Check the issue before retrying.")
    current["issue"]["comments"] = comments
    current["claim_url"] = records[0]["html_url"]
    current["run_url"] = run_url
    return current


def select(github, args):
    if args.event == "issues":
        try:
            event = json.loads(Path(args.event_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise IntakeError("The issue event is unavailable or invalid.") from exc
        if (not isinstance(event, dict) or event.get("action") != "labeled"
                or (event.get("label") or {}).get("name", "").casefold() != args.label.casefold()):
            raise IntakeError("Only a new execution-label event requests ticket work.")
        number = (event.get("issue") or {}).get("number")
        if not positive(number):
            raise IntakeError("The issue event has no valid issue number.")
        candidate = request(github, number, args.label)
        return candidate, [], [{key: value for key, value in candidate.items() if key != "issue"}]
    pending, skipped = [], []
    # Match labels literally: GitHub's labels query treats commas as separators.
    for issue in github.pages("issues?state=open&sort=created&direction=asc"):
        if ("pull_request" in issue or not positive(issue.get("number"))
                or not any(isinstance(item, dict) and item.get("name", "").casefold() == args.label.casefold()
                           for item in issue.get("labels", []))):
            continue
        try:
            pending.append(request(github, issue["number"], args.label))
        except IntakeError as exc:
            skipped.append({"issue_number": issue["number"], "reason": str(exc)})
    pending.sort(key=lambda item: (item["request_time"], item["issue_number"]))
    queue = pending[:args.limit]
    return ((queue[0] if queue else None), skipped,
            [{key: value for key, value in item.items() if key != "issue"} for item in queue])


def atomic_json(target, value):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target.parent,
                                     prefix=f".{target.name}.", delete=False) as stream:
        scratch = Path(stream.name)
        try:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.close()
            os.replace(scratch, target)
        finally:
            scratch.unlink(missing_ok=True)


def focus(args):
    """Describe the wrapper's ticket authority, fetching manual issue context."""
    if args.intake_file:
        record = json.loads(Path(args.intake_file).read_text(encoding="utf-8"))
        if (record.get("version") != 1 or record.get("repo", "").casefold() != args.repo.casefold()
                or record.get("issue_number") != args.issue_number or record.get("proceed") is not True
                or not record.get("claim_url") or not record.get("request_id")):
            raise IntakeError("The selected issue has no matching verified workflow claim.")
        issue = json.loads(Path(args.intake_file).with_name("selected-issue.json").read_text(encoding="utf-8"))
        authority = {"source": record["event"], "issue_number": args.issue_number,
                     "request_id": record["request_id"], "claim_url": record["claim_url"]}
    else:
        issue = GitHub(args.repo).api(f"issues/{args.issue_number}")
        authority = {"source": "manual --issue", "issue_number": args.issue_number}
    if (not isinstance(issue, dict) or issue.get("number") != args.issue_number
            or issue.get("state") != "open" or "pull_request" in issue):
        raise IntakeError("The focused issue must be an open issue in this repository.")
    if not args.intake_file:
        issue["comments"] = GitHub(args.repo).pages(f"issues/{args.issue_number}/comments")
    atomic_json(args.context_dir / "selected-issue.json", issue)
    print(json.dumps(authority, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "claim", "focus"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--label", default="")
    parser.add_argument("--maintenance-label", default="dex-maintenance")
    parser.add_argument("--event", choices=("issues", "schedule", "workflow_dispatch"), default="workflow_dispatch")
    parser.add_argument("--event-path", default="")
    parser.add_argument("--context-dir", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--config-error", default="")
    parser.add_argument("--disabled", action="store_true")
    parser.add_argument("--issue-number", type=int, default=0)
    parser.add_argument("--intake-file", default="")
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo, flags=re.ASCII) or args.limit < 1:
        parser.error("invalid repository or queue limit")
    args.context_dir.mkdir(parents=True, exist_ok=True)
    if args.phase == "focus":
        if not positive(args.issue_number):
            parser.error("focus requires a positive issue number")
        try:
            focus(args)
        except (IntakeError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            parser.exit(1, f"Ticket focus could not be verified: {exc}\n")
        return
    state_file = args.context_dir / "intake.json"
    result = {"version": 1, "repo": args.repo, "event": args.event, "label": args.label,
              "proceed": args.event != "issues", "issue_number": None, "request_id": "",
              "requester": "", "claim_url": "", "reason": "No pending ticket requests.", "skipped": [], "queue": []}
    try:
        if args.disabled:
            result["proceed"] = False
            raise IntakeError("Maintenance is disabled in .dex/dex.md.")
        if (args.config_error or not args.label.strip() or args.label.strip() == "_none_"
                or args.label.casefold().startswith("triage:")
                or args.label.casefold() == args.maintenance_label.casefold()):
            raise IntakeError("Configure a dedicated Maintenance issue_label to enable ticket intake; readiness and PR labels cannot be used.")
        github = GitHub(args.repo)
        try:
            configured = github.api(f"labels/{quote(args.label, safe='')}")
            if not isinstance(configured, dict) or configured.get("name", "").casefold() != args.label.casefold():
                raise IntakeError("Invalid label response.")
        except IntakeError as exc:
            raise IntakeError("Configure and create the execution label; its availability could not be verified.") from exc
        if args.phase == "prepare":
            candidate, result["skipped"], result["queue"] = select(github, args)
        else:
            candidate = json.loads(state_file.read_text(encoding="utf-8"))
            if any(candidate.get(key) != result[key] for key in ("version", "repo", "event", "label")):
                raise IntakeError("The intake context no longer matches this invocation.")
            if candidate.get("claim_url"):
                raise IntakeError("This invocation already claimed an attempt; reruns require a new request.")
            result["skipped"] = candidate.get("skipped", [])
            result["queue"] = candidate.get("queue", [])
            candidate = claim(github, candidate, args.label) if candidate.get("issue_number") else None
        if candidate:
            issue = candidate.pop("issue", None)
            result.update(candidate, proceed=True,
                          reason="Ticket attempt claimed." if args.phase == "claim" else "Pending ticket request selected.")
            if issue is not None and args.phase == "claim":
                atomic_json(args.context_dir / "selected-issue.json", issue)
    except (IntakeError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        result["reason"] = str(exc) if isinstance(exc, IntakeError) else "Request evidence is invalid or unavailable; ticket intake skipped."
    if not result["claim_url"]:
        (args.context_dir / "selected-issue.json").unlink(missing_ok=True)
    atomic_json(state_file, result)
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as stream:
            stream.write(f"proceed={str(result['proceed']).lower()}\n")
            stream.write(f"issue_number={result['issue_number'] or ''}\n")
            stream.write(f"dir={args.context_dir}\n")
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as stream:
            stream.write(f"Ticket intake ({args.phase}): {result['reason']}\n\n")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
