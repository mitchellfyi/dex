"""Review checks reuse only complete evidence for the same inputs."""

import json
import os
from pathlib import Path
import subprocess
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

    def test_each_binding_invalidates_without_declared_inputs(self):
        spec = {**self.spec, "inputs": []}
        original = self.key(spec=spec)
        for index in range(4):
            bindings = self.bindings.copy()
            bindings[index] = "d" * 64
            self.assertNotEqual(original, self.key(spec=spec, bindings=bindings))

    def test_declared_inputs_scope_the_key_to_those_paths(self):
        """Declaring inputs narrows the binding to them.

        The scope and working-tree fingerprints are whole-checkout values, so
        keeping them in the key would mean any fix anywhere invalidated the
        receipt — the rule this replaces. The criteria and policy bindings stay:
        they say what the check was run to prove.
        """
        original = self.key()
        for index in (0, 1):
            bindings = self.bindings.copy()
            bindings[index] = "d" * 64
            self.assertEqual(original, self.key(bindings=bindings))
        for index in (2, 3):
            bindings = self.bindings.copy()
            bindings[index] = "d" * 64
            self.assertNotEqual(original, self.key(bindings=bindings))

    def test_scoped_and_unscoped_keys_never_collide(self):
        self.assertNotEqual(self.key(), self.key(spec={**self.spec, "inputs": []}))

    def test_autofix_is_optional_and_declared(self):
        """`autofix` is how a wave earns the right to report MECHANICAL:N.

        The runner does nothing with it, but it is part of the spec, so it is
        part of the key: a command that starts rewriting its inputs must not
        reuse the receipt it earned while it did not.
        """
        checks.validate_spec({**self.spec, "autofix": True})
        self.assertNotEqual(self.key(), self.key(spec={**self.spec, "autofix": True}))
        for invalid in ({**self.spec, "autofix": "yes"}, {**self.spec, "unknown": 1}):
            with self.assertRaises(checks.CheckError):
                checks.validate_spec(invalid)

    def test_unrelated_checkout_change_keeps_a_scoped_receipt(self):
        """The point of the narrowing: a fix elsewhere is not this check's problem."""
        repo = self.root / "repo"
        (repo / "src").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
        watched = repo / "src" / "watched.txt"
        watched.write_text("watched")
        (repo / "src" / "other.txt").write_text("other")
        for command in (["add", "-A"], ["-c", "user.email=d@e.test", "-c",
                                        "user.name=Dex", "commit", "-qm", "init"]):
            subprocess.run(["git", "-C", str(repo), *command], check=True)
        scoped = {**self.spec, "inputs": [str(watched)]}
        unscoped = {**self.spec, "inputs": []}
        previous = os.getcwd()
        os.chdir(repo)
        try:
            scoped_before = checks.fingerprint(
                scoped, self.bindings, {"PATH": os.environ["PATH"]},
                include_checkout=True)
            unscoped_before = checks.fingerprint(
                unscoped, self.bindings, {"PATH": os.environ["PATH"]},
                include_checkout=True)
            (repo / "src" / "other.txt").write_text("other, edited")
            self.assertEqual(scoped_before, checks.fingerprint(
                scoped, self.bindings, {"PATH": os.environ["PATH"]},
                include_checkout=True))
            self.assertNotEqual(unscoped_before, checks.fingerprint(
                unscoped, self.bindings, {"PATH": os.environ["PATH"]},
                include_checkout=True))
            # A change to a declared input still invalidates its receipt.
            watched.write_text("watched, edited")
            self.assertNotEqual(scoped_before, checks.fingerprint(
                scoped, self.bindings, {"PATH": os.environ["PATH"]},
                include_checkout=True))
        finally:
            os.chdir(previous)

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
