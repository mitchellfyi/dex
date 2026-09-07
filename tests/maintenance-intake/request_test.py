from support import IntakeCase


class RequestTests(IntakeCase):
    def test_label_requests_one_attempt_across_fresh_processes(self):
        pending = self.invoke()
        self.assertTrue(pending["proceed"])
        self.assertEqual(7, pending["issue_number"])
        self.assertEqual([], self.db["comments"]["7"])
        claimed = self.invoke("claim")
        self.assertTrue(claimed["proceed"])
        self.assertTrue(claimed["claim_url"])
        self.assertEqual(1, len(self.db["comments"]["7"]))
        self.assertFalse(self.invoke()["proceed"])

    def test_ordinary_triage_events_never_request_work(self):
        for action in ("opened", "edited", "reopened", "unlabeled"):
            with self.subTest(action=action):
                self.event["action"] = action
                self.assertFalse(self.invoke()["proceed"])
        self.event["action"] = "labeled"
        for label in ("triage:ready", "triage:needs-info", "bug"):
            with self.subTest(label=label):
                self.event["label"]["name"] = label
                self.assertFalse(self.invoke()["proceed"])
        self.assertEqual([], self.db["comments"]["7"])

    def test_legacy_or_conflicting_label_skips_with_notice(self):
        for label in ("", "_none_", "triage:ready", "TRIAGE:needs-info", "dex-maintenance"):
            with self.subTest(label=label):
                result = self.invoke(label=label)
                self.assertFalse(result["proceed"])
                self.assertIn("configure", result["reason"].lower())

    def test_original_label_applier_needs_write_permission(self):
        for permission in ("read", "triage", "none", ""):
            self.db["permission"] = permission
            self.assertFalse(self.invoke()["proceed"])
        for permission in ("admin", "maintain", "write"):
            self.db["permission"] = permission
            self.assertTrue(self.invoke()["proceed"])

    def test_closed_pull_request_and_cancelled_requests_skip(self):
        self.db["issues"]["7"]["state"] = "closed"
        self.assertFalse(self.invoke()["proceed"])
        self.db["issues"]["7"]["state"] = "open"
        self.db["issues"]["7"]["pull_request"] = {}
        self.assertFalse(self.invoke()["proceed"])
        del self.db["issues"]["7"]["pull_request"]
        self.db["issues"]["7"]["labels"] = []
        self.assertFalse(self.invoke()["proceed"])

    def test_custom_unicode_label_is_literal(self):
        label = "exécuter, maintenant"
        self.add_issue(7, 100, label=label)
        self.event["label"]["name"] = label
        self.assertTrue(self.invoke(label=label)["proceed"])
