#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/oss/export.py and scripts/oss/scan.py (REN2-R20..R29).
Run: python3 -I scripts/tests/test_oss_export.py

Every scan rule is proven twice on a temporary git repository: a planted file makes the export fail with
that rule's finding, and with the rule switched off the same tree goes through. A last test empties the
whole rule set to show that a seeded tree is only stopped because the rules exist.

Planted strings are assembled from parts so this file does not trip the scanner itself.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
OSS = ROOT / "scripts" / "oss"
EXPORT = OSS / "export.py"
SCAN = OSS / "scan.py"
REAL_MANIFEST = json.loads((OSS / "manifest.json").read_text(encoding="utf-8"))

spec = importlib.util.spec_from_file_location("oss_scan_under_test", SCAN)
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

OLD = "Baer" + "chen"
SENTENCE = "the quick amber lantern drifts quietly over seven silver hills at dawn"
HELP_SENTENCE = "Moves a note to the archive so that it is hidden from the main list of every user."
TOKEN = "Zq8rK3fV7mXp2LwB9tYs4NcD6hJg1AeU5oRi0Tx"
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com"}

CLEAN = {
    "README.md": "# Theo Notes\n\nA notes app.\n",
    "project.yml": "name: TheoNotes\n",
    "Packages/Core/Sources/Core.swift": "let answer = 42\n",
    "web/editor/index.html": "<p>Capture and return.</p>\n",
    "config/release.env": "TEAM=" + "5KZGD4R9" + "K7\n",
}

# One planted file per rule: rule -> (extra rules to switch off so only this one is judged, {path: content})
PLANTS = {
    "forbidden-path": ((), {"docs/oracle/library.md": "private\n"}),
    "working-title": ((), {"Apps/Main/App.swift": f'let name = "{OLD}"\n'}),
    "bear-text": ((), {"Fixtures/links.json": '{"url": "https://bear' + '.app/faq/"}\n'}),
    "ip-guard": (("research-shingle",), {
        "docs/research/bearcli-help-all.txt": HELP_SENTENCE + "\n",
        "Apps/Main/Help.swift": f'let help = "{HELP_SENTENCE}"\n'}),
    "research-shingle": (("ip-guard",), {
        "docs/research/raw/faq.md": SENTENCE + ".\n",
        "Apps/Main/Notes.swift": f"// {SENTENCE}\n"}),
    "adhd-copy": ((), {"README.md": "<p>For " + "AD" + "HD" + " brains</p>\n"}),
    "secret-pattern": ((), {"scripts/deploy.sh": "KEY=AK" + "IA" + "ABCDEFGHIJKLMNOP\n"}),
    "secret-entropy": ((), {"Packages/Core/Sources/Key.swift": f'let k = "{TOKEN}"\n'}),
    "private-email": ((), {"Packages/Core/Sources/Contact.swift": "// write to " + "someone" + "@" + "private-domain.org\n"}),
    "personal-marker": ((), {"scripts/run.sh": "cd /Us" + "ers/" + "alice/work\n"}),
    "cloudflare-id": ((), {"docs/sync-server.md": "deployed at sync." + "demo" + ".work" + "ers.dev\n"}),
    "team-id": ((), {"Apps/Main/Team.swift": 'let team = "' + "5KZGD4R9" + 'K7"\n'}),
    "large-file": ((), {"Fixtures/blob.bin": b"\0" * (5 * 1024 * 1024 + 1)}),
    "symlink-escape": ((), {"Fixtures/outside": ("symlink", "/etc/hosts")}),
    "spdx-header": ((), {"Packages/Core/Sources/NoHeader.swift": "let x = 1\n"}),
}


def git(cwd, *args, check=True):
    return subprocess.run(["git", "-C", str(cwd), "-c", "commit.gpgsign=false", *args], env=GIT_ENV,
                          capture_output=True, text=True, check=check)


def write(root, files):
    for rel, content in files.items():
        path = Path(root) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, tuple) and content[0] == "symlink":
            if path.is_symlink() or path.exists():
                path.unlink()
            os.symlink(content[1], path)
        elif isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")


def make_repo(tmp, files, commits=1):
    repo = Path(tmp) / "repo"
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    for i in range(commits):
        write(repo, files if i == commits - 1 else {"history.txt": f"commit {i}\n"})
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", f"commit {i}")
    return repo


