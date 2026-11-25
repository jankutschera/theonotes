# Theo Notes: notes for contributors and coding agents

Theo Notes is a native notes app for macOS and iOS: Swift 6 (strict concurrency), SwiftUI and AppKit, a GRDB/FTS5 core package, a CodeMirror 6 editor (`web/editor`) shown in a WKWebView, and iCloud sync through CloudKit. See `docs/ARCHITECTURE.md`.

## Build and test

- `scripts/bootstrap.sh` installs JavaScript dependencies and generates the Xcode project (XcodeGen; the `.xcodeproj` is never committed).
- `scripts/build.sh` builds the editor bundle and the Mac app (Debug, dev identity).
- `scripts/test-all.sh` runs Swift tests, editor unit and browser tests, and the guards.
- A fork must change the bundle id root and the signing team in `config/identity.env` and `config/release.env`.

## Rules that are checked

- Everything in English: code, comments, docs, commit messages. Conventional commits (`feat(scope): subject`).
- Markdown source is the exact string the user typed; never normalise it through rich text.
- No user-facing text names a medical condition (`scripts/copy-guard.py`).
- Clean room: other notes apps are consulted for behaviour and interface facts only (command, flag, field and tool names, URL actions, Markdown syntax, shortcuts, exit codes). Do not copy their prose, icons, fonts, themes or sounds, and do not decompile or inspect its app or data.
- Every new dependency is pinned exactly and its licence is recorded; it must be compatible with GPL-3.0.
- `scripts/oss/scan.py` runs on every pull request and blocks private material, secrets and copied text.
