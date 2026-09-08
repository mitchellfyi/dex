"""Review checks reuse only complete evidence for the same inputs."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import review_checks as checks


class ReviewCheckCacheTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.input = self.root / "dependency.txt"
        self.input.write_text("version one")
        self.spec = {
            "name": "syntax", "argv": [sys.executable, "-c", "pass"],
            "cache": "snapshot", "inputs": [str(self.input)], "tools": [],
        }
        self.bindings = ["a" * 64, "b" * 64, "standalone", "c" * 64]

    def key(self, spec=None, bindings=None, environment=None):
        return checks.fingerprint(spec or self.spec, bindings or self.bindings,
                                  environment or {"PATH": os.environ["PATH"]})

    def test_same_inputs_have_same_key(self):
        self.assertEqual(self.key(), self.key())

    def test_each_binding_invalidates(self):
        original = self.key()
        for index in range(4):
            bindings = self.bindings.copy()
            bindings[index] = "d" * 64
            self.assertNotEqual(original, self.key(bindings=bindings))

    def test_command_and_environment_invalidate(self):
        self.assertNotEqual(self.key(), self.key(spec={**self.spec, "argv":
                            [sys.executable, "-c", "print(1)"]}))
        self.assertNotEqual(self.key(), self.key(environment={"PATH":
                            os.environ["PATH"], "CHECK_MODE": "strict"}))

    def test_source_changes_invalidate_even_with_same_size(self):
        original = self.key()
        self.input.write_text("version two")
        self.assertNotEqual(original, self.key())

    def test_directory_addition_invalidates(self):
        self.spec["inputs"] = [str(self.root)]
        original = self.key()
        (self.root / "new.txt").write_text("new dependency")
        self.assertNotEqual(original, self.key())

    def test_missing_or_cyclic_input_refuses_reuse(self):
        self.input.unlink()
        with self.assertRaises(checks.CheckError):
            self.key()
        self.input.symlink_to(self.input)
        with self.assertRaises(checks.CheckError):
            self.key()

    def test_tool_content_invalidates(self):
        self.spec["tools"] = [str(self.input)]
        original = self.key()
        self.input.write_text("different executable")
        self.assertNotEqual(original, self.key())

    def test_child_session_metadata_does_not_invalidate(self):
        before = {"PATH": os.environ["PATH"], "DEX_SESSION_ID": "pass-one",
                  "CODEX_THREAD_ID": "thread-one", "CODEX_SESSION_ID": "session-one"}
        after = {"PATH": os.environ["PATH"], "DEX_SESSION_ID": "pass-two",
                 "CODEX_THREAD_ID": "thread-two", "CODEX_SESSION_ID": "session-two"}
        self.assertEqual(self.key(environment=before), self.key(environment=after))

    def test_uncached_command_retains_orchestration_environment(self):
        environment = {"DEX_SESSION_ID": "fixture", "CODEX_THREAD_ID": "thread"}
        self.assertEqual(environment, checks.execution_environment(environment, reusable=False))
        self.assertEqual({}, checks.execution_environment(environment))

    def test_unknown_environment_variables_do_invalidate(self):
        before = {"PATH": os.environ["PATH"], "DEX_CUSTOM_CHECK_SETTING": "one"}
        after = {**before, "DEX_CUSTOM_CHECK_SETTING": "two"}
        self.assertNotEqual(self.key(environment=before), self.key(environment=after))

    def test_receipt_roundtrip_and_wrong_key(self):
        target = self.root / "receipt.json"
        key = self.key()
        checks.record(target, key, 12)
        self.assertEqual(12, checks.cached(target, key))
        self.assertIsNone(checks.cached(target, "f" * 64))
        self.assertEqual(0o600, target.stat().st_mode & 0o777)

    def test_malformed_failed_or_symlinked_receipts_are_misses(self):
        target = self.root / "receipt.json"
        for payload in ["broken", json.dumps({"version": 1, "key": self.key(),
                         "status": "fail", "duration_seconds": 12})]:
            target.write_text(payload)
            self.assertIsNone(checks.cached(target, self.key()))
        link = self.root / "link.json"
        link.symlink_to(target)
        self.assertIsNone(checks.cached(link, self.key()))
        with self.assertRaises(checks.CheckError):
            checks.record(link, self.key(), 12)

    def test_spec_rejects_empty_command_unknown_keys_and_invalid_cache(self):
        for spec in [{**self.spec, "argv": []}, {**self.spec, "extra": 1},
                     {**self.spec, "cache": "always"}]:
            with self.subTest(spec=spec), self.assertRaises(checks.CheckError):
                checks.validate_spec(spec)


if __name__ == "__main__":
    unittest.main()