def manifest_file(tmp, include=("**",), exclude=("docs/research/**",), overlays=None, patch=None):
    manifest = json.loads(json.dumps(REAL_MANIFEST))
    manifest["include"] = list(include)
    manifest["exclude"] = list(exclude)
    manifest["overlays"] = overlays or {}
    for key, value in (patch or {}).items():
        manifest["scan"][key] = value
    path = Path(tmp) / "manifest.json"
    path.write_text(json.dumps(manifest), encoding="utf-8")
    return path


def run_export(repo, out, manifest, *extra):
    return subprocess.run([sys.executable, "-I", str(EXPORT), "--repo", str(repo), "--out", str(out),
                           "--manifest", str(manifest), *extra], env=GIT_ENV, capture_output=True, text=True)


def findings(result):
    return [line.split(" ", 1) for line in result.stdout.splitlines() if " " in line]


def finding_rules(result):
    return {rule for rule, _ in findings(result)}


class ExportMechanics(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_clean_tree_passes(self):
        repo = make_repo(self.tmp, CLEAN)
        result = run_export(repo, self.tmp / "out", manifest_file(self.tmp))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.tmp / "out" / "README.md").is_file())

    def test_untracked_secret_is_not_copied(self):
        repo = make_repo(self.tmp, CLEAN)
        write(repo, {".env": "TOKEN=" + "gh" + "p_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8\n",
                     "README.md": "# Theo Notes\nAK" + "IA" + "ABCDEFGHIJKLMNOP\n"})  # uncommitted edit of a tracked file
        result = run_export(repo, self.tmp / "out", manifest_file(self.tmp))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.tmp / "out" / ".env").exists())
        self.assertNotIn("AKIA", (self.tmp / "out" / "README.md").read_text())

    def test_research_dir_excluded(self):
        files = {**CLEAN, "docs/research/raw/faq.md": "scraped text\n", "Apps/Main/App.swift": "let x = 1\n"}
        repo = make_repo(self.tmp, files)
        manifest = manifest_file(self.tmp, include=REAL_MANIFEST["include"], exclude=REAL_MANIFEST["exclude"])
        result = run_export(repo, self.tmp / "out", manifest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.tmp / "out" / "Apps" / "Main" / "App.swift").is_file())
        self.assertFalse((self.tmp / "out" / "docs" / "research").exists())

    def test_everything_unlisted_is_left_out(self):
        files = {**CLEAN, "notes/random.txt": "x\n", "docs/decisions.md": "# decisions\n", "SESSION_LOG.md": "log\n"}
        repo = make_repo(self.tmp, files)
        manifest = manifest_file(self.tmp, include=["README.md", "project.yml"], exclude=[])
        result = run_export(repo, self.tmp / "out", manifest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        copied = sorted(p.name for p in (self.tmp / "out").rglob("*") if p.is_file())
        self.assertEqual(copied, ["README.md", "project.yml"])

    def test_exclude_beats_include_and_overlay_replaces(self):
        files = {**CLEAN, "scripts/status.py": "print(1)\n", "scripts/oss/overlays/AGENTS.md": "# public\n",
                 "AGENTS.md": "# private\n"}
        repo = make_repo(self.tmp, files)
        manifest = manifest_file(self.tmp, include=["scripts/**", "README.md", "AGENTS.md"],
                                 exclude=["scripts/status.py", "scripts/oss/overlays/**"],
                                 overlays={"AGENTS.md": "scripts/oss/overlays/AGENTS.md"})
        result = run_export(repo, self.tmp / "out", manifest)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.tmp / "out" / "scripts" / "status.py").exists())
        self.assertEqual((self.tmp / "out" / "AGENTS.md").read_text(), "# public\n")

    @unittest.skipUnless((ROOT / "scripts/oss/overlays").is_dir(), "a public tree carries the overlays as its root files")
    def test_real_manifest_maps_the_readme_overlay(self):
        overlay = REAL_MANIFEST["overlays"]["README.md"]
        self.assertEqual(overlay, "scripts/oss/overlays/README.md")
        self.assertTrue((ROOT / overlay).is_file())
        files = {**CLEAN, "README.md": "# private\n", overlay: "# public overlay\n"}
        repo = make_repo(self.tmp, files)
        manifest = manifest_file(self.tmp, include=["README.md"], exclude=[], overlays=REAL_MANIFEST["overlays"])
        result = run_export(repo, self.tmp / "out", manifest, "--disable", "all")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.tmp / "out" / "README.md").read_text(), "# public overlay\n")

    def test_single_commit_history(self):
        repo = make_repo(self.tmp, CLEAN, commits=3)
        old_sha = git(repo, "rev-parse", "HEAD~1").stdout.strip()
        git(repo, "tag", "v-private")
        out = self.tmp / "out"
        result = run_export(repo, out, manifest_file(self.tmp), "--init-git", "--author", "Public Name <public@example.com>")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(git(out, "rev-list", "--count", "HEAD").stdout.strip(), "1")
        self.assertNotEqual(git(out, "cat-file", "-e", old_sha, check=False).returncode, 0)
        self.assertEqual(git(out, "tag").stdout.strip(), "")
        self.assertEqual(git(out, "remote").stdout.strip(), "")
        self.assertEqual(git(out, "log", "-1", "--format=%an <%ae>|%cn <%ce>").stdout.strip(),
                         "Public Name <public@example.com>|Public Name <public@example.com>")

    def test_init_git_needs_an_explicit_author(self):
        repo = make_repo(self.tmp, CLEAN)
        result = run_export(repo, self.tmp / "out", manifest_file(self.tmp), "--init-git")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.tmp / "out").exists())

    def test_findings_leave_nothing_behind_and_no_repository(self):
        files = {**CLEAN, "scripts/run.sh": "cd /Us" + "ers/" + "alice\n"}
        repo = make_repo(self.tmp, files)
        out = self.tmp / "out"
        result = run_export(repo, out, manifest_file(self.tmp), "--init-git", "--author", "A <a@example.com>")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(out.exists())

    def test_keep_on_fail_keeps_the_folder(self):
        files = {**CLEAN, "scripts/run.sh": "cd /Us" + "ers/" + "alice\n"}
        repo = make_repo(self.tmp, files)
        result = run_export(repo, self.tmp / "out", manifest_file(self.tmp), "--keep-on-fail")
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.tmp / "out" / "scripts" / "run.sh").is_file())

    def test_target_inside_the_repository_is_refused(self):
        repo = make_repo(self.tmp, CLEAN)
        result = run_export(repo, repo / "public", manifest_file(self.tmp))
        self.assertEqual(result.returncode, 2)
        self.assertFalse((repo / "public").exists())

    def test_non_empty_target_is_refused(self):
        repo = make_repo(self.tmp, CLEAN)
        out = self.tmp / "out"
        out.mkdir()
        (out / "keep.txt").write_text("mine")
        result = run_export(repo, out, manifest_file(self.tmp))
        self.assertEqual(result.returncode, 2)
        self.assertEqual((out / "keep.txt").read_text(), "mine")

    def test_dry_run_reports_and_removes(self):
        repo = make_repo(self.tmp, CLEAN)
        result = subprocess.run([sys.executable, "-I", str(EXPORT), "--repo", str(repo), "--dry-run",
                                 "--manifest", str(manifest_file(self.tmp))], env=GIT_ENV, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("file(s) selected", result.stderr)

    def test_manifest_lists_exactly_the_scanner_rules(self):
        self.assertEqual(set(REAL_MANIFEST["scan"]["rules"]), set(scan.RULES))
        self.assertFalse(REAL_MANIFEST["scan"]["rules"]["spdx-header"], "switchable, off until the licence work lands")


class ScanRules(unittest.TestCase):
    """Each rule: red with the rule on, green with it off."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.counter = 0

    def run_tree(self, files, disable=(), enable=(), exclude=("docs/research/**",), patch=None):
        self.counter += 1
        sub = self.tmp / f"case{self.counter}"
        sub.mkdir()
        repo = make_repo(sub, {**CLEAN, **files})
        extra = []
        if disable:
            extra += ["--disable", ",".join(disable)]
        if enable:
            extra += ["--enable", ",".join(enable)]
        return run_export(repo, sub / "out", manifest_file(sub, exclude=exclude, patch=patch), *extra), sub / "out"

    def assert_bites(self, rule, files, others=(), enable=(), exclude=("docs/research/**",), patch=None):
        red, out = self.run_tree(files, disable=others, enable=enable, exclude=exclude, patch=patch)
        self.assertEqual(red.returncode, 1, f"{rule}: expected a failing export\n{red.stdout}{red.stderr}")
        self.assertIn(rule, finding_rules(red), f"{rule}: finding missing\n{red.stdout}")
        self.assertFalse(out.exists(), "a failing export must leave nothing behind")
        self.assertEqual(finding_rules(red) - {rule}, set(), f"{rule}: other rules fired\n{red.stdout}")
        green, out = self.run_tree(files, disable=(*others, rule), enable=[e for e in enable if e != rule],
                                   exclude=exclude, patch=patch)
        self.assertEqual(green.returncode, 0, f"{rule}: rule off must let the tree through\n{green.stdout}{green.stderr}")
        self.assertTrue(out.is_dir())

    def test_every_rule_has_a_planted_case(self):
        self.assertEqual(set(PLANTS), set(scan.RULES))

    def test_each_rule_fails_the_export_and_is_silenced_by_switching_it_off(self):
        for rule, (others, files) in PLANTS.items():
            if rule == "spdx-header":
                continue
            with self.subTest(rule=rule):
                exclude = () if rule == "forbidden-path" else ("docs/research/**",)
                patch = {"large_file_bytes": 5 * 1024 * 1024} if rule == "large-file" else None
                self.assert_bites(rule, files, others, exclude=exclude, patch=patch)

    def test_spdx_header_rule_is_switchable_and_off_by_default(self):
        files = PLANTS["spdx-header"][1]
        default, _ = self.run_tree(files)
        self.assertEqual(default.returncode, 0, default.stdout + default.stderr)
        self.assert_bites("spdx-header", files, enable=["spdx-header"])
        header = "// SPDX-License-Identifier: GPL-3.0-only\nlet x = 1\n"
        headed, _ = self.run_tree({"Packages/Core/Sources/NoHeader.swift": header, "Packages/Core/Sources/Core.swift": header},
                                  enable=["spdx-header"])
        self.assertEqual(headed.returncode, 0, headed.stdout + headed.stderr)

    def test_working_title_in_unlisted_file_fails_but_frozen_labels_pass_in_their_files(self):
        label = "baer" + "chen-envelope-v1"
        red, _ = self.run_tree({"Apps/Main/Other.swift": f'let l = "{label}"\n'})
        self.assertIn("working-title", finding_rules(red))
        green, _ = self.run_tree({"Packages/Core/Sources/Crypto/ProtocolLabels.swift": f'let l = "{label}"\n'})
        self.assertEqual(green.returncode, 0, green.stdout + green.stderr)
        mixed, _ = self.run_tree({"Packages/Core/Sources/Crypto/ProtocolLabels.swift": f'let l = "{label}"\n// {OLD}\n'})
        self.assertIn("working-title", finding_rules(mixed))
        renamed_label, _ = self.run_tree({"Packages/Core/Sources/Crypto/ProtocolLabels.swift": 'let l = "' + "baer" + 'chen-other:1"\n'})
        self.assertIn("working-title", finding_rules(renamed_label))

    def ledger(self, *entries):
        rows = [{"path": p, "match": m, "reason": "fixture", "until": u} for p, m, u in entries]
        return json.dumps({"about": "fixture", "entries": rows}, ensure_ascii=False)

    def test_working_title_passes_only_where_a_never_entry_of_the_tree_ledger_covers_it(self):
        name = OLD + ".sqlite"
        code = {"Packages/Core/Sources/Paths.swift": f'let db = "{name}"\n'}
        frozen, out = self.run_tree({**code, "scripts/name-guard.json": self.ledger(("Packages/**", name, "never"))})
        self.assertEqual(frozen.returncode, 0, frozen.stdout + frozen.stderr)
        due, _ = self.run_tree({**code, "scripts/name-guard.json": self.ledger(("Packages/**", name, "A7"))})
        self.assertIn("working-title", finding_rules(due))
        elsewhere, _ = self.run_tree({**code, "scripts/name-guard.json": self.ledger(("Apps/**", name, "never"))})
        self.assertIn("working-title", finding_rules(elsewhere))
        other_token, _ = self.run_tree({"Packages/Core/Sources/Paths.swift": f'let db = "{name}" // {OLD}\n',
                                        "scripts/name-guard.json": self.ledger(("Packages/**", name, "never"))})
        self.assertIn("working-title", finding_rules(other_token))

    def test_export_prunes_the_ledger_to_never_entries_that_cover_the_tree(self):
        name = OLD + ".sqlite"
        ledger = self.ledger(("Packages/**", name, "never"), ("docs/private/**", name, "never"),
                             ("Packages/**", OLD + "Old", "A7"))
        result, out = self.run_tree({"Packages/Core/Sources/Paths.swift": f'let db = "{name}"\n', "scripts/name-guard.json": ledger})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        kept = json.loads((out / "scripts" / "name-guard.json").read_text(encoding="utf-8"))["entries"]
        self.assertEqual([(e["path"], e["match"], e["until"]) for e in kept], [("Packages/**", name, "never")])

    def test_working_title_in_file_and_directory_names_fails(self):
        for rel in (f"Apps/{OLD}Mac/Main.swift", f"Packages/Core/{OLD}Tests.swift"):
            with self.subTest(rel=rel):
                result, _ = self.run_tree({rel: "let x = 1\n"})
                self.assertIn("working-title", finding_rules(result))
                self.assertIn(rel.split("/")[1][:5], result.stdout)

    def test_owner_name_passes_only_inside_the_public_repository_url(self):
        owner = "jankutsch" + "era"
        ok, _ = self.run_tree({"Packages/Core/Sources/Links.swift": f'let u = "https://github.com/{owner}/theonotes"\n'})
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        owners, _ = self.run_tree({".github/CODEOWNERS": f"# one maintainer\n* @{owner}\n"})
        self.assertEqual(owners.returncode, 0, owners.stdout + owners.stderr)
        for text in (f"https://github.com/{owner}/other", f"/{owner}/theonotes", f"{owner} wrote this", f"x * @{owner} here"):
            with self.subTest(text=text):
                bad, _ = self.run_tree({"Packages/Core/Sources/Links.swift": f"// {text}\n"})
                self.assertIn("personal-marker", finding_rules(bad))

    def test_absolute_user_path_fails(self):
        for text in ("/Us" + "ers/" + "jan" + "kutschera/Library", "/Us" + "ers/alice/notes"):
            with self.subTest(text=text):
                result, _ = self.run_tree({"scripts/a.sh": f"cd {text}\n"})
                self.assertIn("personal-marker", finding_rules(result))
        placeholder, _ = self.run_tree({"scripts/a.sh": "cd /Us" + "ers/Shared and /Us" + "ers/example/x\n"})
        self.assertEqual(placeholder.returncode, 0, placeholder.stdout)

    def test_token_shapes_fail(self):
        shapes = {
            "private key": "-----BEGIN " + "RSA PRIVATE " + "KEY-----",
            "aws key": "AK" + "IA" + "ABCDEFGHIJKLMNOP",
            "github token": "gh" + "p_" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8",
            "github fine grained": "github" + "_pat_" + "11ABCDEFG0abcdefghijklmnop",
            "slack token": "xo" + "xb-" + "1234567890-abcdefghij",
            "openai style key": "s" + "k-" + "abcdefghij1234567890ABCD",
            "jwt": "ey" + "Jhbgci0iJIUzI1NiJ9." + "ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0." + "abcDEF123456789xyz",
            "bearer": "Bear" + "er " + "abcdefghijklmnopqrstuvwxyz012345",
            "cloudflare token": "CLOUDFLARE_API_" + "TOKEN=abcd1234efgh5678",
        }
        for name, shape in shapes.items():
            with self.subTest(shape=name):
                # long tokens also trip the entropy rule; that rule is judged in its own test
                self.assert_bites("secret-pattern", {"scripts/deploy.sh": shape + "\n"}, others=("secret-entropy",))

    def test_findings_never_print_the_matched_text(self):
        result, _ = self.run_tree({"scripts/deploy.sh": "KEY=AK" + "IA" + "ABCDEFGHIJKLMNOP\n"})
        self.assertNotIn("ABCDEFGHIJKLMNOP", result.stdout + result.stderr)

    def test_entropy_rule_skips_lockfiles_and_alphabet_tables(self):
        self.assertGreaterEqual(scan.entropy(TOKEN), 4.5)
        lock, _ = self.run_tree({"web/editor/pnpm-lock.yaml": f"integrity: {TOKEN}\n"})
        self.assertEqual(lock.returncode, 0, lock.stdout)
        table, _ = self.run_tree({"Apps/Main/Chars.swift": 'let s = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"\n'})
        self.assertEqual(table.returncode, 0, table.stdout)

    def test_only_the_public_contact_and_example_domains_are_allowed_emails(self):
        ok, _ = self.run_tree({"Packages/Core/Sources/Contact.swift": "// hello@theonotes.app and a@example.com\n"})
        self.assertEqual(ok.returncode, 0, ok.stdout)
        bad, _ = self.run_tree({"Packages/Core/Sources/Contact.swift": "// owner" + "@" + "private-domain.org\n"})
        self.assertIn("private-email", finding_rules(bad))
        legal, _ = self.run_tree({"docs/legal/third-party.md": "author: " + "someone" + "@" + "private-domain.org\n"})
        self.assertEqual(legal.returncode, 0, "third-party licence texts under docs/legal are exempt\n" + legal.stdout)

    def test_shingle_allow_skips_only_the_listed_path(self):
        others, files = PLANTS["research-shingle"]
        listed = {"shingle_allow": [{"path": "Apps/Main/Notes.swift", "reason": "reviewed"}]}
        ok, _ = self.run_tree(files, disable=others, exclude=("docs/research/**",), patch=listed)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        other = {**files, "Apps/Main/Other.swift": files["Apps/Main/Notes.swift"]}
        bad, _ = self.run_tree(other, disable=others, exclude=("docs/research/**",), patch=listed)
        self.assertIn("research-shingle Apps/Main/Other.swift", bad.stdout)

    def test_entropy_allow_exempts_a_file_or_only_matching_text(self):
        allow = {"entropy_allow": [{"path": "Fixtures/vector.json", "reason": "vector"},
                                   {"path": "Packages/Core/Tests/*.swift", "match": r"func\s+\w+", "reason": "names"}]}
        files = {"Fixtures/vector.json": f'{{"k": "{TOKEN}"}}\n',
                 "Packages/Core/Tests/NameTests.swift": f"func {TOKEN}() {{}}\n"}
        ok, _ = self.run_tree(files, patch=allow)
        self.assertEqual(ok.returncode, 0, ok.stdout)
        more = {**files, "Packages/Core/Tests/KeyTests.swift": f'let k = "{TOKEN}"\n', "Fixtures/other.json": f'{{"k": "{TOKEN}"}}\n'}
        bad, _ = self.run_tree(more, patch=allow)
        self.assertEqual(sorted(f for f in bad.stdout.splitlines() if f.startswith("secret-entropy ")),
                         ["secret-entropy Fixtures/other.json:1", "secret-entropy Packages/Core/Tests/KeyTests.swift:1"])

    def test_bear_text_allow_is_narrow(self):
        key = "net.shiny" + "frog.bear"
        ok, _ = self.run_tree({"Packages/Core/Sources/Meta.swift": f'let k = "{key}"\n'})
        self.assertEqual(ok.returncode, 0, ok.stdout)
        # The maker's name is no longer allowed anywhere, not even in TRADEMARK.md (one neutral line names no maker).
        maker, _ = self.run_tree({"TRADEMARK.md": "Not endorsed by Shiny " + "Frog.\n"})
        self.assertIn("bear-text", finding_rules(maker))
        bad, _ = self.run_tree({"Packages/Core/Sources/Meta.swift": f'let k = "{key}" // https://bear' + '.app/faq\n',
                                "docs/legal/about.md": "Made by Shiny " + "Frog.\n"})
        self.assertEqual(len([f for f in bad.stdout.splitlines() if f.startswith("bear-text ")]), 2, bad.stdout)

    def test_cloudflare_id_shapes_fail(self):
        for text in ('database_' + 'id = "' + "0123456789abcdef" * 2 + '"', '"account_' + 'id": "' + "fedcba9876543210" * 2 + '"',
                     "0123456789abcdef" * 2 + ".r2." + "cloudflare" + "storage.com"):
            with self.subTest(text=text[:20]):
                result, _ = self.run_tree({"docs/sync-server.md": text + "\n"})
                self.assertIn("cloudflare-id", finding_rules(result))

    def test_generic_r2_host_without_account_id_is_allowed(self):
        ok, _ = self.run_tree({"Packages/Core/Sources/Host.swift": 'let h = "test.r2.' + 'cloudflare' + 'storage.com"\n'})
        self.assertEqual(ok.returncode, 0, ok.stdout)

    def test_team_id_is_allowed_in_config_env_only(self):
        ok, _ = self.run_tree({"config/identity.env": "TEAM=" + "5KZGD4R9" + "K7\n"})
        self.assertEqual(ok.returncode, 0, ok.stdout)

    def test_large_file_is_listed_and_can_be_acknowledged(self):
        files = PLANTS["large-file"][1]
        patch = {"large_file_bytes": 5 * 1024 * 1024}
        red, _ = self.run_tree(files, patch=patch)
        self.assertIn("large-file Fixtures/blob.bin", red.stdout)
        ok, _ = self.run_tree(files, patch={**patch, "large_file_ok": ["Fixtures/blob.bin"]})
        self.assertEqual(ok.returncode, 0, ok.stdout)

    def test_nine_word_overlap_with_research_fails_and_eight_words_pass(self):
        eight = " ".join(SENTENCE.split()[:8])
        short, _ = self.run_tree({"docs/research/raw/faq.md": SENTENCE + "\n", "Apps/Main/Notes.swift": f"// {eight}\n"})
        self.assertEqual(short.returncode, 0, short.stdout)
        long, _ = self.run_tree({"docs/research/raw/faq.md": SENTENCE + "\n", "Apps/Main/Notes.swift": f"// {SENTENCE}\n"})
        self.assertIn("research-shingle Apps/Main/Notes.swift", long.stdout)

    def test_forbidden_paths_cover_keys_env_and_private_notes(self):
        for rel in ("SESSION_LOG.md", "LESSONS.md", ".superpowers/legal/x.md", "docs/research/raw/a.md", "docs/status/index.html",
                    "Apps/keys.env", "Apps/.env.local", "Apps/signing.p12", "build/out.txt", "docs/reviews/r.md",
                    "docs/release/evidence/e.md", "Apps/dev.mobileprovision", "Apps/cert.pem", "Apps/id.key",
                    "docs/bear-community-audit.md", "docs/oracle/m1.md", "web/node_modules/pkg/index.js"):
            with self.subTest(rel=rel):
                result, _ = self.run_tree({rel: "x\n"}, exclude=())
                self.assertIn("forbidden-path", finding_rules(result), rel)

    def test_symlink_inside_the_tree_is_fine(self):
        result, _ = self.run_tree({"Fixtures/target.txt": "x\n", "Fixtures/link.txt": ("symlink", "target.txt")})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bite_check_empty_rule_set_lets_the_seeded_tree_through(self):
        seeded = {}
        for rule, (_, files) in PLANTS.items():
            if rule == "spdx-header":
                continue
            seeded.update(files)
        patch = {"large_file_bytes": 5 * 1024 * 1024}
        on, _ = self.run_tree(seeded, enable=["spdx-header"], exclude=(), patch=patch)
        self.assertEqual(on.returncode, 1)
        self.assertEqual(finding_rules(on), set(scan.RULES), "every rule must fire on the seeded tree")
        off, out = self.run_tree(seeded, disable=["all"], exclude=(), patch=patch)
        self.assertEqual(off.returncode, 0, "with the rules emptied the seeded tree passes, so the rules did the work\n" + off.stdout)
        self.assertTrue(out.is_dir())

    def test_scan_cli_exit_codes(self):
        tree = self.tmp / "tree"
        tree.mkdir()
        (tree / "a.txt").write_text("fine\n")
        ok = subprocess.run([sys.executable, "-I", str(SCAN), str(tree)], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0)
        (tree / "b.txt").write_text(f"{OLD}\n")
        bad = subprocess.run([sys.executable, "-I", str(SCAN), str(tree)], capture_output=True, text=True)
        self.assertEqual(bad.returncode, 1)
        self.assertEqual(bad.stdout.strip(), "working-title b.txt:1")
        unknown = subprocess.run([sys.executable, "-I", str(SCAN), str(tree), "--disable", "nope"], capture_output=True, text=True)
        self.assertEqual(unknown.returncode, 2)
        missing = subprocess.run([sys.executable, "-I", str(SCAN), str(tree / "none")], capture_output=True, text=True)
        self.assertEqual(missing.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
