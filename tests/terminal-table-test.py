#!/usr/bin/env python3
"""Check terminal layout without losing identifiers or emitting controls."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "terminal-table.py"
SPEC = importlib.util.spec_from_file_location("terminal_table", SCRIPT)
TABLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TABLE)


class TableTests(unittest.TestCase):
    def test_unicode_and_numeric_columns_align(self):
        result = TABLE.render_table(["Name", "Left"], [["支店", "9%"], ["Cafe\u0301", "100%"]], right_align=[1])
        self.assertIn("支店    9%", result)
        self.assertIn("Cafe\u0301  100%", result)

    def test_wrap_preserves_long_identifiers_and_explicit_newlines(self):
        identifier = "account-" + "a" * 90
        result = TABLE.render_table(["Account"], [[identifier + "\nweekly-opus"]], width=20)
        self.assertTrue(all(len(line) <= 20 for line in result.splitlines()))
        self.assertEqual("".join(result.splitlines()[2:]), identifier + "weekly-opus")

    def test_narrow_terminals_keep_labelled_values(self):
        result = TABLE.render_table(["Account", "Status", "Reset"], [["Main", "disabled", "unknown"]], width=18)
        self.assertIn("Account: Main", result)
        self.assertIn("Status: disabled", result)
        self.assertIn("Reset: unknown", result)
        self.assertTrue(all(len(line) <= 18 for line in result.splitlines()))

    def test_control_sequences_cannot_change_the_terminal(self):
        result = TABLE.render_table(["Account"], [["\x1b[2JMain\x1b]0;title\x07\t\x00\r\u202e"]])
        self.assertEqual(result.splitlines()[-1], "Main")

    def test_redirected_output_ignores_terminal_environment_width(self):
        identifier = "account-" + "b" * 90
        result = subprocess.run([sys.executable, str(SCRIPT)], text=True, capture_output=True,
                                input=json.dumps({"headers": ["Account"], "rows": [[identifier]]}),
                                env={**os.environ, "COLUMNS": "20"}, check=True)
        self.assertIn(identifier, result.stdout)

    def test_empty_tables_and_mismatched_columns(self):
        self.assertEqual(TABLE.render_table(["Account"], []), "")
        with self.assertRaises(ValueError):
            TABLE.render_table(["Account", "Status"], [["Main"]])
        # A table of nothing but group rules has no rows to show.
        self.assertEqual(TABLE.render_table(["Account"], [None, None]), "")

    def test_group_rules_separate_rows_without_doubling(self):
        out = TABLE.render_table(["A", "B"], [["x", "1"], None, ["y", "2"]], width=40)
        lines = out.split("\n")
        rule = lines[1]
        self.assertEqual(lines, ["A  B", rule, "x  1", rule, "y  2"])
        # A rule against the header rule, or against another rule, is collapsed.
        leading = TABLE.render_table(["A", "B"], [None, ["x", "1"]], width=40)
        self.assertEqual(leading.split("\n"), ["A  B", rule, "x  1"])
        doubled = TABLE.render_table(["A", "B"], [["x", "1"], None, None, ["y", "2"]], width=40)
        self.assertEqual(doubled.split("\n"), ["A  B", rule, "x  1", rule, "y  2"])
        # A rule is not data: it must not widen a column or be aligned.
        self.assertEqual(TABLE.render_table(["A"], [["short"], None], width=40).split("\n")[0], "A    ".rstrip())

    def test_group_rules_survive_the_narrow_record_layout(self):
        # Too narrow for columns: records are printed instead, and a rule has
        # no record of its own to print.
        out = TABLE.render_table(["Account", "Status"], [["main", "ready"], None, ["other", "ready"]], width=8)
        self.assertNotIn("None", out)
        self.assertIn("main", out)
        self.assertIn("other", out)


if __name__ == "__main__":
    unittest.main()
