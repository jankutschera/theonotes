# Theo Notes for iPhone and iPad

Universal SwiftUI/UIKit app, iOS/iPadOS 26+. Shares TheoNotesCore and the bundled CodeMirror editor with the Mac app.

## Build and run

From the repository root:

```sh
pnpm --dir web/editor install --frozen-lockfile
scripts/build-ios.sh
open TheoNotes.xcodeproj
```

Choose the **TheoNotesIOS** scheme and an iPhone or iPad simulator in Xcode, then Run. The generated project is not committed.

For a connected device, select it in Xcode and configure an available development team under Signing & Capabilities. The command-line helper deliberately disables signing for simulator/build verification; it does not install onto a physical device. TestFlight and APNs are not configured.

```sh
xcodebuild -project TheoNotes.xcodeproj -scheme TheoNotesIOS \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

The UI tests use a separate `TheoNotesUITests` directory. Only Debug builds accept `--ui-testing` and `--reset-library`; the latter applies only to that test directory.

## Current scope

Implemented: adaptive sidebar/list/editor, note capture, nested tags and counts, search operators, touch formatting, shared Markdown editor, journaled autosave/recovery, foreground/background flushing, pin/archive/trash/restore, file insertion/previews, links/completions, Markdown sharing and in-note find. Archive/Trash/read-only/locked notes reject edits.

Sync availability depends on the build and account configuration. Simulator tests do not establish physical-device acceptance; see `docs/ios-acceptance.md` and `docs/release/device-acceptance.md` for the remaining device checks.
