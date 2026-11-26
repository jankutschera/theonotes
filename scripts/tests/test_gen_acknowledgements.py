#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Tests for scripts/gen-acknowledgements.py. Run: python3 -I scripts/tests/test_gen_acknowledgements.py

Fixture trees are built in a temp directory; the last class checks the committed file.
"""

import contextlib
import importlib.util
import io
import json
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent.parent
spec = importlib.util.spec_from_file_location("gen_acknowledgements", ROOT / "scripts" / "gen-acknowledgements.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

MIT = """MIT License

Copyright (c) {who}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
"""

GPL = "GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n"
OFL = "Copyright 2001-2021 The Example Authors, with Reserved Font Name \"Ex\".\n\nSIL OPEN FONT LICENSE Version 1.1 - 26 February 2007\n\nPREAMBLE ...\n"
EPL = "Eclipse Public License - v 2.0\n\nTHE ACCOMPANYING PROGRAM IS PROVIDED UNDER THE TERMS...\n"
SECONDARY = (
    '\nExhibit A - Form of Secondary Licenses Notice\n\n"This Source Code may also be made available under the '
    'following Secondary Licenses when the conditions for such availability set forth in the Eclipse Public '
    'License, v. 2.0 are satisfied: %s."\n')
EPL_TEMPLATE = EPL + SECONDARY % "{name license(s), version(s), and exceptions or additional permissions here}"
EPL_GPL3 = EPL + SECONDARY % "GNU General Public License, Version 3, or any later version"
EPL_GPL2_ONLY = EPL + SECONDARY % "GNU General Public License, Version 2.0"
APACHE = "Apache License\nVersion 2.0, January 2004\n\nCopyright 2020 Example Authors\n\nLicensed under the Apache License, Version 2.0.\n"


class Fixture:
    """A tiny repository: one editor bundle with source maps, one Swift pin, one theme."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="ack-test-"))
        (self.root / "scripts").mkdir()
        self.config = {
            "themeDir": "res",
            "themeOwnLicence": "LicenseRef-Own",
            "themeLicenceFiles": {},
            "npmOverrides": {},
            "extraNpm": [],
            "assets": [],
            "bundle": {
                "ownWork": [
                    {"pattern": "Acknowledgements.json", "why": "generated"},
                    {"pattern": "Editor/index.html", "why": "ours"},
                ],
                "owners": [],
                "code": [
                    {"pattern": "Info.plist", "why": "metadata"},
                    {"pattern": "Helpers/cli", "why": "our command line tool"},
                ],
            },
        }
        (self.root / "res").mkdir()
        self.add_theme("own", {"project": "Own", "license": "LicenseRef-Own", "copyright": "x"})
        self.sources = []
        self.pins = []
        self.build = self.root / "build"
        (self.build / "assets").mkdir(parents=True)
        self.checkouts = self.root / "checkouts"
        self.checkouts.mkdir()

    def add_theme(self, name, source):
        (self.root / "res" / ("theme-%s.json" % name)).write_text(json.dumps({"id": name, "name": name, "source": source}))

    def add_package(self, name, version, license_value, licence_text, bundled=True, extra_files=None, author=None):
        directory = self.root / "web/editor/node_modules/.pnpm" / ("%s@%s" % (name.replace("/", "+"), version)) / "node_modules" / name
        directory.mkdir(parents=True)
        pkg = {"name": name, "version": version}
        if license_value is not None:
            pkg["license"] = license_value
        if author:
            pkg["author"] = author
        (directory / "package.json").write_text(json.dumps(pkg))
        if licence_text is not None:
            (directory / "LICENSE").write_text(licence_text)
        for filename, content in (extra_files or {}).items():
            (directory / filename).write_text(content)
        if bundled:
            relative = directory.relative_to(self.root)
            self.sources.append("../../" + str(relative) + "/index.js")
        return directory

    def add_pin(self, name, version, licence_text):
        self.pins.append({
            "identity": name.lower(), "kind": "remoteSourceControl",
            "location": "https://github.com/example/%s.git" % name,
            "state": {"revision": "a" * 40, "version": version},
        })
        if licence_text is not None:
            directory = self.checkouts / name
            directory.mkdir()
            (directory / "LICENSE").write_text(licence_text)

    def add_bundle(self, extra_files=None):
        """An app bundle whose Editor is a copy of the audited build (maps left out), plus our own file."""
        self.finish()
        resources = self.root / "App.app/Contents/Resources"
        for path in self.build.rglob("*"):
            if path.is_file() and not path.name.endswith(".map"):
                target = resources / "Editor" / path.relative_to(self.build)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(path.read_bytes())
        (resources / "Acknowledgements.json").write_text("{}")
        contents = resources.parent
        (contents / "MacOS").mkdir(exist_ok=True)
        (contents / "MacOS/App").write_text("binary")
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "App"}))
        for name, content in (extra_files or {}).items():
            target = resources / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
        return resources

    def finish(self):
        (self.build / "index.html").write_text("<html></html>")
        (self.build / "assets" / "a.js").write_text("export default 1;\n//# sourceMappingURL=a.js.map\n")
        (self.build / "assets" / "a.js.map").write_text(json.dumps({"version": 3, "sources": self.sources}))
        (self.root / "Packages/TheoNotesCore").mkdir(parents=True, exist_ok=True)
        (self.root / "Packages/TheoNotesCore/Package.resolved").write_text(json.dumps({"pins": self.pins, "version": 3}))
        (self.root / "scripts/acknowledgements-config.json").write_text(json.dumps(self.config))

    def run(self, *extra, bundle=True):
        self.finish()
        if bundle and "--check" in extra and "--app-bundle" not in extra:
            extra = extra + ("--app-bundle", str(self.root / "App.app"))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gen.main(["--root", str(self.root), "--editor-build", str(self.build),
                             "--swift-checkouts", str(self.checkouts)] + list(extra))
        return code, out.getvalue(), err.getvalue()

    def output(self):
        return json.loads((self.root / gen.OUTPUT_REL).read_text(encoding="utf-8"))

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture()
        self.addCleanup(self.fx.cleanup)

    def test_entries_come_from_the_bundle_swiftpm_and_themes(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 Alpha Author"))
        fx.add_package("not-in-bundle", "9.9.9", "MIT", MIT.format(who="Nobody"), bundled=False)
        fx.add_pin("Gamma", "3.1.0", MIT.format(who="2019 Gamma Author"))
        fx.add_theme("pal", {"project": "Pal", "license": "MIT", "copyright": "Copyright (c) 2021 Pal", "url": "https://example.com/pal"})
        (fx.root / "res/pal-license.txt").write_text(MIT.format(who="2021 Pal"))
        fx.config["themeLicenceFiles"] = {"Pal": "pal-license.txt"}
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        by_name = {e["name"]: e for e in fx.output()["entries"]}
        self.assertEqual(sorted(by_name), ["Gamma", "Pal colour palette", "alpha"])
        self.assertEqual(by_name["alpha"]["kind"], "npm")
        self.assertEqual(by_name["alpha"]["version"], "1.0.0")
        self.assertEqual(by_name["alpha"]["licence"], "MIT")
        self.assertEqual(by_name["alpha"]["copyright"], "Copyright (c) 2020 Alpha Author")
        self.assertEqual(by_name["Gamma"]["kind"], "swiftpm")
        self.assertEqual(by_name["Pal colour palette"]["kind"], "asset")

    def test_two_installed_versions_of_one_package_are_both_listed(self):
        fx = self.fx
        fx.add_package("dup", "1.0.9", "MIT", MIT.format(who="2018 Old"))
        fx.add_package("dup", "3.1.0", "ISC", "ISC License\n\nCopyright 2020 New\n\nPermission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.\n")
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        entries = fx.output()["entries"]
        self.assertEqual([(e["name"], e["version"], e["licence"]) for e in entries],
                         [("dup", "1.0.9", "MIT"), ("dup", "3.1.0", "ISC")])

    def test_identical_texts_are_stored_once_and_rebuild_exactly(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 Alpha Author"))
        fx.add_package("beta", "2.0.0", "MIT", MIT.format(who="2021 Beta Author"))
        fx.add_pin("Gamma", "3.1.0", MIT.format(who="2019 Gamma Author"))
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        document = fx.output()
        self.assertEqual(len(document["texts"]), 1)
        self.assertEqual(len({e["textId"] for e in document["entries"]}), 1)
        by_name = {e["name"]: e for e in document["entries"]}
        self.assertEqual(gen.expand_text(document, by_name["beta"]), gen.normalise(MIT.format(who="2021 Beta Author")))
        self.assertEqual(gen.expand_text(document, by_name["Gamma"]), gen.normalise(MIT.format(who="2019 Gamma Author")))

    def test_unknown_licence_fails_with_a_list(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "WTFPL", "DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE")
        fx.add_package("beta", "2.0.0", "Custom-Thing", "some text")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: unknown licence WTFPL", err)
        self.assertIn("beta@2.0.0: unknown licence Custom-Thing", err)
        self.assertFalse((fx.root / gen.OUTPUT_REL).exists())

    def test_denied_licence_fails_even_when_it_is_the_only_alternative(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "GPL-3.0-only", GPL)
        fx.add_package("beta", "2.0.0", "(LGPL-2.1 OR AGPL-3.0)", GPL)
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: denied licence", err)
        self.assertIn("beta@2.0.0: denied licence", err)

    def test_or_expression_elects_the_permissive_alternative(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "(GPL-3.0 OR MIT)", MIT.format(who="2020 A"))
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        entry = fx.output()["entries"][0]
        self.assertEqual(entry["licence"], "MIT")
        self.assertEqual(entry["licenceExpression"], "(GPL-3.0 OR MIT)")

    def test_missing_licence_text_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", None)
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: no licence file", err)

    def test_declared_licence_must_match_the_licence_file(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", EPL)
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: declares MIT but its licence file reads as EPL-2.0", err)

    ELK_OVERRIDE = {
        "ruling": "LIC-R98",
        "sourceUrl": "https://github.com/example/elk/tree/0.9.3",
        "sourceStatement": "Shipped without changes; True Brew Birdie Ltd. keeps an archive copy of this release.",
    }

    def test_weak_copyleft_gets_a_source_statement_and_an_immutable_link(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE)
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL3, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        entry = fx.output()["entries"][0]
        self.assertEqual(entry["licence"], "EPL-2.0")
        self.assertEqual(entry["sourceCode"], "https://github.com/example/elk/tree/0.9.3")
        self.assertIn("Shipped without changes", entry["note"])
        self.assertIn("Source code of version 0.9.3", entry["note"])
        self.assertEqual(entry["copyright"], "Copyright (c) Ulf R")

    def test_weak_copyleft_without_a_source_link_fails(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = {"ruling": "LIC-R98"}
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL3, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("elk@0.9.3: weak copyleft needs npmOverrides sourceUrl and sourceStatement", err)

    def test_weak_copyleft_source_link_must_name_the_version(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE, sourceUrl="https://github.com/example/elk")
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL3, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("elk@0.9.3: sourceUrl must point at this exact version (0.9.3)", err)

    def test_weak_copyleft_source_link_must_be_https(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE, sourceUrl="http://example.com/elk/0.9.3")
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL3, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("elk@0.9.3: sourceUrl must be an https link", err)

    def test_a_permissive_package_may_not_carry_a_source_link(self):
        fx = self.fx
        fx.config["npmOverrides"]["alpha"] = dict(self.ELK_OVERRIDE)
        fx.add_package("alpha", "0.9.3", "MIT", MIT.format(who="2020 A"))
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@0.9.3: sourceUrl and sourceStatement are for weak-copyleft packages only", err)

    def test_a_font_under_the_ofl_is_allowed_as_an_asset(self):
        fx = self.fx
        self.assertEqual(gen.classify("OFL-1.1"), "permissive")
        self.assertEqual(gen.detect_spdx(OFL), "OFL-1.1")
        (fx.root / "fonts").mkdir()
        (fx.root / "fonts/OFL.txt").write_text(OFL)
        fx.config["assets"].append({
            "name": "Example fonts", "licenceFile": "fonts/OFL.txt", "licence": "OFL-1.1", "ruling": "LIC-R34",
            "copyright": "Copyright 2001-2021 The Example Authors", "usedIn": "Maths", "note": "Reserved Font Name: Ex."})
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        entry = fx.output()["entries"][0]
        self.assertEqual(entry["licence"], "OFL-1.1")
        self.assertIn("Reserved Font Name", entry["note"])

    # ---- GPL-3.0 gate (L1, amended)

    def test_epl2_without_secondary_notice_fails(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE)
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("elk@0.9.3: EPL-2.0 without an EPL-2.0 Secondary-License notice naming the GPL", err)
        self.assertEqual(fx.run()[0], 1)  # nothing was written, so a second run fails the same way
        self.assertFalse((fx.root / gen.OUTPUT_REL).exists())

    def test_epl2_with_the_empty_exhibit_a_template_fails(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE)
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_TEMPLATE, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("Secondary-License notice", err)

    def test_epl2_whose_secondary_licence_is_gpl2_only_fails(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE)
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL2_ONLY, author="Ulf R")
        self.assertEqual(fx.run()[0], 1)

    def test_epl2_with_a_gpl3_secondary_notice_in_the_readme_passes(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = dict(self.ELK_OVERRIDE)
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL, author="Ulf R", extra_files={"README.md": EPL_GPL3})
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)

    def test_epl2_notice_alone_is_not_enough_without_a_ruling_id(self):
        fx = self.fx
        fx.config["npmOverrides"]["elk"] = {k: v for k, v in self.ELK_OVERRIDE.items() if k != "ruling"}
        fx.add_package("elk", "0.9.3", "EPL-2.0", EPL_GPL3, author="Ulf R")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("EPL-2.0 needs a ruling id", err)

    def test_apache2_allowed(self):
        fx = self.fx
        self.assertEqual(gen.gplCompatible("Apache-2.0").status, gen.ALLOWED)
        fx.add_package("chev", "11.0.0", "Apache-2.0", APACHE, author="Chev Authors")
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        self.assertEqual(fx.output()["entries"][0]["licence"], "Apache-2.0")

    def test_ofl_requires_ruling_id(self):
        fx = self.fx
        (fx.root / "fonts").mkdir()
        (fx.root / "fonts/OFL.txt").write_text(OFL)
        font = {"name": "Example fonts", "licenceFile": "fonts/OFL.txt", "licence": "OFL-1.1",
                "copyright": "Copyright 2001-2021 The Example Authors", "usedIn": "Maths"}
        for ruling in (None, "", "yes", "LIC-34", "lic-r34"):
            fx.config["assets"] = [dict(font, ruling=ruling) if ruling is not None else dict(font)]
            code, _, err = fx.run()
            self.assertEqual(code, 1, ruling)
            self.assertIn("OFL-1.1 needs a ruling id", err)
        fx.config["assets"] = [dict(font, ruling="LIC-R34")]
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)

    def test_the_gpl_table(self):
        for spdx in ("MIT", "ISC", "BSD-2-Clause", "BSD-3-Clause", "0BSD", "Zlib", "Unlicense", "CC0-1.0",
                     "BlueOak-1.0.0", "Unicode-3.0", "Apache-2.0"):
            self.assertEqual(gen.gplCompatible(spdx).status, gen.ALLOWED, spdx)
        self.assertEqual(gen.gplCompatible("OFL-1.1").needs, (gen.NEEDS_RULING,))
        self.assertEqual(gen.gplCompatible("MPL-2.0").needs, (gen.NEEDS_RULING,))
        self.assertEqual(gen.gplCompatible("EPL-2.0").needs, (gen.NEEDS_RULING, gen.NEEDS_NOTICE))
        for spdx in ("GPL-2.0-only", "GPL-3.0-only", "LGPL-2.1-only", "LGPL-3.0-or-later", "AGPL-3.0-only", "SSPL-1.0",
                     "CC-BY-SA-4.0", "CC-BY-NC-4.0", "LicenseRef-Proprietary", "", "mit"):
            verdict = gen.gplCompatible(spdx)
            self.assertEqual(verdict.status, gen.FAIL, spdx)
            self.assertTrue(verdict.reason)

    def test_an_mpl_package_needs_a_ruling_id(self):
        fx = self.fx
        fx.config["npmOverrides"]["mp"] = {"sourceUrl": "https://example.com/mp/1.0.0", "sourceStatement": "Unchanged."}
        fx.add_package("mp", "1.0.0", "MPL-2.0", "Mozilla Public License Version 2.0\n", author="M P")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("mp@1.0.0: MPL-2.0 needs a ruling id", err)
        fx.config["npmOverrides"]["mp"]["ruling"] = "LIC-R99"
        self.assertEqual(fx.run()[0], 0)

    def test_a_font_licence_file_that_is_not_the_ofl_fails(self):
        fx = self.fx
        (fx.root / "fonts").mkdir()
        (fx.root / "fonts/OFL.txt").write_text(MIT.format(who="2020 X"))
        fx.config["assets"].append({"name": "Example fonts", "licenceFile": "fonts/OFL.txt", "licence": "OFL-1.1", "copyright": "c"})
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("declared OFL-1.1 but the licence file reads as MIT", err)

    def test_a_licence_file_nobody_lists_fails(self):
        fx = self.fx
        (fx.root / "res/orphan-license.txt").write_text(MIT.format(who="2020 Orphan"))
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("orphan-license.txt is not listed", err)

    def test_theme_without_a_licence_file_mapping_fails(self):
        fx = self.fx
        fx.add_theme("pal", {"project": "Pal", "license": "MIT", "copyright": "c"})
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("theme palette Pal: no entry in themeLicenceFiles", err)

    def test_swiftpm_pin_without_a_checkout_fails(self):
        fx = self.fx
        fx.add_pin("Gamma", "3.1.0", None)
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("Gamma@3.1.0: no checkout found", err)

    def test_big_chunk_without_source_map_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        (fx.build / "assets" / "big.js").write_text("x" * (gen.MAX_UNMAPPED_CHUNK_BYTES + 1))
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("chunk without a source map: big.js", err)

    def test_check_mode_detects_a_stale_file(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_bundle()
        code, _, _ = fx.run("--check")
        self.assertEqual(code, 1, "no file yet counts as stale")
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        code, out, err = fx.run("--check")
        self.assertEqual(code, 0, err)
        self.assertIn("up to date", out)
        fx.add_package("beta", "2.0.0", "MIT", MIT.format(who="2021 B"))
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("is stale", err)
        path = fx.root / gen.OUTPUT_REL
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        path.write_text(path.read_text().replace("2021 B", "2022 B"))
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1, "an edited committed file is stale too")

    def test_declared_mit_with_a_custom_text_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", "You may use this if you are nice to the author.")
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: licence text is not recognised as MIT", err)

    CUSTOM = "You may use this if you are nice to the author."

    def test_an_unrecognised_text_passes_only_when_its_exact_hash_is_accepted(self):
        import hashlib
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", self.CUSTOM)
        right = hashlib.sha256(gen.normalise(self.CUSTOM).encode("utf-8")).hexdigest()
        fx.config["npmOverrides"] = {"alpha": {"unrecognisedText": {"sha256": right, "ruling": "LIC-R99"}}}
        code, _, err = fx.run()
        self.assertEqual(code, 0, err)
        wrong = hashlib.sha256(b"something else").hexdigest()
        fx.config["npmOverrides"] = {"alpha": {"unrecognisedText": {"sha256": wrong, "ruling": "LIC-R99"}}}
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0: licence text is not recognised as MIT", err)
        self.assertIn(right, err)

    def test_a_bare_ruling_string_or_a_missing_ruling_id_is_not_an_exception(self):
        import hashlib
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", self.CUSTOM)
        right = hashlib.sha256(gen.normalise(self.CUSTOM).encode("utf-8")).hexdigest()
        for exception in ("LIC-R99", {"sha256": right}, {"sha256": right, "ruling": ""}):
            fx.config["npmOverrides"] = {"alpha": {"unrecognisedText": exception}}
            code, _, err = fx.run()
            self.assertEqual(code, 1, exception)
            self.assertIn("not recognised as MIT", err)

    def test_declared_licence_must_be_the_one_the_text_reads_as_not_just_any_known_one(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "(MIT OR ISC)", EPL)
        code, _, err = fx.run()
        self.assertEqual(code, 1)
        self.assertIn("alpha@1.0.0", err)

    # ---- the built app bundle (fail-closed coverage)

    def test_check_without_a_built_app_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("no built app", err)

    def test_a_bundle_whose_files_are_all_accounted_for_passes(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_bundle()
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 0, err)

    def test_shipped_files_nobody_accounts_for_fail_with_a_list(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        resources = fx.add_bundle({"Editor/assets/katex.woff2": "font", "Extra/data.bin": "x", "Core.bundle/Contents/Resources/words.txt": "w"})
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        for name in ("Editor/assets/katex.woff2", "Extra/data.bin", "Core.bundle/Contents/Resources/words.txt"):
            self.assertIn(name, err)
        self.assertTrue((resources / "Extra/data.bin").exists())

    def test_codesign_metadata_of_a_nested_bundle_is_not_shipped_content(self):
        # An ad hoc signed dev build signs the SwiftPM resource bundles: their
        # `_CodeSignature` files come from codesign, not from any package or asset.
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_bundle({"Core.bundle/Contents/_CodeSignature/CodeResources": "sig", "Core.bundle/Contents/_CodeSignature/CodeDirectory": "sig"})
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 0, err)

    def test_a_config_pattern_accounts_for_a_file_and_an_owner_must_exist(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_bundle({"Core.bundle/Contents/Resources/words.txt": "w", "Core.bundle/Contents/Resources/own.txt": "o"})
        fx.config["bundle"]["owners"] = [{"pattern": "*/words.txt", "owner": "alpha"}]
        fx.config["bundle"]["ownWork"].append({"pattern": "*/own.txt", "why": "ours"})
        self.assertEqual(fx.run()[0], 0)
        self.assertEqual(fx.run("--check")[0], 0)
        fx.config["bundle"]["owners"] = [{"pattern": "*/words.txt", "owner": "nobody"}]
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("owner nobody is not in the list", err)

    def test_a_shipped_editor_file_that_differs_from_the_audited_build_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        resources = fx.add_bundle()
        (resources / "Editor/assets/a.js").write_text("export default 2;\n")
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("Editor/assets/a.js differs from the audited build", err)

    def test_an_editor_script_the_audited_build_did_not_produce_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_bundle({"Editor/assets/extra.js": "console.log(1)"})
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("Editor/assets/extra.js", err)

    def test_theme_files_are_accounted_by_their_declared_source(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        fx.add_theme("pal", {"project": "Pal", "license": "MIT", "copyright": "c"})
        (fx.root / "res/pal-license.txt").write_text(MIT.format(who="2021 Pal"))
        fx.config["themeLicenceFiles"] = {"Pal": "pal-license.txt"}
        own = json.dumps({"source": {"project": "Own", "license": "LicenseRef-Own"}})
        pal = json.dumps({"source": {"project": "Pal", "license": "MIT"}})
        stranger = json.dumps({"source": {"project": "Stranger", "license": "MIT"}})
        fx.add_bundle({"C.bundle/Contents/Resources/theme-own.json": own, "C.bundle/Contents/Resources/theme-pal.json": pal,
                       "C.bundle/Contents/Resources/pal-license.txt": "text"})
        self.assertEqual(fx.run()[0], 0)
        self.assertEqual(fx.run("--check")[0], 0)
        (fx.root / "App.app/Contents/Resources/C.bundle/Contents/Resources/theme-new.json").write_text(stranger)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("theme-new.json", err)

    def test_the_main_executable_and_listed_code_files_pass(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        resources = fx.add_bundle()
        (resources.parent / "Helpers").mkdir()
        (resources.parent / "Helpers/cli").write_text("tool")
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 0, err)

    def test_a_stray_framework_helper_plugin_or_executable_fails_with_a_list(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        resources = fx.add_bundle()
        contents = resources.parent
        for rel in ("Frameworks/Sparkle.framework/Versions/B/Sparkle", "Helpers/updater", "PlugIns/Share.appex/Contents/MacOS/Share", "MacOS/other"):
            (contents / rel).parent.mkdir(parents=True, exist_ok=True)
            (contents / rel).write_text("x")
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        for rel in ("Frameworks/Sparkle.framework/Versions/B/Sparkle", "Helpers/updater", "PlugIns/Share.appex/Contents/MacOS/Share", "MacOS/other"):
            self.assertIn(rel, err)
        self.assertNotIn("Helpers/cli", err)
        self.assertNotIn("MacOS/App", err)

    def test_a_bundle_without_a_main_executable_name_fails(self):
        fx = self.fx
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        resources = fx.add_bundle()
        (resources.parent / "Info.plist").write_bytes(plistlib.dumps({}))
        self.assertEqual(fx.run()[0], 0)
        code, _, err = fx.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("MacOS/App", err)

    def test_output_is_deterministic(self):
        fx = self.fx
        fx.add_package("beta", "2.0.0", "MIT", MIT.format(who="2021 B"))
        fx.add_package("alpha", "1.0.0", "MIT", MIT.format(who="2020 A"))
        self.assertEqual(fx.run()[0], 0)
        first = (fx.root / gen.OUTPUT_REL).read_text()
        self.assertEqual(fx.run()[0], 0)
        self.assertEqual(first, (fx.root / gen.OUTPUT_REL).read_text())
        self.assertEqual([e["name"] for e in json.loads(first)["entries"]], ["alpha", "beta"])


class CommittedFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads((ROOT / gen.OUTPUT_REL).read_text(encoding="utf-8"))
        cls.by_name = {e["name"]: e for e in cls.document["entries"]}

    def test_names_the_libraries_the_app_relies_on(self):
        self.assertEqual(self.by_name["GRDB.swift"]["licence"], "MIT")
        self.assertEqual(self.by_name["GRDB.swift"]["kind"], "swiftpm")
        self.assertEqual(self.by_name["@codemirror/view"]["licence"], "MIT")

    def test_elkjs_is_not_listed(self):
        # Elkjs (EPL-2.0 without a GPL secondary licence) is not in the editor bundle.
        self.assertNotIn("elkjs", self.by_name)
        self.assertNotIn("EPL-2.0", [e["licence"] for e in self.document["entries"]])

    def test_every_entry_has_a_licence_text_and_a_copyright_line(self):
        for entry in self.document["entries"]:
            with self.subTest(entry=entry["name"]):
                self.assertTrue(entry["copyright"].strip())
                text = gen.expand_text(self.document, entry)
                self.assertGreater(len(text), 200)
                self.assertNotIn(gen.PLACEHOLDER, text)
                if "noticeId" in entry:
                    self.assertIn(entry["noticeId"], self.document["texts"])

    def test_nothing_unknown_or_denied_is_listed(self):
        for entry in self.document["entries"]:
            with self.subTest(entry=entry["name"]):
                for token in entry["licence"].split(" AND "):
                    self.assertIn(gen.classify(token), ("permissive", "weak"), token)

    def test_the_maths_font_is_stix_two_under_the_ofl_with_its_notices(self):
        names = list(self.by_name)
        self.assertEqual([n for n in names if "newcm" in n.lower()], [])
        self.assertEqual(self.by_name["@mathjax/mathjax-stix2-font"]["licence"], "Apache-2.0")
        stix = self.by_name["STIX Two fonts (glyph data in @mathjax/mathjax-stix2-font)"]
        self.assertEqual(stix["licence"], "OFL-1.1")
        self.assertIn("Copyright 2001-2021 The STIX Fonts Project Authors", stix["copyright"])
        self.assertIn('Reserved Font Name "TM Math"', stix["copyright"])
        text = gen.expand_text(self.document, stix)
        self.assertIn("SIL OPEN FONT LICENSE Version 1.1", text)
        self.assertIn("Reserved Font Name", text)
        source_sans = next(e for n, e in self.by_name.items() if n.startswith("Source Sans Pro"))
        self.assertIn("Adobe", source_sans["copyright"])
        self.assertIn("Reserved Font Name 'Source'", source_sans["copyright"])

    def test_no_weak_copyleft_is_listed(self):
        # A new EPL/MPL component needs a ruling first (docs/legal/licence-compatibility.md).
        weak = sorted(e["name"] for e in self.document["entries"] if gen.classify(e["licence"]) == "weak")
        self.assertEqual(weak, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
