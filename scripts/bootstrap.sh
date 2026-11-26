#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pnpm --dir web/editor install --frozen-lockfile
pnpm --dir tools/mcpb install --frozen-lockfile
pnpm --dir web/editor exec playwright install webkit
xcodegen generate
