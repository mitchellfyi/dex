import json

from support import IntakeCase


class RecoveryTests(IntakeCase):
    def test_lost_post_response_is_reconciled_without_another_write(self):
        self.invoke()
        self.db["post_error"] = "accepted-but-disconnected"
        self.assertTrue(self.invoke("claim")["claim_url"])
        self.assertEqual(1, len(self.db["comments"]["7"]))
        self.assertFalse(self.invoke("claim")["proceed"])
        self.assertEqual(1, len(self.db["comments"]["7"]))

    def test_rejected_claim_never_launches(self):
        self.invoke()
        self.db["post_error"] = "rejected"
        result = self.invoke("claim")
        self.assertFalse(result["proceed"])
        self.assertIn("could not be verified", result["reason"])
        self.assertFalse((self.context / "selected-issue.json").exists())

    def test_reapply_creates_new_request_but_edits_do_not(self):
        first = self.invoke()["request_id"]
        self.invoke("claim")
        self.db["issues"]["7"]["body"] = "Updated acceptance criteria"
        self.assertFalse(self.invoke()["proceed"])
        event = dict(self.db["events"]["7"][0], id=101)
        self.db["events"]["7"].extend([dict(event, event="unlabeled"), dict(event, id=102)])
        next_request = self.invoke()
        self.assertTrue(next_request["proceed"])
        self.assertNotEqual(first, next_request["request_id"])
        self.assertTrue(self.invoke("claim")["claim_url"])
        self.assertEqual(2, len(self.db["comments"]["7"]))

    def test_cancel_between_selection_and_claim_leaves_no_attempt(self):
        self.invoke()
        self.db["issues"]["7"]["labels"] = []
        self.assertFalse(self.invoke("claim")["proceed"])
        self.assertEqual([], self.db["comments"]["7"])

    def test_replacement_after_selection_stays_pending(self):
        self.invoke()
        self.db["events"]["7"].append(dict(self.db["events"]["7"][0], id=103))
        self.assertFalse(self.invoke("claim")["proceed"])
        self.assertEqual([], self.db["comments"]["7"])
        self.assertTrue(self.invoke()["proceed"])

    def test_unavailable_or_corrupt_evidence_never_authorises(self):
        for endpoint in ("/events", "/comments", "/permission", "/labels/"):
            with self.subTest(endpoint=endpoint):
                self.db["fail"] = endpoint
                self.assertFalse(self.invoke()["proceed"])
        self.db["fail"] = ""
        self.db["events"]["7"] = []
        self.assertFalse(self.invoke()["proceed"])

    def test_history_and_consumption_are_paginated(self):
        self.db["events"]["7"] = [{"id": n, "event": "commented"} for n in range(100)] + self.db["events"]["7"]
        self.assertTrue(self.invoke()["proceed"])
        self.db["comments"]["7"] = [{"body": "Earlier discussion"} for _ in range(100)]
        self.invoke("claim")
        self.assertFalse(self.invoke()["proceed"])
        self.assertTrue(any("comments?per_page=100&page=2" in call for call in self.db["calls"]))

    def test_mismatched_prepared_context_never_claims(self):
        self.invoke()
        target = self.context / "intake.json"
        state = json.loads(target.read_text())
        state["repo"] = "different/repository"
        target.write_text(json.dumps(state))
        self.assertFalse(self.invoke("claim")["proceed"])
        self.assertEqual([], self.db["comments"]["7"])
