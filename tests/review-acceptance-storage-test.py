"""Interrupted checkpoint installation and unsafe filesystem inputs."""

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import review_acceptance as acceptance


class AcceptanceStorageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dex-acceptance-storage-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)

    def checkpoint(self):
        values = dict.fromkeys(acceptance.FIELDS, "fixture")
        values.update(child="child", pass_id="pass", generation="a" * 32,
                      required="2", iteration="2", clean="2", total="0",
                      scope="b" * 64, working="c" * 64, policy="d" * 64,
                      scope_before="b" * 64)
        for suffix in ("review-context", "review-evidence.json", "completion-expectation",
                       "completion-receipt." + values["generation"]):
            acceptance.write(self.base / ("child." + suffix), b"fixture")
        for suffix in ("review-state", "review-ledger"):
            acceptance.write(self.base / ("parent." + suffix), b"before")
        acceptance.begin(self.base, "parent", self.base, [values[key] for key in acceptance.FIELDS])
        root = self.base / "parent.review-acceptance"
        acceptance.run("stage", self.base, "parent")
        for suffix in ("review-state", "review-ledger"):
            acceptance.write(root / "stage" / ("parent." + suffix), b"after")
        acceptance.run("seal", self.base, "parent")
        acceptance.run("commit", self.base, "parent")
        return root

    def test_interrupted_install_replays_the_checkpoint_once(self):
        root = self.checkpoint()
        original_copy = acceptance.copy

        def interrupted_copy(source, target):
            if source.name == "parent.review-ledger":
                raise OSError("simulated interrupted ledger write")
            original_copy(source, target)

        with patch.object(acceptance, "copy", interrupted_copy), self.assertRaises(OSError):
            acceptance.run("install", self.base, "parent")
        self.assertEqual(b"after", (self.base / "parent.review-state").read_bytes())
        self.assertFalse((self.base / "parent.review-ledger").exists())
        self.assertTrue((root / "committed").exists())
        for _ in range(2):
            acceptance.run("install", self.base, "parent")
            self.assertEqual(b"after", (self.base / "parent.review-state").read_bytes())
            self.assertEqual(b"after", (self.base / "parent.review-ledger").read_bytes())

    def test_interrupted_input_capture_can_resume_before_any_parent_writes(self):
        original_capture = acceptance.capture_inputs
        with patch.object(acceptance, "capture_inputs", side_effect=OSError("interrupted copy")):
            with self.assertRaises(OSError):
                self.checkpoint()
        root = self.base / "parent.review-acceptance"
        self.assertTrue((root / "record.json").exists())
        self.assertFalse((root / "inputs.sha256").exists())
        self.assertEqual(b"before", (self.base / "parent.review-state").read_bytes())
        data = acceptance.metadata(root, "parent")
        original_capture(root, self.base, "parent", data)
        acceptance.validate_inputs(root)

    def test_changed_checkpoint_is_rejected_before_install(self):
        root = self.checkpoint()
        acceptance.write(root / "stage" / "parent.review-state", b"changed")
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.run("install", self.base, "parent")
        self.assertEqual(b"before", (self.base / "parent.review-state").read_bytes())

    def test_links_and_special_files_are_rejected_without_following_them(self):
        target = self.base / "outside"
        target.write_text("preserve me")
        link = self.base / "link"
        link.symlink_to(target)
        fifo = self.base / "fifo"
        os.mkfifo(fifo)
        for candidate in (link, fifo):
            with self.subTest(candidate=candidate), self.assertRaises(acceptance.AcceptanceError):
                acceptance.read(candidate)
        self.assertEqual("preserve me", target.read_text())

    def test_oversized_files_and_nested_links_are_rejected(self):
        target = self.base / "large"
        with target.open("wb") as stream:
            stream.truncate(acceptance.MAX_FILE + 1)
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.read(target)
        target.unlink()
        nested = self.base / "nested"
        nested.mkdir()
        (nested / "link").symlink_to(self.base)
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.remove(nested)
        self.assertTrue((nested / "link").is_symlink())


if __name__ == "__main__":
    unittest.main()
