#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Export scanner (REN2-R20): fails when a tree about to be published holds anything private.

Usage: python3 -I scripts/oss/scan.py DIR [--research DIR] [--manifest FILE]
                                      [--disable r1,r2|all] [--enable r1,r2] [--gitleaks]
       python3 -I scripts/oss/scan.py --list-rules

Prints one finding per line as `rule path:line` and never the matched text (a finding must not copy
the secret into a log). Exit 0 when clean, 1 on any finding, 2 on a usage error.

Rules live in scripts/oss/manifest.json (section "scan"); each can be switched with "rules" there or
with --disable/--enable. `--disable all` empties the rule set (the tests use it to show that a seeded
tree is only caught because the rules are on). `spdx-header` is off until the licence work (L3) lands.

  forbidden-path    research, oracle, private notes, build output, key and env files
  working-title     the old product name in any file name, directory name or text, except the frozen
                    protocol labels inside the files that are allowed to hold them and the frozen names
                    a `never` entry of the tree's own scripts/name-guard.json allows (each with a reason)
  bear-text         Bear URLs, addresses and brand terms that only come from copied material
  ip-guard          an 8+ word sentence of Bear's CLI help or MCP text (scripts/ip-guard.py logic)
  research-shingle  a run of 9 words that also occurs in --research DIR (the private docs/research)
  adhd-copy         the words ADHD/ADHS in user-facing files (scripts/copy-guard.py scope + extras)
  secret-pattern    private keys, cloud and git tokens, JWTs, bearer tokens
  secret-entropy    long high-entropy tokens outside lockfiles
  private-email     e-mail addresses other than the allow-listed public contact
  personal-marker   absolute home paths, the owner's user name, the secrets folder
  cloudflare-id     account/database/zone ids, workers.dev and R2 hosts
  team-id           Apple Team ids outside config/*.env
  large-file        files over 5 MB, listed for a human decision (large_file_ok acknowledges one)
  symlink-escape    symbolic links that leave the tree
  spdx-header       first-party source files without an SPDX-License-Identifier line
"""
import argparse
import bisect
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
DEFAULT_MANIFEST = HERE / "manifest.json"
RULES = [
    "forbidden-path", "working-title", "bear-text", "ip-guard", "research-shingle", "adhd-copy",
    "secret-pattern", "secret-entropy", "private-email", "personal-marker", "cloudflare-id", "team-id",
    "large-file", "symlink-escape", "spdx-header",
]
# Assembled from parts so this file does not name the old product itself.
OLD_NAME = re.compile("(?i)b(?:ae|ä|a)" + "rchen")
FROZEN_PREFIX = "baer" + "chen-"
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
EMAIL_TLD = re.compile(r"\.[A-Za-z]{2,}$")
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".heic", ".pdf", ".woff", ".woff2",
                  ".ttf", ".otf", ".mp3", ".mp4", ".mov", ".wav", ".zip", ".gz", ".tgz", ".car", ".nib", ".mom"}
ADHD_WORD = re.compile(r"(?i)\badh[ds]\b")
TOKEN = re.compile(r"[A-Za-z0-9+/_=-]{32,}")


# ---------------------------------------------------------------- glob matching

def expand_braces(pattern):
    found = re.search(r"\{([^{}]*)\}", pattern)
    if not found:
        return [pattern]
    out = []
    for alternative in found.group(1).split(","):
        out += expand_braces(pattern[:found.start()] + alternative + pattern[found.end():])
    return out


def glob_regex(pattern):
    parts = []
    for single in expand_braces(pattern):
        i, rx = 0, ""
        while i < len(single):
            if single.startswith("**/", i):
                rx += "(?:.*/)?"
                i += 3
            elif single.startswith("**", i):
                rx += ".*"
                i += 2
            elif single[i] == "*":
                rx += "[^/]*"
                i += 1
            elif single[i] == "?":
                rx += "[^/]"
                i += 1
            else:
                rx += re.escape(single[i])
                i += 1
        parts.append(rx)
    return re.compile("^(?:" + "|".join(parts) + ")$")


class Globs:
    def __init__(self, patterns):
        self.patterns = [glob_regex(p) for p in patterns]

    def match(self, path):
        return any(p.match(path) for p in self.patterns)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- tree walk

