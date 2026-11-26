#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""End-to-end check of the Claude desktop extension and the Claude Code plugin.

    python3 -I scripts/tests/test_mcpb.py

Builds the dev extension with scripts/build-mcpb.py against a fake app whose `theonotes` prints
its arguments, then checks: the manifest passes `mcpb validate`; the bundle is a zip a strict
reader accepts (the signature block is declared as the zip comment); the PKCS#7 signature verifies
over the bytes before it; the launcher inside starts the app's tool with the right scope flags and
fails clearly without the app. `claude plugin validate` runs on the plugin and the marketplace when
the `claude` command is installed (it is not a dependency of this repository).

`mcpb verify` is not run as a pass/fail gate: @anthropic-ai/mcpb 2.1.2 reports every bundle as
unsigned because node-forge cannot verify PKCS#7 (modelcontextprotocol/mcpb#260, #277). The
openssl check below is the signature check until a fixed release is out.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
MCPB = ROOT / "tools" / "mcpb" / "node_modules" / ".bin" / "mcpb"
FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    print(("ok   " if condition else "FAIL ") + what)
    if not condition:
        FAILURES.append(what)


def run(*args: str, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, **kw)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="theonotes-mcpb-test.") as tmp:
        tmp = Path(tmp)
        app = tmp / "Fake Theo.app"
        helpers = app / "Contents" / "Helpers"
        helpers.mkdir(parents=True)
        (helpers / "theonotes").write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nprintf "DATA=%s\\n" "${THEONOTES_DATA_DIR:-}"\n')
        (helpers / "theonotes").chmod(0o755)

        bundle = tmp / "out" / "TheoNotes.mcpb"
        built = run(sys.executable, "-I", str(ROOT / "scripts" / "build-mcpb.py"), "--out", str(bundle),
                    "--version", "9.8.7", "--dev", "--bundle-id", "invalid.theonotes.test", "--app-hint", str(app))
        check(built.returncode == 0, "build-mcpb.py builds the dev extension" + ("" if built.returncode == 0 else built.stderr + built.stdout))
        if built.returncode != 0:
            return

        # Strict zip: the bytes after the end-of-central-directory record are exactly its comment.
        data = bundle.read_bytes()
        eocd = data.rfind(b"PK\x05\x06")
        declared = int.from_bytes(data[eocd + 20: eocd + 22], "little")
        check(len(data) - (eocd + 22) == declared and declared > 0, "signature block is declared as the zip comment")
        with zipfile.ZipFile(bundle) as archive:
            names = sorted(archive.namelist())
            check(names == ["icon.png", "manifest.json", "server/theonotes-mcp"], f"bundle holds exactly its three files: {names}")
            mode = archive.getinfo("server/theonotes-mcp").external_attr >> 16
            check(mode & 0o111 != 0, "launcher keeps its executable bit")
            manifest = json.loads(archive.read("manifest.json"))
            archive.extractall(tmp / "x")
        check(manifest["name"] == "theonotes-dev" and manifest["version"] == "9.8.7", "dev name and app version")
        check(set(manifest["user_config"]) == {"only_tags", "exclude_tags"}, "tag scopes are user_config")
        check(len(manifest.get("tools", [])) > 10, "tools are listed for the install screen")
        check(manifest["server"]["mcp_config"]["env"].get("THEONOTES_DATA_DIR", "").endswith("/Theo Notes Dev"),
              "dev extension names the dev library")

        validated = run(str(MCPB), "validate", str(tmp / "x" / "manifest.json"))
        check(validated.returncode == 0, "mcpb validate passes" + ("" if validated.returncode == 0 else validated.stdout + validated.stderr))

        # Signature: MCPB_SIG_V1, 4-byte little-endian length, DER PKCS#7 over everything before, MCPB_SIG_END.
        start = data.rfind(b"MCPB_SIG_V1")
        length = int.from_bytes(data[start + 11: start + 15], "little")
        (tmp / "sig.der").write_bytes(data[start + 15: start + 15 + length])
        (tmp / "content").write_bytes(data[:start])
        check(data.endswith(b"MCPB_SIG_END") and start + 15 + length + 12 == len(data), "signature block is well formed")
        verified = run("openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", str(tmp / "sig.der"),
                       "-content", str(tmp / "content"), "-noverify", "-out", os.devnull)
        check(verified.returncode == 0, "PKCS#7 signature verifies over the bundle" + ("" if verified.returncode == 0 else verified.stderr))
        info = run(str(MCPB), "info", str(bundle))
        check(info.returncode == 0, "mcpb info reads the signed bundle")

        launcher = tmp / "x" / "server" / "theonotes-mcp"
        launcher.chmod(0o755)  # zipfile does not restore modes; the bit itself is checked above

        def launch(**env: str) -> subprocess.CompletedProcess:
            base = {"PATH": "/usr/bin:/bin", "HOME": str(tmp / "home")}
            return run(str(launcher), env={**base, **env})

        out = launch()
        check(out.stdout.splitlines() == ["mcp-server", "DATA="], f"no scope: plain mcp-server ({out.stdout!r} {out.stderr!r})")
        out = launch(THEONOTES_CONNECT_ONLY_TAGS="work, home/kids", THEONOTES_CONNECT_EXCLUDE_TAGS="private")
        check(out.stdout.splitlines()[:5] == ["mcp-server", "--only-tags", "work, home/kids", "--exclude-tags", "private"],
              "scope values become flags")
        out = launch(THEONOTES_CONNECT_ONLY_TAGS="${user_config.only_tags}", THEONOTES_CONNECT_EXCLUDE_TAGS="  ")
        check(out.stdout.splitlines()[0:1] == ["mcp-server"] and "--only-tags" not in out.stdout and "--exclude-tags" not in out.stdout,
              "an unexpanded placeholder or blanks mean no limit")
        out = launch(THEONOTES_CONNECT_ONLY_TAGS=",")
        check("--only-tags\n,\n" in out.stdout, "a value naming no tag still reaches the server, which refuses it")

        shutil.rmtree(app)
        out = launch()
        check(out.returncode == 69 and "is not installed" in out.stderr, "without the app: exit 69 and a clear message")

        # The production launcher is the plugin's file, unchanged except for the dev lines.
        plugin_launcher = (ROOT / "plugins" / "theonotes" / "server" / "theonotes-mcp").read_text()
        identity = (ROOT / "config" / "identity.env").read_text()
        root = next(line.split("=", 1)[1].strip() for line in identity.splitlines() if line.startswith("THEONOTES_BUNDLE_ROOT="))
        check(f'BUNDLE_ID="{root}"' in plugin_launcher and 'APP_HINT=""' in plugin_launcher,
              "plugin launcher looks for the production app (config/identity.env)")

    claude = shutil.which("claude")
    if claude:
        for target in (ROOT / "plugins" / "theonotes", ROOT):
            result = run(claude, "plugin", "validate", str(target))
            check(result.returncode == 0 and "Validation passed" in result.stdout,
                  f"claude plugin validate {target.relative_to(ROOT) or '.'}" + ("" if result.returncode == 0 else result.stdout + result.stderr))
    else:
        print("skip claude plugin validate: the claude command is not installed")


if __name__ == "__main__":
    main()
    if FAILURES:
        sys.exit(f"{len(FAILURES)} check(s) failed")
    print("all checks passed")
