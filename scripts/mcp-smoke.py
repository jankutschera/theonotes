#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Manual smoke test for `theonotes mcp-server` over stdio (M5 Task 17).

Run it on a COPY of a library, never the real one:

    python3 -I scripts/mcp-smoke.py --binary <path to theonotes> --data-dir /tmp/baerchen-copy

It performs the MCP handshake, lists the tools and runs a read-only tool sequence. It prints
tool names, counts and PASS/FAIL per step; it never prints note titles, text, tags or ids.
It refuses to run without --data-dir, and refuses the real library folder. Standard library only.
"""

import argparse
import json
import os
import pwd
import queue
import subprocess
import sys
import threading

REPLY_TIMEOUT = 10
EXPECTED_TOOLS = 28


def real_library_paths():
    homes = {os.path.expanduser("~"), pwd.getpwuid(os.getuid()).pw_dir}
    paths = set()
    for home in homes:
        for name in ("Theo Notes", "Baerchen"):
            paths.add(os.path.realpath(os.path.join(home, "Library", "Application Support", name)))
    return paths


def refusal(data_dir):
    """Why this data dir must not be used, or None."""
    if not data_dir:
        return "--data-dir is required: run against a copy of a library, never the real one"
    if not os.path.isabs(data_dir):
        return "--data-dir must be an absolute path"
    real = os.path.realpath(data_dir)
    for library in real_library_paths():
        if real == library or real.startswith(library + os.sep) or library.startswith(real + os.sep):
            return "refusing to run against the real Theo Notes library; copy it first"
    if not os.path.isdir(real):
        return "--data-dir is not a folder"
    return None


class Client:
    def __init__(self, binary, data_dir):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        self.process = subprocess.Popen(
            [binary, "mcp-server", "--data-dir", data_dir],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd="/",
        )
        self.lines = queue.Queue()
        self.next_id = 1
        self.stderr_bytes = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _drain_stderr(self):
        self.stderr_bytes = len(self.process.stderr.read())

    def _send(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        self.process.stdin.flush()

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        while True:
            try:
                line = self.lines.get(timeout=REPLY_TIMEOUT)
            except queue.Empty:
                raise RuntimeError("no reply within %d s" % REPLY_TIMEOUT)
            if line is None:
                raise RuntimeError("server closed stdout")
            message = json.loads(line)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError("JSON-RPC error %s" % message["error"].get("code"))
            return message["result"]

    def notify(self, method):
        self._send({"jsonrpc": "2.0", "method": method})

    def call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def close(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=REPLY_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None
        return self.process.returncode


class Report:
    def __init__(self):
        self.failed = 0

    def step(self, name, ok, detail=""):
        if not ok:
            self.failed += 1
        print("%s  %s%s" % ("PASS" if ok else "FAIL", name, (" (%s)" % detail) if detail else ""))


def structured(result):
    if result.get("isError"):
        return None
    return result.get("structuredContent")


def run(binary, data_dir):
    report = Report()
    client = Client(binary, data_dir)
    try:
        init = client.request(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "mcp-smoke", "version": "1"},
            },
        )
        report.step("initialize", init.get("serverInfo", {}).get("name") == "theonotes")
        client.notify("notifications/initialized")

        tools = client.request("tools/list", {})["tools"]
        names = [tool["name"] for tool in tools]
        report.step("tools/list", len(names) == EXPECTED_TOOLS, "%d tools" % len(names))
        print("     tools: %s" % ", ".join(names))

        listed = structured(client.call("list_notes", {"limit": 5}))
        ok = listed is not None and isinstance(listed.get("total"), int) and len(listed.get("metadata", [])) <= 5
        report.step("list_notes", ok, "total %s" % (listed or {}).get("total"))
        rows = (listed or {}).get("metadata", [])

        tags = structured(client.call("list_tags", {}))
        report.step("list_tags", tags is not None and isinstance(tags.get("tags"), list), "%d tags" % len((tags or {}).get("tags", [])))

        pins = structured(client.call("list_pins", {}))
        report.step("list_pins", pins is not None and isinstance(pins.get("pins"), list))

        found = structured(client.call("search_notes", {"query": "a", "limit": 3}))
        report.step("search_notes", found is not None and isinstance(found.get("total"), int), "total %s" % (found or {}).get("total"))

        readable = next((row for row in rows if not row.get("locked")), None)
        if readable is None:
            print("SKIP  note reads (no unlocked note among the first 5)")
        else:
            note_id = readable["id"]
            meta = structured(client.call("get_note", {"id": note_id}))
            report.step("get_note", meta is not None and "metadata" in meta)
            content = structured(client.call("read_note_content", {"id": note_id}))
            report.step(
                "read_note_content",
                content is not None and isinstance(content.get("content"), str) and isinstance(content.get("hash"), str),
                "%d characters" % len((content or {}).get("content", "")),
            )
            outline = structured(client.call("read_note_outline", {"id": note_id}))
            report.step("read_note_outline", outline is not None and isinstance(outline.get("outline"), list), "%d sections" % len((outline or {}).get("outline", [])))
            inside = structured(client.call("search_in_note", {"id": note_id, "string": "a", "limit": 3}))
            report.step("search_in_note", inside is not None and isinstance(inside.get("matches"), list))
        locked = next((row for row in rows if row.get("locked")), None)
        if locked is not None:
            refused = client.call("read_note_content", {"id": locked["id"]})
            report.step("locked note refused", refused.get("isError") is True and "note_locked" in json.dumps(refused))

        missing = client.call("get_note", {"id": "ZZZ-NO-SUCH-NOTE"})
        report.step("unknown note is a tool error", missing.get("isError") is True)
    except Exception as error:
        report.step("session", False, str(error))
    status = client.close()
    report.step("server exits when stdin closes", status == 0, "status %s" % status)
    report.step("nothing on stderr", client.stderr_bytes == 0, "%d bytes" % client.stderr_bytes)
    print("\n%s" % ("ALL PASS" if report.failed == 0 else "%d FAILED" % report.failed))
    return 0 if report.failed == 0 else 1


def self_test():
    failures = 0

    def check(name, ok):
        nonlocal failures
        print("%s  %s" % ("PASS" if ok else "FAIL", name))
        failures += 0 if ok else 1

    check("no --data-dir is refused", refusal(None) is not None)
    check("relative path is refused", refusal("relative/dir") is not None)
    for library in real_library_paths():
        check("real library is refused", refusal(library) is not None)
        check("inside the real library is refused", refusal(os.path.join(library, "Attachments")) is not None)
    check("missing folder is refused", refusal("/nonexistent-baerchen-smoke-folder") is not None)
    check("a temporary folder passes", refusal("/tmp") is None)
    return 0 if failures == 0 else 1


def main():
    parser = argparse.ArgumentParser(description="Read-only smoke test of `theonotes mcp-server` (never prints note content)")
    parser.add_argument("--binary", help="path to the theonotes executable")
    parser.add_argument("--data-dir", help="a COPY of a library (required)")
    parser.add_argument("--self-test", action="store_true", help="check the refusal rules and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    reason = refusal(args.data_dir)
    if reason:
        print("refused: %s" % reason, file=sys.stderr)
        return 2
    if not args.binary or not os.access(args.binary, os.X_OK):
        print("refused: --binary must name an executable theonotes", file=sys.stderr)
        return 2
    return run(args.binary, os.path.realpath(args.data_dir))


if __name__ == "__main__":
    sys.exit(main())
