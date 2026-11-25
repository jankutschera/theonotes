#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Allow-list export of the repository for publication (REN2-R20, plan task P1). Publishes nothing.

Usage: python3 -I scripts/oss/export.py --out DIR [--init-git --author "Name <mail>"] [--ref HEAD]
       python3 -I scripts/oss/export.py --dry-run

Takes the files of `--ref` (default HEAD) from git's object store, never from the working tree, so an
untracked secret cannot travel. A path is copied only when it matches `include` in
scripts/oss/manifest.json and no `exclude`; everything else is left out by default. Overlays replace
or add files from the manifest, `redact` rewrites text. The result is scanned (scripts/oss/scan.py);
on any finding the export is removed again and the exit code is 1.

DIR must not exist (or be empty) and must lie outside the repository. The private docs/research of
`--ref` is read into a temporary folder for the Bear-text checks and deleted again.

--init-git creates a fresh repository in DIR with exactly one commit by `--author` (required, never
taken from the machine's git configuration), no tags, no remote, no hooks.
--dry-run exports into a temporary folder, prints the file count and the findings, and removes it.
--keep-on-fail leaves a failing export in place for inspection (never publish it).
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("oss_scan", HERE / "scan.py")
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

DEFAULT_REPO = HERE.parent.parent
SAFE_GIT_ENV = {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0"}


class ExportError(Exception):
    pass


def git(repo, *args, input=None, env=None):
    result = subprocess.run(["git", "-C", str(repo), *args], input=input, capture_output=True,
                            env={**os.environ, **(env or {})})
    if result.returncode:
        raise ExportError(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def tracked(repo, ref):
    """[(mode, sha, path)] of every file in `ref`; submodules are refused."""
    out = git(repo, "ls-tree", "-r", "-z", "--full-tree", ref)
    entries = []
    for record in out.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, sha = meta.decode().split()
        if kind == "commit":
            raise ExportError(f"submodule at {path.decode()} cannot be exported")
        entries.append((mode, sha, path.decode("utf-8", errors="surrogateescape")))
    return entries


def blob(repo, sha):
    return git(repo, "cat-file", "blob", sha)


def check_target(out, repo):
    out = Path(out).resolve()
    repo = Path(repo).resolve()
    if out == repo or repo in out.parents or out in repo.parents:
        raise ExportError("--out must be outside the repository")
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        raise ExportError("--out must not exist or must be an empty directory")
    return out


def apply_redactions(rules, path, data):
    for rule in rules:
        if scan.glob_regex(rule["path"]).match(path):
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            data = re.sub(rule["regex"], rule["replace"], text).encode("utf-8")
    return data


def write_file(root, rel, data, mode):
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if mode == "120000":
        os.symlink(data.decode("utf-8", errors="surrogateescape"), target)
        return
    target.write_bytes(data)
    target.chmod(0o755 if mode == "100755" else 0o644)


def build_tree(repo, ref, manifest, out):
    include = scan.Globs(manifest["include"])
    exclude = scan.Globs(manifest["exclude"])
    redact = manifest.get("redact", [])
    copied = {}
    for mode, sha, path in tracked(repo, ref):
        if include.match(path) and not exclude.match(path):
            write_file(out, path, apply_redactions(redact, path, blob(repo, sha)), mode)
            copied[path] = True
    by_path = {path: (mode, sha) for mode, sha, path in tracked(repo, ref)}
    for dest, source in manifest.get("overlays", {}).items():
        if source not in by_path:
            continue  # an overlay that does not exist yet is simply not applied
        target = out / dest
        if target.is_symlink() or target.exists():
            target.unlink()
        write_file(out, dest, blob(repo, by_path[source][1]), "100644")
        copied[dest] = True
    return sorted(copied)


def prune_ledger(out):
    """Cut the exported name-guard ledger down to the `never` entries that cover a name in the exported tree.

    The private ledger also lists files that never travel and names still due for a rename; the public copy
    keeps only the frozen names it needs, so its paths and reasons describe the public tree alone."""
    ledger = out / "scripts" / "name-guard.json"
    if not ledger.is_file():
        return
    guard = scan.load_module("name_guard", out / "scripts" / "name-guard.py") if (out / "scripts" / "name-guard.py").is_file() \
        else scan.load_module("name_guard", HERE.parent / "name-guard.py")
    entries = [e for e in guard.load_ledger(ledger) if e["until"] == "never"]
    used = set()
    for path, _, token, _, _ in guard.collect_hits(out, guard.list_files(out), skip=guard.SELF_FILES):
        for e in entries:
            if e["match"] == token and e["regex"].match(path):
                used.add(id(e))
    keep = [{k: e[k] for k in ("path", "match", "reason", "until")} for e in entries if id(e) in used]
    guard.write_ledger(ledger, keep)


def research_dir(repo, ref, into):
    """Extract docs/research of `ref` into `into` for the Bear-text checks; None when it does not exist."""
    found = False
    for mode, sha, path in tracked(repo, ref):
        if path.startswith("docs/research/") and mode != "120000":
            write_file(into, path[len("docs/research/"):], blob(repo, sha), "100644")
            found = True
    return into if found else None


def init_git(out, author, message):
    name_mail = re.fullmatch(r"\s*(.+?)\s*<([^<>@\s]+@[^<>@\s]+)>\s*", author or "")
    if not name_mail:
        raise ExportError('--author must look like "Name <mail@host>"')
    name, mail = name_mail.groups()
    env = {**SAFE_GIT_ENV, "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": mail,
           "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": mail}
    git(out, "init", "-q", "-b", "main", env=env)
    git(out, "-c", "core.hooksPath=" + os.devnull, "add", "-A", env=env)
    git(out, "-c", "core.hooksPath=" + os.devnull, "-c", "commit.gpgsign=false", "commit", "-q",
        "--no-verify", "-m", message, env=env)


def clear(out, remove_self):
    if remove_self:
        shutil.rmtree(out, ignore_errors=True)
        return
    for child in out.iterdir():
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child, ignore_errors=True)
        else:
            child.unlink()


def export(repo, ref, out, manifest, disable=(), enable=(), do_init_git=False, author=None,
           message="Initial public release", keep_on_fail=False, gitleaks=False):
    """Returns (files, findings). Raises ExportError on usage problems. On findings the folder is removed."""
    out = check_target(out, repo)
    created = not out.exists()
    out.mkdir(parents=True, exist_ok=True)
    try:
        files = build_tree(repo, ref, manifest, out)
        prune_ledger(out)
        with tempfile.TemporaryDirectory(prefix="oss-research-") as tmp:
            research = research_dir(repo, ref, Path(tmp))
            findings = scan.scan_tree(out, manifest, disable, enable, research, gitleaks)
        if findings:
            if not keep_on_fail:
                clear(out, remove_self=created)
            return files, findings
        if do_init_git:
            init_git(out, author, message)
        return files, []
    except BaseException:
        if out.exists():
            clear(out, remove_self=created)
        raise


def main(argv):
    parser = argparse.ArgumentParser(prog="export.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out")
    parser.add_argument("--repo", default=str(DEFAULT_REPO))
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--manifest", default=str(HERE / "manifest.json"))
    parser.add_argument("--init-git", action="store_true")
    parser.add_argument("--author")
    parser.add_argument("--message", default="Initial public release")
    parser.add_argument("--disable", default="", help="comma list of scan rules to switch off, or all")
    parser.add_argument("--enable", default="", help="comma list of scan rules to switch on")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep-on-fail", action="store_true")
    parser.add_argument("--gitleaks", action="store_true")
    args = parser.parse_args(argv)
    if bool(args.out) == args.dry_run:
        parser.error("give exactly one of --out DIR or --dry-run")
    if args.init_git and not args.author:
        parser.error("--init-git needs --author")
    if args.dry_run and args.init_git:
        parser.error("--dry-run cannot create a repository")
    manifest = scan.load_manifest(args.manifest)
    split = lambda value: [x for x in value.split(",") if x]
    try:
        if args.dry_run:
            holder = tempfile.mkdtemp(prefix="oss-dry-run-")
            target = Path(holder) / "export"
            try:
                files, findings = export(args.repo, args.ref, target, manifest, split(args.disable), split(args.enable),
                                         gitleaks=args.gitleaks)
            finally:
                shutil.rmtree(holder, ignore_errors=True)
        else:
            files, findings = export(args.repo, args.ref, args.out, manifest, split(args.disable), split(args.enable),
                                     args.init_git, args.author, args.message, args.keep_on_fail, args.gitleaks)
    except ExportError as error:
        print(f"export: {error}", file=sys.stderr)
        return 2
    for rule, path, line in findings:
        print(f"{rule} {path}:{line}")
    print(f"export: {len(files)} file(s) selected", file=sys.stderr)
    if findings:
        print(f"export: {len(findings)} scan finding(s): {scan.summarise(findings)}", file=sys.stderr)
        print("export: nothing kept; fix the findings at the source and run again" if not args.keep_on_fail
              else "export: output kept for inspection, do not publish it", file=sys.stderr)
        return 1
    print("export: clean" + ("" if args.dry_run else f", written to {args.out}"), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
