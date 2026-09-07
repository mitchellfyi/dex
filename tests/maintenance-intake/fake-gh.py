#!/usr/bin/env python3
"""Persistent fake GitHub API for subprocess integration tests."""
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, unquote, urlsplit

db_file = Path(os.environ["DX_INTAKE_TEST_DB"])
db = json.loads(db_file.read_text())
args = sys.argv[1:]
endpoint = args[1]
url = urlsplit(endpoint)
parts = url.path.split("/")
query = parse_qs(url.query)
db["calls"].append(endpoint)
rc = 0
result = None
if db.get("fail") and db["fail"] in endpoint:
    rc = 1
elif "/labels/" in endpoint:
    result = {"name": unquote(parts[-1])}
elif "/collaborators/" in endpoint:
    result = {"permission": db.get("permissions", {}).get(unquote(parts[-2]), db["permission"])}
elif len(parts) == 4 and parts[-1] == "issues":
    result = list(db["issues"].values())
elif len(parts) >= 5 and parts[3] == "issues":
    key = parts[4]
    if len(parts) == 5:
        result = db["issues"][key]
    elif parts[5] == "events":
        result = db["events"][key]
    elif parts[5] == "comments":
        if "--input" in args:
            payload = json.load(sys.stdin)
            result = {"id": len(db["comments"][key]) + 1, "body": payload["body"],
                      "user": {"login": "github-actions[bot]", "type": "Bot"},
                      "html_url": "https://github.com/o/r/issues/7#issuecomment-1"}
            if db["post_error"] != "rejected":
                db["comments"][key].append(result)
            if db["post_error"]:
                rc = 1
        else:
            result = db["comments"][key]
else:
    raise SystemExit(f"unexpected API endpoint: {endpoint}")
if isinstance(result, list) and "page" in query:
    page = int(query["page"][0])
    size = int(query["per_page"][0])
    result = result[(page-1)*size:page*size]
db_file.write_text(json.dumps(db))
if rc:
    print("simulated GitHub failure", file=sys.stderr)
else:
    print(json.dumps(result))
sys.exit(rc)
