import json
import subprocess

from support import IntakeCase, ROOT


def step(name):
    workflow = (ROOT / ".github/workflows/dx-maintain.yml").read_text()
    block = workflow.split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]
    script = block.split("        run: |\n", 1)[1]
    return block, "\n".join(line[10:] if line.startswith("          ") else line for line in script.splitlines())


class WorkflowTests(IntakeCase):
    def setUp(self):
        super().setUp()
        (self.root / ".dex").mkdir()
        (self.root / ".dex/dex.md").write_text("## Maintenance\n\n| Setting | Value |\n| issue_label | dex-execute |\n")

    def execute(self, name, event="issues", **extra):
        (self.root / "db.json").write_text(json.dumps(self.db))
        (self.root / "event.json").write_text(json.dumps(self.event))
        env = dict(self.env, DEX_DIR=str(ROOT), GH_REPO="o/r", EVENT_NAME=event,
                   GITHUB_EVENT_PATH=str(self.root / "event.json"),
                   DX_ARTIFACT_DIR=str(self.root / "artifacts"), GITHUB_OUTPUT=str(self.root / "output"),
                   GITHUB_STEP_SUMMARY=str(self.root / "summary"), **extra)
        result = subprocess.run(["bash", "-c", step(name)[1]], cwd=self.root, env=env,
                                text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.db = json.loads((self.root / "db.json").read_text())
        return json.loads(result.stdout) if result.stdout.strip() else None

    def test_workflow_skips_triage_edits_before_provider_setup(self):
        self.event["action"] = "edited"
        self.assertFalse(self.execute("Select pending ticket request")["proceed"])
        provider = step("Configure agent provider")[0]
        self.assertIn("if: ${{ steps.issue_intake.outputs.proceed == 'true' }}", provider)
        self.assertEqual([], self.db["comments"]["7"])

    def test_workflow_defers_consumption_until_provider_setup_then_passes_focus(self):
        self.assertTrue(self.execute("Select pending ticket request")["proceed"])
        self.assertEqual([], self.db["comments"]["7"])
        result = self.execute("Claim selected ticket request")
        self.assertTrue(result["claim_url"])
        self.assertIn("if: ${{ steps.provider.outputs.ready == 'true' }}", step("Claim selected ticket request")[0])
        workflow = (ROOT / ".github/workflows/dx-maintain.yml").read_text()
        self.assertLess(workflow.index("name: Resolve maintenance mode"), workflow.index("name: Claim selected ticket request"))
        self.assertIn("group: dx-maintain-${{ github.repository }}-nightly", workflow)
        self.assertIn("cancel-in-progress: false", workflow)

    def test_actual_run_step_passes_scheduled_focus_and_scrubs_credentials(self):
        self.execute("Select pending ticket request", event="schedule")
        self.execute("Claim selected ticket request", event="schedule")
        runtime = self.root / "runtime"
        (runtime / "bin").mkdir(parents=True)
        capture = self.root / "launch.json"
        (runtime / "bin/maintain.sh").write_text('''#!/usr/bin/env bash
python3 - "$@" <<'PY'
import json, os, sys
from pathlib import Path
Path(os.environ['DX_TEST_LAUNCH']).write_text(json.dumps({'args': sys.argv[1:], 'token': os.environ.get('GH_TOKEN')}))
PY
''')
        env = dict(self.env, DEX_DIR=str(runtime), MODE="report", SINCE="", EVENT_NAME="schedule",
                   ISSUE_NUMBER="7", ISSUE_CONTEXT_DIR=str(self.root / "artifacts/maintenance/issue-intake"),
                   GH_TOKEN="test-placeholder", DX_TEST_LAUNCH=str(capture))
        subprocess.run(["bash", "-c", step("Run DX maintain")[1]], cwd=self.root, env=env, check=True)
        invocation = json.loads(capture.read_text())
        self.assertIn("--issue", invocation["args"])
        self.assertEqual("7", invocation["args"][invocation["args"].index("--issue") + 1])
        self.assertIsNone(invocation["token"])

    def test_disabled_or_duplicate_configuration_cannot_consume(self):
        config = self.root / ".dex/dex.md"
        config.write_text(config.read_text() + "| enabled | false |\n")
        self.assertFalse(self.execute("Select pending ticket request", event="schedule")["proceed"])
        config.write_text("## Maintenance\n| issue_label | dex-execute |\n| issue_label | another |\n")
        self.assertFalse(self.execute("Select pending ticket request")["proceed"])
        self.assertEqual([], self.db["comments"]["7"])

    def test_manual_focus_bypasses_labels_without_consuming_queue_request(self):
        self.db["issues"]["7"]["labels"] = []
        (self.root / "db.json").write_text(json.dumps(self.db))
        result = subprocess.run(["bash", "-c", 'source "$DEX_DIR/lib/common.sh"; dx_maintenance_issue_focus "$PWD" 7 "$PWD/focus"'],
                                cwd=self.root, env=dict(self.env, DEX_DIR=str(ROOT), GH_REPO="o/r", DX_MAINTAIN_INTAKE_FILE=""),
                                text=True, capture_output=True, check=True)
        authority = json.loads(result.stdout)
        self.assertEqual("manual --issue", authority["source"])
        self.assertEqual(7, json.loads((self.root / "focus/selected-issue.json").read_text())["number"])
        self.db = json.loads((self.root / "db.json").read_text())
        self.assertEqual([], self.db["comments"]["7"])

    def test_workflow_focus_requires_matching_claim_and_issue(self):
        self.invoke()
        self.invoke("claim")
        for number, succeeds in ((7, True), (8, False)):
            with self.subTest(number=number):
                result = subprocess.run(["python3", str(ROOT / "scripts/maintenance-intake.py"), "focus",
                                         "--repo", "o/r", "--issue-number", str(number),
                                         "--intake-file", str(self.context / "intake.json"),
                                         "--context-dir", str(self.root / "focus")],
                                        env=self.env, text=True, capture_output=True)
                self.assertEqual(succeeds, result.returncode == 0, result.stderr)

    def test_unclaimed_context_does_not_grant_ticket_execution(self):
        self.invoke()
        result = subprocess.run(["python3", str(ROOT / "scripts/maintenance-intake.py"), "focus",
                                 "--repo", "o/r", "--issue-number", "7",
                                 "--intake-file", str(self.context / "intake.json"),
                                 "--context-dir", str(self.root / "focus")],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "focus/selected-issue.json").exists())
