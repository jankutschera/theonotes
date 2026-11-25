#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/licence-headers.py. Run: python3 -I scripts/tests/test_licence_headers.py"""

import contextlib
import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("licence_headers", ROOT / "scripts" / "licence-headers.py")
lh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lh)

SPDX = "SPDX-License-Identifier: GPL-3.0-only"
COPY = "Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors"


class Tree:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="licence-headers-test-"))

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def put(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p

    def run(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lh.main(["--root", str(self.root), *args])
        return code, out.getvalue()


class LicenceHeaderTests(unittest.TestCase):
    def setUp(self):
        self.t = Tree()
        self.addCleanup(self.t.close)

    def test_check_flags_missing_header(self):
        self.t.put("Sources/a.swift", "import Foundation\n")
        code, out = self.t.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("Sources/a.swift", out)

    def test_check_passes_with_header(self):
        self.t.put("a.ts", f"// {SPDX}\n// {COPY}\n\nexport {{}}\n")
        self.assertEqual(self.t.run("--check")[0], 0)

    def test_write_is_idempotent(self):
        p = self.t.put("a.swift", "import Foundation\n")
        self.assertEqual(self.t.run("--write")[0], 0)
        first = p.read_text()
        self.assertEqual(first, f"// {SPDX}\n// {COPY}\n\nimport Foundation\n")
        self.t.run("--write")
        self.assertEqual(p.read_text(), first)
        self.assertEqual(self.t.run("--check")[0], 0)

    def test_shebang_kept_first(self):
        p = self.t.put("run.sh", "#!/usr/bin/env bash\nset -e\n")
        self.t.run("--write")
        self.assertEqual(p.read_text(), f"#!/usr/bin/env bash\n# {SPDX}\n# {COPY}\n\nset -e\n")

    def test_swift_tools_version_kept_first(self):
        p = self.t.put("Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\n")
        self.t.run("--write")
        self.assertTrue(p.read_text().startswith("// swift-tools-version: 6.0\n// " + SPDX))

    def test_comment_styles(self):
        css = self.t.put("a.css", "body {}\n")
        py = self.t.put("a.py", "import os\n")
        self.t.run("--write")
        self.assertTrue(css.read_text().startswith(f"/* {SPDX} */\n/* {COPY} */\n\n"))
        self.assertTrue(py.read_text().startswith(f"# {SPDX}\n# {COPY}\n\n"))

    def test_excluded_paths_are_untouched(self):
        for rel in ("Fixtures/x.swift", "docs/y.py", "node_modules/z/index.js",
                    "web/editor/src/editor/features/hidden-font.ts"):
            self.t.put(rel, "x\n")
        self.assertEqual(self.t.run("--check")[0], 0)
        self.t.run("--write")
        self.assertEqual((self.t.root / "Fixtures/x.swift").read_text(), "x\n")

    def test_other_extensions_are_ignored(self):
        self.t.put("a.json", "{}\n")
        self.t.put("a.md", "# x\n")
        self.assertEqual(self.t.run("--check")[0], 0)

    def test_generated_files_covered_by_their_generator(self):
        src = (ROOT / "scripts" / "gen-automation-sources.py").read_text()
        self.assertIn(SPDX, src)
        self.assertIn(COPY, src)

    def test_repo_generated_swift_files_have_the_header(self):
        gen = ROOT / "Packages/TheoNotesCore/Sources/TheoNotesAutomation/Generated"
        for f in gen.glob("*.swift"):
            lines = f.read_text().splitlines()
            self.assertEqual(lines[:2], [f"// {SPDX}", f"// {COPY}"], f.name)


if __name__ == "__main__":
    unittest.main()
