import importlib.util
from types import SimpleNamespace
import unittest
from urllib.parse import parse_qs, urlsplit

from support import ROOT

spec = importlib.util.spec_from_file_location("maintenance_intake", ROOT / "scripts/maintenance-intake.py")
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)


class BudgetGitHub(intake.GitHub):
    def __init__(self, consumed=False):
        super().__init__("o/r")
        self.calls = 0
        self.permission = "write"
        self.issues = [{"number": number, "state": "open", "labels": [{"name": "dex-execute"}]}
                       for number in range(1, 251)]
        self.comments = {number: [] for number in range(1, 251)}
        if consumed:
            for number in range(1, 250):
                self.comments[number] = [self.record(number,
                    "Previous attempt\n\n" + intake.marker(f"o/r:{number}:{number}")
                    + "\n<!-- dex-maintenance-attempt:" + "a" * 32 + " -->")]

    @staticmethod
    def record(number, body):
        return {"id": number, "html_url": f"https://github.com/o/r/issues/{number}#issuecomment-1",
                "body": body, "user": {"login": "github-actions[bot]", "type": "Bot"}}

    def api(self, endpoint, payload=None):
        self.calls += 1
        if self.calls > 1000:
            raise intake.IntakeError("Workflow API budget exhausted")
        url = urlsplit(endpoint)
        parts = url.path.split("/")
        if parts[0] == "collaborators":
            return {"permission": self.permission}
        if parts == ["issues"]:
            result = self.issues
        else:
            number = int(parts[1])
            if len(parts) == 2:
                return self.issues[number - 1]
            if parts[2] == "events":
                result = [{"id": number, "event": "labeled", "label": {"name": "dex-execute"},
                           "actor": {"login": "owner"}, "created_at": "2026-01-01T00:00:00Z"}]
            elif payload is not None:
                record = self.record(number, payload["body"])
                self.comments[number].append(record)
                return record
            else:
                result = self.comments[number]
        page = int(parse_qs(url.query)["page"][0])
        return result[(page - 1) * 100:page * 100]


class BudgetTests(unittest.TestCase):
    def test_preparation_leaves_budget_to_claim_with_pending_or_consumed_backlog(self):
        for consumed in (False, True):
            with self.subTest(consumed=consumed):
                github = BudgetGitHub(consumed)
                candidate, skipped, queue = intake.select(github, SimpleNamespace(
                    event="schedule", label="dex-execute", limit=10))
                self.assertIsNotNone(candidate, f"No candidate after {github.calls} API calls")
                claimed = intake.claim(github, candidate, "dex-execute")
                self.assertTrue(claimed["claim_url"])
                self.assertEqual(250 if consumed else 1, claimed["issue_number"])
                self.assertLess(github.calls, 1000)
                self.assertEqual(1 if consumed else 10, len(queue))
                self.assertEqual(249 if consumed else 0, len(skipped))

    def test_claim_rechecks_permission_after_preparation(self):
        github = BudgetGitHub()
        github.issues = github.issues[:2]
        candidate, _, _ = intake.select(github, SimpleNamespace(
            event="schedule", label="dex-execute", limit=10))
        github.permission = "read"
        with self.assertRaisesRegex(intake.IntakeError, "access"):
            intake.claim(github, candidate, "dex-execute")
        self.assertEqual([], github.comments[1])
