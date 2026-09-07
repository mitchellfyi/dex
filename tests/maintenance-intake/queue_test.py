from support import IntakeCase


class QueueTests(IntakeCase):
    def test_empty_or_legacy_queue_preserves_independent_maintenance(self):
        self.db["issues"] = {}
        for event in ("schedule", "workflow_dispatch"):
            result = self.invoke(event=event)
            self.assertTrue(result["proceed"])
            self.assertIsNone(result["issue_number"])
        result = self.invoke(event="schedule", label="_none_")
        self.assertTrue(result["proceed"])
        self.assertIsNone(result["issue_number"])
        self.assertIn("Configure", result["reason"])

    def test_queue_selects_oldest_request_and_claims_only_one(self):
        self.add_issue(8, 50)
        self.add_issue(9, 200)
        result = self.invoke(event="schedule", limit=1)
        self.assertEqual(8, result["issue_number"])
        self.assertEqual([], self.db["comments"]["8"])
        self.assertEqual(8, self.invoke("claim", event="schedule", limit=1)["issue_number"])
        self.assertEqual([], self.db["comments"]["7"])
        self.assertEqual([], self.db["comments"]["9"])

    def test_permission_uses_label_applier_on_scheduled_runs(self):
        self.db["permission"] = "read"
        result = self.invoke(event="schedule")
        self.assertTrue(result["proceed"])
        self.assertIsNone(result["issue_number"])
        self.assertIn("applier", result["skipped"][0]["reason"])

    def test_consumed_requests_are_filtered_before_queue_limit(self):
        self.invoke()
        self.invoke("claim")
        self.add_issue(8, 200)
        self.assertEqual(8, self.invoke(event="schedule", limit=1)["issue_number"])

    def test_candidate_pagination_does_not_stop_at_unrequested_issues(self):
        for number in range(8, 111):
            self.add_issue(number, 100, label="triage:ready")
        self.add_issue(112, 50)
        self.assertEqual(112, self.invoke(event="schedule", limit=1)["issue_number"])

    def test_serialized_direct_and_scheduled_deliveries_share_consumption(self):
        direct_context = self.context
        self.invoke()
        self.context = self.root / "scheduled"
        self.invoke(event="schedule")
        self.context = direct_context
        self.invoke("claim")
        self.context = self.root / "scheduled"
        result = self.invoke("claim", event="schedule")
        self.assertTrue(result["proceed"])
        self.assertIsNone(result["issue_number"])
        self.assertFalse((self.context / "selected-issue.json").exists())
        self.assertEqual(1, len(self.db["comments"]["7"]))

    def test_unavailable_queue_reports_the_gap_without_unrestricted_context(self):
        self.db["fail"] = "issues?"
        result = self.invoke(event="schedule")
        self.assertTrue(result["proceed"])
        self.assertIsNone(result["issue_number"])
        self.assertIn("unavailable", result["reason"])
        self.assertFalse((self.context / "selected-issue.json").exists())

    def test_equal_request_times_use_issue_number(self):
        self.add_issue(6, 101)
        self.db["issues"]["7"]["updated_at"] = "2027-01-01T00:00:00Z"
        self.assertEqual(6, self.invoke(event="schedule")["issue_number"])