def walk(root):
    """[(relative posix path, absolute path, is_symlink)] for every file and symlink, `.git` skipped."""
    out = []
    for base, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d != ".git" or Path(base) != root)
        rel_base = Path(base).relative_to(root)
        for d in list(dirs):
            full = Path(base) / d
            if full.is_symlink():
                dirs.remove(d)
                out.append(((rel_base / d).as_posix(), full, True))
        for name in sorted(names):
            full = Path(base) / name
            out.append(((rel_base / name).as_posix(), full, full.is_symlink()))
    return out


def read_text(path):
    """Text of a file, or None when it is binary."""
    if path.suffix.lower() in IMAGE_SUFFIXES:
        return None
    data = path.read_bytes()
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


def line_starts(text):
    starts = [0]
    for i, ch in enumerate(text):
        if ch == "\n":
            starts.append(i + 1)
    return starts


def line_of(starts, index):
    return bisect.bisect_right(starts, index)


def has_alphabet_run(token, length=8):
    """True when the token holds `length` consecutive characters in ascending code order (an alphabet table)."""
    run = 1
    for a, b in zip(token, token[1:]):
        run = run + 1 if ord(b) == ord(a) + 1 else 1
        if run >= length:
            return True
    return False


def entropy(token):
    counts = Counter(token)
    return -sum(c / len(token) * math.log2(c / len(token)) for c in counts.values())


# ---------------------------------------------------------------- the scan

