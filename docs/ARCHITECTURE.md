# Architecture

Theo Notes is a set of native Apple apps around one Swift package and one web editor.

```
Apps/TheoNotesMac ─┐                        ┌─ web/editor (TypeScript, CodeMirror 6)
Apps/TheoNotesIOS ─┼─ Packages/TheoNotesCore ┤   bundled into the apps, shown in a WKWebView,
Apps/TheoNotesWatch┘   (Swift 6, GRDB/FTS5)   └─ talks to Swift over a JSON message bridge
                         └─ theonotes (command line tool and MCP server)
```

## Packages/TheoNotesCore

A Swift package with four products.

| Target | What lives there |
|---|---|
| `TheoNotesCore` | The library: SQLite through GRDB with FTS5 search (`Store`, `Search`), the Markdown dialect indexer (`Parse`, `Tags`, `Links`), attachments and OCR (`OCR`), locked notes and their encryption (`Crypto`), import and export (`Import`, `Export`), backups (`Store/LibraryBackup*`), iCloud sync through CloudKit (`CloudSync`), the editor bridge protocol (`Bridge`), themes (`Appearance`) and the starter notes (`GettingStarted`, `Resources`). |
| `TheoNotesAutomation` | Everything a program can ask of the library: the command table and argument parser of the CLI, the MCP server, x-callback-url actions, and the socket the CLI uses to reach a running app. Help text and tool schemas are generated from `Fixtures/cli` and `Fixtures/mcp` by `scripts/gen-automation-sources.py`. |
| `theonotes` | The command line executable. `theonotes mcp-server` runs the MCP server over stdio. |
| `TheoNotesVoice` | Voice capture and transcription for quick notes. |

`bear-oracle` is a developer tool that checks import and command-line compatibility against a locally installed copy of an app Theo Notes imports from, using that app's read-only command line tool; it is never shipped.

The library folder holds one SQLite database plus attachment files. A note's text is stored exactly as typed; everything else (titles, tags, links, search index) is derived from it and can be rebuilt.

## web/editor

The editor is CodeMirror 6 with our own Markdown dialect (`src/editor/dialect*.ts`, features in `src/editor/features/`), MathJax for math and Mermaid for diagrams. It is built with Vite into a single bundle that the apps load from their resources. `src/bridge/` is the message protocol with the native side; both sides are checked against the same fixtures in `Fixtures/bridge` and `Fixtures/dialect`.

## Apps

| Folder | Product |
|---|---|
| `Apps/TheoNotesMac` | The Mac app (SwiftUI and AppKit): windows, sidebar, note list, editor host, menus, settings, import and export panels, About and Acknowledgements. |
| `Apps/TheoNotesMacShare` | Mac share extension. |
| `Apps/TheoNotesIOS`, `TheoNotesIOSShare`, `TheoNotesIOSWidgets` | iPhone and iPad app, share extension and widgets. |
| `Apps/TheoNotesWatch`, `TheoNotesWatchShared`, `TheoNotesWatchWidgets` | Apple Watch app for quick dictated notes, with its complications. |
| `Apps/TheoNotesCLI` | Signing entitlements of the bundled `theonotes` tool. |

The Xcode project is generated from `project.yml` by XcodeGen. Two build identities exist: `Debug` is the development identity ("Theo Notes Dev", own bundle ids, own library folder), `Production` and `Release` are the shipped identity. Bundle ids, team and the iCloud container come from `config/*.env`.

## Sync

The shipped sync is iCloud: each library syncs through the user's private CloudKit database, with note contents encrypted on the device before upload. The apps also contain an older client for a private sync server; that server is not part of this repository, and a build without `config/private-sync.xcconfig` never offers it.

## Names you will meet

The app was developed under a working title, and some stored names keep it on purpose: the database file, theme ids, the old backup file type, a legacy URL scheme, App Intents identifiers, the executable name of releases up to 1.1 (still recognised by the scripts) and twelve byte strings in encrypted data (`docs/crypto-labels.md`). Renaming them would break existing libraries, backups, links or Shortcuts. `scripts/name-guard.py` lists every allowed place with its reason in `scripts/name-guard.json`; anything a person sees says Theo Notes.

Rule ids in comments (such as `` or ``) point to the project's decision log, which is not published.

## Tests and guards

`scripts/test-all.sh` runs the Swift tests, the editor's vitest and Playwright tests, the Python tests under `scripts/tests`, and these guards: `name-guard.py` (old name only where allowed), `copy-guard.py` (user-facing wording), `ip-guard.py` (no copied third-party prose), `licence-headers.py` (SPDX headers) and `gen-acknowledgements.py --check` (every bundled third-party file is listed with its licence). `scripts/oss/scan.py` checks a tree for private material before it is published.
