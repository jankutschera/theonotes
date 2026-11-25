#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Runs a command on a pseudo terminal and types one answer when its prompt appears (for scripts/test-install-dev.sh).

    python3 -I scripts/tests/tty_run.py <answer> <prompt text> -- <command> [args...]

Prints everything the command printed; exits with the command's status. Nothing here launches an app.
"""

import os
import pty
import select
import sys

answer, prompt = sys.argv[1], sys.argv[2]
command = sys.argv[sys.argv.index("--") + 1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
seen = b""
answered = False
while True:
    ready, _, _ = select.select([fd], [], [], 30)
    if not ready:
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    seen += chunk
    if not answered and prompt.encode() in seen:
        os.write(fd, (answer + "\n").encode())
        answered = True
sys.stdout.write(seen.decode(errors="replace"))
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