class Scanner:
    def __init__(self, root, manifest, enabled, research=None):
        self.root = Path(root)
        self.cfg = manifest["scan"]
        self.enabled = enabled
        self.research = Path(research) if research else None
        self.findings = []
        cfg = self.cfg
        self.forbidden = Globs(cfg["forbidden_paths"])
        self.frozen_paths = Globs(cfg["frozen_label_paths"])
        self.frozen = re.compile("|".join(re.escape(FROZEN_PREFIX + s) for s in cfg["frozen_label_suffixes"]))
        self.bear = [re.compile(p, re.I) for p in cfg["bear_text_patterns"]]
        # Reviewed exceptions: [(path glob, compiled regex)]; each has a written "reason" in the manifest.
        # Files whose 9-word runs were reviewed as interface contracts (usage lines, option and field names), never prose.
        self.shingle_allow = Globs([e["path"] for e in cfg.get("shingle_allow", [])])
        # Reviewed test vectors and false positives: an entry without "match" exempts the whole file from
        # secret-entropy, one with "match" blanks only those matches. Every entry carries a written "reason".
        self.entropy_allow = [(Globs([e["path"]]), re.compile(e["match"]) if e.get("match") else None)
                              for e in cfg.get("entropy_allow", [])]
        self.bear_allow = [(Globs([e["path"]]), re.compile(e["match"], re.I)) for e in cfg.get("bear_text_allow", [])]
        self.adhd_extra = Globs(cfg.get("adhd_extra_paths", []))
        self.secrets = [re.compile(p) for p in cfg["secret_patterns"]]
        self.entropy_skip = Globs(cfg["entropy_skip_paths"])
        self.allowed_emails = {e.lower() for e in cfg["allowed_emails"]}
        self.allowed_domains = {d.lower() for d in cfg["allowed_email_domains"]}
        self.email_skip = Globs(cfg["email_skip_paths"])
        self.personal = [re.compile(p) for p in cfg["personal_patterns"]]
        self.cloudflare = [re.compile(p) for p in cfg["cloudflare_patterns"]]
        self.team = [re.compile(p) for p in cfg["team_id_patterns"]]
        self.team_skip = Globs(cfg["team_id_skip_paths"])
        self.large_ok = Globs(cfg["large_file_ok"])
        self.spdx_skip = Globs(cfg["spdx_skip_paths"])
        self.spdx_suffixes = set(cfg["spdx_suffixes"])
        self.guard = load_module("name_guard", SCRIPTS / "name-guard.py")
        ledger = self.root / "scripts" / "name-guard.json"
        # Only `never` entries count: a name that is still due for a rename must not travel.
        self.never = [e for e in self.guard.load_ledger(ledger) if e["until"] == "never"] if ledger.is_file() else []

    def frozen_name(self, rel, raw):
        """True when a `never` ledger entry covers this token at this path (the guard's own files spell the name)."""
        if rel in self.guard.SELF_FILES:
            return True
        token = self.guard.clean_token(raw)
        return any(e["match"] == token and e["regex"].match(rel) for e in self.never)

    def add(self, rule, path, line=0):
        if rule in self.enabled:
            self.findings.append((rule, path, line))

    def regex_lines(self, rule, path, text, starts, patterns):
        for pattern in patterns:
            for match in pattern.finditer(text):
                self.add(rule, path, line_of(starts, match.start()))

    def run(self):
        entries = walk(self.root)
        texts = {}
        for rel, full, is_link in entries:
            self.check_path(rel, full, is_link)
            if is_link:
                continue
            self.check_size(rel, full)
            text = read_text(full)
            if text is not None:
                texts[rel] = text
                self.check_text(rel, text)
        self.check_adhd()
        self.check_ip_guard(texts)
        self.check_shingles(texts)
        return sorted(set(self.findings))

    def check_path(self, rel, full, is_link):
        if self.forbidden.match(rel):
            self.add("forbidden-path", rel)
        if OLD_NAME.search(rel) and not self.frozen_label_only(rel, rel) and not all(
                self.frozen_name(rel, m.group()) for part in rel.split("/") for m in self.guard.TOKEN.finditer(part)):
            self.add("working-title", rel)
        if is_link:
            target = os.readlink(full)
            resolved = (full.parent / target).resolve() if not os.path.isabs(target) else Path(target)
            try:
                resolved.relative_to(self.root.resolve())
            except ValueError:
                self.add("symlink-escape", rel)

    def frozen_label_only(self, rel, text):
        """True when every old-name match in `text` is one of the frozen labels and the file may hold them."""
        if not self.frozen_paths.match(rel):
            return False
        return not OLD_NAME.search(self.frozen.sub("", text))

    def check_size(self, rel, full):
        if full.stat().st_size > self.cfg["large_file_bytes"] and not self.large_ok.match(rel):
            self.add("large-file", rel)

    def check_text(self, rel, text):
        starts = line_starts(text)
        # working title (text), minus frozen labels where allowed
        scrubbed = text
        if self.frozen_paths.match(rel):
            scrubbed = self.frozen.sub(lambda m: " " * len(m.group(0)), text)
        for match in self.guard.TOKEN.finditer(scrubbed):
            if not self.frozen_name(rel, match.group()):
                self.add("working-title", rel, line_of(starts, match.start()))
        bear_text = text
        for glob, allowed in self.bear_allow:
            if glob.match(rel):
                bear_text = allowed.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), bear_text)
        self.regex_lines("bear-text", rel, bear_text, starts, self.bear)
        self.regex_lines("secret-pattern", rel, text, starts, self.secrets)
        self.regex_lines("personal-marker", rel, text, starts, self.personal)
        self.regex_lines("cloudflare-id", rel, text, starts, self.cloudflare)
        if not self.team_skip.match(rel):
            self.regex_lines("team-id", rel, text, starts, self.team)
        if not self.email_skip.match(rel):
            for match in EMAIL.finditer(text):
                address, domain = match.group(0).lower(), match.group(1).lower()
                if address in self.allowed_emails or domain in self.allowed_domains:
                    continue
                if not EMAIL_TLD.search(domain) or domain.endswith((".png", ".jpg", ".patch", ".swift", ".json")):
                    continue
                self.add("private-email", rel, line_of(starts, match.start()))
        entropy_text = text
        for glob, only in self.entropy_allow:
            if glob.match(rel):
                if only is None:
                    entropy_text = ""
                else:
                    entropy_text = only.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), entropy_text)
        if not self.entropy_skip.match(rel):
            for match in TOKEN.finditer(entropy_text):
                token = match.group(0)
                if len(token) < self.cfg["entropy_min_len"] or token.count("/") > 2:
                    continue
                if not (re.search(r"[A-Za-z]", token) and re.search(r"[0-9]", token)):
                    continue
                if has_alphabet_run(token):
                    continue
                if entropy(token) >= self.cfg["entropy_min"]:
                    self.add("secret-entropy", rel, line_of(starts, match.start()))
        suffix = Path(rel).suffix
        if suffix in self.spdx_suffixes and not self.spdx_skip.match(rel):
            head = "\n".join(text.splitlines()[:6])
            if "SPDX-License-Identifier:" not in head:
                self.add("spdx-header", rel, 1)

    def check_adhd(self):
        if "adhd-copy" not in self.enabled:
            return
        guard = load_module("copy_guard", SCRIPTS / "copy-guard.py")
        try:
            for path, line, kind, word in guard.scan(self.root):
                self.add("adhd-copy", path, line)
        except guard.Undecodable:
            self.add("adhd-copy", "(unreadable user-facing file)", 0)
        for rel, full, is_link in walk(self.root):
            if is_link or not self.adhd_extra.match(rel):
                continue
            text = read_text(full)
            if text is None:
                continue
            starts = line_starts(text)
            for match in ADHD_WORD.finditer(text):
                self.add("adhd-copy", rel, line_of(starts, match.start()))

    def research_files(self):
        if not self.research or not self.research.is_dir():
            return []
        return [(rel, full) for rel, full, link in walk(self.research) if not link]

    def check_ip_guard(self, texts):
        if "ip-guard" not in self.enabled or not self.research:
            return
        guard = load_module("ip_guard", SCRIPTS / "ip-guard.py")
        reference = []
        help_dump = self.research / "bearcli-help-all.txt"
        mcp_dump = self.research / "bear-mcp-tools.json"
        if help_dump.is_file():
            reference += guard.sentences(help_dump.read_text(encoding="utf-8"))
        if mcp_dump.is_file():
            data = json.loads(mcp_dump.read_text(encoding="utf-8"))
            prose = [data.get("initialize", {}).get("result", {}).get("instructions", "")]
            guard.mcp_prose(data.get("tools", {}).get("result", {}).get("tools", []), prose)
            for text in prose:
                reference += guard.sentences(text)
        for rel, sentence in guard.find_hits(reference, sorted(texts.items())):
            self.add("ip-guard", rel, 0)

    def check_shingles(self, texts):
        if "research-shingle" not in self.enabled:
            return
        sources = self.research_files()
        if not sources:
            return
        guard = load_module("ip_guard", SCRIPTS / "ip-guard.py")
        n = self.cfg["shingle_words"]
        known = set()
        for rel, full in sources:
            text = read_text(full)
            if text is None:
                continue
            flat = [w for line in text.splitlines() for w in guard.words(line)]
            for i in range(len(flat) - n + 1):
                gram = flat[i:i + n]
                if len(set(gram)) >= 4:
                    known.add(" ".join(gram))
        if not known:
            return
        for rel, text in texts.items():
            if self.shingle_allow.match(rel):
                continue
            flat = []
            for number, line in enumerate(text.splitlines(), 1):
                flat += [(w, number) for w in guard.words(line)]
            for i in range(len(flat) - n + 1):
                if " ".join(w for w, _ in flat[i:i + n]) in known:
                    self.add("research-shingle", rel, flat[i][1])
                    break


