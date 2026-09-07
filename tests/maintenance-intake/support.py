import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IntakeCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dex-intake-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.context = self.root / "context"
        self.event = {"action": "labeled", "label": {"name": "dex-execute"},
                      "issue": {"number": 7}}
        self.db = {"issues": {}, "events": {}, "comments": {}, "calls": [],
                   "permission": "write", "post_error": "", "fail": ""}
        self.add_issue(7, 100)
        fake = self.root / "bin"
        fake.mkdir()
        (fake / "gh").write_text((Path(__file__).with_name("fake-gh.py")).read_text())
        (fake / "gh").chmod(0o755)
        self.env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"],
                        DX_INTAKE_TEST_DB=str(self.root / "db.json"))

    def add_issue(self, number, event_id, label="dex-execute", **extra):
        key = str(number)
        self.db["issues"][key] = dict(number=number, title=f"Issue {number}", state="open",
                                      labels=[{"name": label}], html_url=f"https://github.com/o/r/issues/{number}",
                                      body="Product context", **extra)
        self.db["events"][key] = [{"id": event_id, "event": "labeled", "label": {"name": label},
                                  "actor": {"login": "owner"}, "created_at": f"2026-01-01T00:{event_id//100:02}:00Z"}]
        self.db["comments"][key] = []

    def invoke(self, phase="prepare", event="issues", label="dex-execute", limit=10):
        (self.root / "db.json").write_text(json.dumps(self.db))
        (self.root / "event.json").write_text(json.dumps(self.event))
        result = subprocess.run(["python3", str(ROOT / "scripts/maintenance-intake.py"), phase,
                                 "--repo", "o/r", "--label", label, "--maintenance-label", "dex-maintenance",
                                 "--event", event, "--event-path", str(self.root / "event.json"),
                                 "--context-dir", str(self.context), "--limit", str(limit)],
                                env=self.env, text=True, capture_output=True, check=True)
        self.db = json.loads((self.root / "db.json").read_text())
        return json.loads(result.stdout)
