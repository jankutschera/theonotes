#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Builds the Claude desktop extension (`.mcpb`) that the Mac app hands to Claude.

    python3 -I scripts/build-mcpb.py --out <file.mcpb> --version <x.y.z> [--dev --bundle-id <id> --app-hint <app>]

The extension holds `mcpb/manifest.json`, the app icon and the launcher
`plugins/theonotes/server/theonotes-mcp` (shared with the Claude Code plugin), which starts the
`theonotes` tool inside the installed app. `--dev` makes the "Theo Notes Dev" variant: its own
extension name, the dev bundle id and the dev app's path as the first place to look.

Signing: with MCPB_SIGN_CERT and MCPB_SIGN_KEY (PEM files; MCPB_SIGN_INTERMEDIATE, one PEM file
with the chain, is optional) the bundle is signed with that certificate; otherwise with a throwaway
self-signed one. Packing uses `@anthropic-ai/mcpb` from tools/mcpb (pinned, installed on first
use); signing uses openssl, see `sign`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools" / "mcpb"
LAUNCHER = ROOT / "plugins" / "theonotes" / "server" / "theonotes-mcp"
ICON = ROOT / "Apps" / "TheoNotesMac" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_128x128@2x.png"
TOOL_TEXT = ROOT / "Fixtures" / "mcp" / "descriptions.json"


def tool_path() -> list[str]:
    # Xcode script phases run with a minimal PATH; add the usual tool locations (as build-editor.sh).
    home = os.environ.get("HOME", "")
    extra = ["/opt/homebrew/bin", "/usr/local/bin", f"{home}/.volta/bin", f"{home}/.local/bin", f"{home}/Library/pnpm"]
    nvm = Path(home, ".nvm/versions/node")
    if nvm.is_dir():
        extra += [str(p / "bin") for p in sorted(nvm.iterdir())]
    return extra + os.environ.get("PATH", "").split(os.pathsep)


def run(*args: str, env: dict[str, str]) -> str:
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"error: {' '.join(args)} failed:\n{result.stdout}{result.stderr}")
    return result.stdout


def tools() -> list[dict[str, str]]:
    """Every MCP tool with the first sentence of its description, for Claude's install screen."""
    data = json.loads(TOOL_TEXT.read_text())
    described = {k: v for k, v in data["descriptions"].items() if "/" not in k}
    described.update({k: v["description"] for k, v in data["extensionTools"].items()})
    first = lambda text: re.split(r"(?<=\.)\s", text, maxsplit=1)[0]
    return [{"name": name, "description": first(text)} for name, text in sorted(described.items())]


def launcher(dev: bool, bundle_id: str, app_hint: str) -> str:
    text = LAUNCHER.read_text()
    if not dev:
        return text
    for key, value in (("APP_NAME", "Theo Notes Dev"), ("BUNDLE_ID", bundle_id), ("APP_HINT", app_hint)):
        text, count = re.subn(rf'^{key}=".*"$', f'{key}="{value}"', text, count=1, flags=re.M)
        if count != 1:
            sys.exit(f"error: {key}= not found in {LAUNCHER}")
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dev", action="store_true")
    parser.add_argument("--bundle-id", default="")
    parser.add_argument("--app-hint", default="")
    args = parser.parse_args()
    if args.dev and not args.bundle_id:
        sys.exit("error: --dev needs --bundle-id")
    for value in (args.bundle_id, args.app_hint):
        if '"' in value or "$" in value or "`" in value or "\\" in value:
            sys.exit(f"error: unsupported character in {value!r}")

    env = dict(os.environ, PATH=os.pathsep.join(tool_path()))
    mcpb = TOOLS / "node_modules" / ".bin" / "mcpb"
    if not mcpb.exists():
        run("pnpm", "--dir", str(TOOLS), "install", "--frozen-lockfile", env=env)

    with tempfile.TemporaryDirectory(prefix="theonotes-mcpb.") as tmp:
        stage = Path(tmp, "stage")
        (stage / "server").mkdir(parents=True)
        manifest = json.loads((ROOT / "mcpb" / "manifest.json").read_text())
        manifest["version"] = args.version
        manifest["tools"] = tools()
        if args.dev:
            manifest["name"] = "theonotes-dev"
            manifest["display_name"] = "Theo Notes Dev"
            # The tool inside any app opens the production library unless told otherwise (it has no
            # bundle id of its own), so the dev extension names the dev library.
            manifest["server"]["mcp_config"]["env"]["THEONOTES_DATA_DIR"] = "${HOME}/Library/Application Support/Theo Notes Dev"
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copyfile(ICON, stage / "icon.png")
        entry = stage / "server" / "theonotes-mcp"
        entry.write_text(launcher(args.dev, args.bundle_id, args.app_hint))
        entry.chmod(0o755)

        packed = Path(tmp, "theonotes.mcpb")
        run(str(mcpb), "pack", str(stage), str(packed), env=env)

        cert, key = os.environ.get("MCPB_SIGN_CERT"), os.environ.get("MCPB_SIGN_KEY")
        if not (cert and key):
            cert, key = str(Path(tmp, "cert.pem")), str(Path(tmp, "key.pem"))
            run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                "-subj", "/CN=Theo Notes local build", "-addext", "extendedKeyUsage=codeSigning",
                "-keyout", key, "-out", cert, env=env)
        signed = sign(packed.read_bytes(), cert, key, os.environ.get("MCPB_SIGN_INTERMEDIATE"), Path(tmp), env)

        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_bytes(signed)
    print(f"built: {args.out}")


MAGIC_EOCD = b"PK\x05\x06"


def with_comment_length(archive: bytes, length: int) -> bytes:
    """The zip with its end-of-central-directory comment length set to `length`."""
    eocd = archive.rfind(MAGIC_EOCD)
    if eocd < 0 or len(archive) - eocd != 22:
        sys.exit("error: packed bundle has no plain end-of-central-directory record")
    return archive[: eocd + 20] + length.to_bytes(2, "little")


def sign(archive: bytes, cert: str, key: str, chain: str | None, tmp: Path, env: dict[str, str]) -> bytes:
    """The bundle with the MCPB signature block (`MCPB_SIG_V1`, length, DER PKCS#7 over everything
    before it, `MCPB_SIG_END`) appended, the format `mcpb sign` writes. Unlike `mcpb sign` 2.1.2,
    the block is declared as the zip comment: Claude Desktop's strict unzip refuses trailing bytes
    otherwise (modelcontextprotocol/mcpb#278). The comment length is part of the signed bytes, so
    the signature is made again until its length is the one declared."""
    length = 0
    for _ in range(4):
        content = with_comment_length(archive, length)
        Path(tmp, "content").write_bytes(content)
        command = ["openssl", "cms", "-sign", "-binary", "-md", "sha256", "-nosmimecap", "-outform", "DER",
                   "-signer", cert, "-inkey", key, "-in", str(tmp / "content"), "-out", str(tmp / "sig.der")]
        if chain:
            command += ["-certfile", chain]
        run(*command, env=env)
        der = Path(tmp, "sig.der").read_bytes()
        block = b"MCPB_SIG_V1" + len(der).to_bytes(4, "little") + der + b"MCPB_SIG_END"
        if len(block) == length:
            return content + block
        length = len(block)
    sys.exit("error: signature length did not settle")


if __name__ == "__main__":
    main()