def run_gitleaks(root):
    if not shutil.which("gitleaks"):
        print("scan: gitleaks not installed, second opinion skipped", file=sys.stderr)
        return []
    result = subprocess.run(["gitleaks", "detect", "--no-git", "--no-banner", "--source", str(root)],
                            capture_output=True, text=True)
    return [("gitleaks", "(see gitleaks output)", 0)] if result.returncode else []


def load_manifest(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def enabled_rules(manifest, disable, enable):
    on = {r for r, v in manifest["scan"]["rules"].items() if v}
    if "all" in disable:
        on = set()
    else:
        on -= set(disable)
    return on | set(enable)


def scan_tree(root, manifest, disable=(), enable=(), research=None, gitleaks=False):
    enabled = enabled_rules(manifest, set(disable), set(enable))
    findings = Scanner(root, manifest, enabled, research).run()
    if gitleaks:
        findings += run_gitleaks(root)
    return findings


def summarise(findings):
    counts = Counter(rule for rule, _, _ in findings)
    return ", ".join(f"{rule}={n}" for rule, n in counts.most_common())


def main(argv):
    parser = argparse.ArgumentParser(prog="scan.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir", nargs="?")
    parser.add_argument("--research")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--disable", default="")
    parser.add_argument("--enable", default="")
    parser.add_argument("--gitleaks", action="store_true")
    parser.add_argument("--list-rules", action="store_true")
    args = parser.parse_args(argv)
    manifest = load_manifest(args.manifest)
    if args.list_rules:
        for rule in RULES:
            print(f"{rule} {'on' if manifest['scan']['rules'].get(rule) else 'off'}")
        return 0
    if not args.dir or not Path(args.dir).is_dir():
        print("scan: DIR is required and must be a directory", file=sys.stderr)
        return 2
    split = lambda value: [x for x in value.split(",") if x]
    unknown = (set(split(args.disable)) | set(split(args.enable))) - set(RULES) - {"all"}
    if unknown:
        print(f"scan: unknown rule(s): {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    findings = scan_tree(args.dir, manifest, split(args.disable), split(args.enable), args.research, args.gitleaks)
    for rule, path, line in findings:
        print(f"{rule} {path}:{line}")
    if findings:
        print(f"scan: {len(findings)} finding(s): {summarise(findings)}", file=sys.stderr)
        return 1
    print("scan: ok", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
