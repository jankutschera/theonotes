#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/name-guard.py. Run: python3 -I scripts/tests/test_name_guard.py

Fixture trees are built in a temp directory. The old name is spelled by joining two strings so that
this file does not need a ledger entry of its own (the guard also skips it by name).
"""

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("name_guard", ROOT / "scripts" / "name-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

NAME = "Baer" + "chen"
LOWER = NAME.lower()
UMLAUT = "B\u00e4r" + "chen"


def entry(path, match, until="A3", reason="test"):
    return {"path": path, "match": match, "reason": reason, "until": until}


class Tree:
    """A temporary source tree with a ledger; not a git work tree unless `git()` is called."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="name-guard-test-"))

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def write(self, rel, text="x\n"):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def ledger(self, entries, rel="scripts/name-guard.json"):
        lines = ['{"entries": [']
        lines += ["  " + json.dumps(e, ensure_ascii=False) + ("," if i < len(entries) - 1 else "") for i, e in enumerate(entries)]
        lines += ["]}"]
        self.write(rel, "\n".join(lines) + "\n")

    def git(self):
        for args in (["init", "-q"], ["add", "-A"]):
            subprocess.run(["git", "-C", str(self.root)] + args, check=True, capture_output=True)

    def run(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = guard.main(["--root", str(self.root)] + list(args))
        return code, out.getvalue().splitlines(), err.getvalue()


class NameGuardTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()
        self.addCleanup(self.tree.close)

    def test_flags_unlisted_match(self):
        self.tree.write("src/a.txt", "one\nuses %sCore here\n" % NAME)
        self.tree.ledger([])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(lines, ["src/a.txt:2 unlisted-match:%sCore" % NAME])

    def test_listed_exact_string_passes(self):
        self.tree.write("src/a.txt", "uses %sCore here and %sCore again\n" % (NAME, NAME))
        self.tree.ledger([entry("src/a.txt", NAME + "Core")])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual((code, lines[-1][:14]), (0, "name-guard: ok"))

    def test_listed_path_but_other_string_fails(self):
        self.tree.write("src/a.txt", "%sCore and %sMac\n" % (NAME, NAME))
        self.tree.ledger([entry("src/a.txt", NAME + "Core")])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(lines, ["src/a.txt:1 unlisted-match:%sMac" % NAME])

    def test_listed_string_in_other_path_fails(self):
        self.tree.write("src/a.txt", "%sCore\n" % NAME)
        self.tree.write("other/b.txt", "%sCore\n" % NAME)
        self.tree.ledger([entry("src/*", NAME + "Core")])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual((code, lines), (1, ["other/b.txt:1 unlisted-match:%sCore" % NAME]))

    def test_walk_skips_generated_output_outside_a_work_tree(self):
        for rel in ("TheoNotes.xcodeproj/project.pbxproj", "build/DerivedData/x.txt", "Packages/Core/.build/y.txt"):
            self.tree.write(rel, "%s\n" % NAME)
        self.tree.ledger([])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual((code, lines[-1][:14]), (0, "name-guard: ok"))

    def test_directory_and_file_names_are_checked(self):
        self.tree.write("Packages/%sCore/Sources/%sApp.swift" % (NAME, NAME), "clean\n")
        self.tree.ledger([])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(sorted(lines), sorted([
            "Packages/%sCore/Sources/%sApp.swift:0 unlisted-name:%sCore" % (NAME, NAME, NAME),
            "Packages/%sCore/Sources/%sApp.swift:0 unlisted-name:%sApp.swift" % (NAME, NAME, NAME),
        ]))
        self.tree.ledger([entry("Packages/%sCore/**" % NAME, NAME + "Core"), entry("Packages/*/*/*", NAME + "App.swift")])
        self.assertEqual(self.tree.run("--check")[0], 0)

    def test_until_expired_entry_fails(self):
        self.tree.write("src/a.txt", "%sCore\n" % NAME)
        self.tree.write("src/b.txt", "%s-envelope-v1\n" % LOWER)
        self.tree.ledger([entry("src/a.txt", NAME + "Core", "B8"), entry("src/b.txt", LOWER + "-envelope-v1", "never")])
        self.assertEqual(self.tree.run("--check")[0], 0)
        code, lines, _ = self.tree.run("--check", "--phase", "B8")
        self.assertEqual(code, 1)
        self.assertEqual(len(lines), 1)
        self.assertRegex(lines[0], r"^scripts/name-guard\.json:2 expired-entry:until-B8$")

    def test_phase_expires_only_entries_up_to_that_task(self):
        self.tree.write("src/a.txt", "%sCore %s-test\n" % (NAME, LOWER))
        self.tree.ledger([entry("src/a.txt", NAME + "Core", "A3"), entry("src/a.txt", LOWER + "-test", "A4")])
        code, lines, _ = self.tree.run("--check", "--phase", "A3")
        self.assertEqual(code, 1)
        self.assertEqual(len(lines), 1)
        self.assertIn("expired-entry:until-A3", lines[0])
        self.assertEqual(self.tree.run("--check", "--phase", "A4")[0], 1)

    def test_strict_reports_entries_that_cover_nothing(self):
        self.tree.write("src/a.txt", "clean\n")
        self.tree.ledger([entry("src/a.txt", NAME + "Core")])
        self.assertEqual(self.tree.run("--check")[0], 0)
        code, lines, _ = self.tree.run("--check", "--strict")
        self.assertEqual(code, 1)
        self.assertIn("unused-entry:%sCore" % NAME, lines[0])

    def test_glob_star_stays_inside_one_directory(self):
        self.tree.write("a/b/c.txt", "%sCore\n" % NAME)
        self.tree.ledger([entry("a/*", NAME + "Core")])
        self.assertEqual(self.tree.run("--check")[0], 1)
        self.tree.ledger([entry("a/**", NAME + "Core")])
        self.assertEqual(self.tree.run("--check")[0], 0)

    def test_umlaut_and_case_variants_are_hits(self):
        self.tree.write("a.txt", "%s and %s and BAER%s\n" % (UMLAUT, LOWER, "CHEN"))
        self.tree.ledger([])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(len(lines), 3)

    def test_decomposed_umlaut_is_a_hit(self):
        self.tree.write("a.txt", "B\u0061\u0308rchen\n")
        self.tree.ledger([])
        self.assertEqual(self.tree.run("--check")[0], 1)

    def test_sentence_punctuation_is_not_part_of_the_token(self):
        self.tree.write("a.txt", "Quit %s. Then %s: done\n" % (NAME, NAME))
        self.tree.ledger([entry("a.txt", NAME)])
        self.assertEqual(self.tree.run("--check")[0], 0)

    def test_binary_content_is_skipped_but_its_name_is_checked(self):
        path = self.tree.root / ("img-%s.png" % LOWER)
        path.write_bytes(b"\x89PNG\0" + NAME.encode())
        self.tree.ledger([])
        code, lines, _ = self.tree.run("--check")
        self.assertEqual((code, lines), (1, ["img-%s.png:0 unlisted-name:img-%s.png" % (LOWER, LOWER)]))

    def test_the_guards_own_files_are_not_scanned(self):
        self.tree.write("scripts/name-guard.py", "%s\n" % NAME)
        self.tree.write("scripts/tests/test_name_guard.py", "%s\n" % NAME)
        self.tree.ledger([entry("zzz", NAME)])
        self.assertEqual(self.tree.run("--check")[0], 0)

    def test_git_work_tree_scans_tracked_files_only(self):
        self.tree.write("tracked.txt", "%sCore\n" % NAME)
        self.tree.ledger([])
        self.tree.git()
        self.tree.write("untracked.txt", "%sMac\n" % NAME)
        code, lines, _ = self.tree.run("--check")
        self.assertEqual((code, lines), (1, ["tracked.txt:1 unlisted-match:%sCore" % NAME]))

    def test_broken_ledger_is_an_error_not_a_pass(self):
        self.tree.write("scripts/name-guard.json", "{ nope")
        code, _, err = self.tree.run("--check")
        self.assertEqual(code, 2)
        self.assertIn("not valid JSON", err)
        self.tree.ledger([entry("a", "nothing here", "A3")])
        self.assertEqual(self.tree.run("--check")[0], 2)
        self.tree.ledger([entry("a", NAME, "someday")])
        self.assertEqual(self.tree.run("--check")[0], 2)

    def test_missing_ledger_is_an_error(self):
        self.tree.write("a.txt", "clean\n")
        self.assertEqual(self.tree.run("--check")[0], 2)

    def test_baseline_then_check_passes_and_labels_never_expire(self):
        self.tree.write("Packages/%sCore/Sources/x.swift" % NAME, "import %sCore\nlet l = \"%s-envelope-v1\"\n" % (NAME, LOWER))
        self.tree.write("docs/notes.md", "The %s app and %sCore.\n" % (NAME, NAME))
        self.tree.write("Info.plist", "<string>%s</string> %s://x\n" % (LOWER, LOWER))
        self.tree.ledger([])
        code, _, _ = self.tree.run("--baseline")
        self.assertEqual(code, 0)
        self.assertEqual(self.tree.run("--check")[0], 0)
        self.assertEqual(self.tree.run("--check", "--strict")[0], 0)
        ledger = json.loads((self.tree.root / "scripts/name-guard.json").read_text(encoding="utf-8"))["entries"]
        by_match = {(e["match"], e["until"]) for e in ledger}
        self.assertIn((LOWER + "-envelope-v1", "never"), by_match)
        self.assertIn((LOWER, "B8"), by_match)
        self.assertIn((NAME + "Core", "A3"), by_match)
        self.assertIn((NAME + "Core", "A7"), by_match)
        self.assertTrue(all(e["reason"] for e in ledger))
        code, lines, _ = self.tree.run("--check", "--phase", "B8")
        self.assertEqual(code, 1)
        self.assertTrue(all("expired-entry" in line for line in lines))
        self.assertEqual(len(lines), len([e for e in ledger if e["until"] != "never"]))

    def test_frozen_labels_classify_as_never_everywhere(self):
        for label in guard.FROZEN_LABELS:
            self.assertEqual(guard.classify("docs/x.md", label, "x")[0], "never", label)
            self.assertEqual(guard.classify("src/x.swift", label + ":acct:note:1", "x")[0], "never", label)
        self.assertEqual(len(guard.FROZEN_LABELS), 12)


class RepositoryTests(unittest.TestCase):
    def test_the_committed_ledger_covers_the_repository(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = guard.main(["--check"])
        self.assertEqual(code, 0, "\n".join(out.getvalue().splitlines()[:20]))


if __name__ == "__main__":
    unittest.main()
