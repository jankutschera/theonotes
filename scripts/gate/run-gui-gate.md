# M0 GUI gate checklist

The GUI-only items of the M0 editor acceptance gate (plan Task 8, items 1–8, plus Task 7 Step 2).
The headless items already run in `xcodebuild test` (`Apps/TheoNotesMac/Tests/EditorIntegrationTests.swift`).
Record results in `docs/m0-acceptance.md` (PASS / FAIL / NOT VERIFIED + evidence).

All commands run from the repo root. `DB` below means:

```sh
DB="$HOME/Library/Application Support/Baerchen/Baerchen.sqlite"
q() { sqlite3 "$DB" "select id, revision, quote(text) from note where location='notes' order by modifiedAt desc limit 5"; }
```

## 0. Preconditions (about 5 min, once)

1. The screen must be **unlocked** with a logged-in console session. Check:
   `ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked` must print `<false/>` (or nothing).
2. System Settings > Privacy & Security: give the terminal or agent host **Accessibility** and
   **Screen Recording** (needed for `screencapture`, CGEvents, `scripts/gate/ax-dump.swift`, kimi-cu).
3. System Settings > Keyboard > Input Sources: add **Japanese – Romaji** and **Chinese, Simplified – Pinyin**.
   `swift scripts/gate/input-source.swift list` must then show
   `com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese` and `com.apple.inputmethod.SCIM.ITABC`.
4. Clean slate and build:
   ```sh
   mv "$HOME/Library/Application Support/Theo Notes Dev" "$HOME/Library/Application Support/Theo Notes Dev.gate-$(date +%s)"
   scripts/build.sh
   open "build/DerivedData/Build/Products/Debug/Theo Notes Dev.app" --args -ApplePersistenceIgnoreState YES
   pgrep -x "Theo Notes Dev"   # note the pid
   ```
5. Screenshots: `screencapture -x docs/m0/<name>.png` (whole screen; bring Theo Notes to the front first).
   A black image means Screen Recording permission is missing.

## Task 7 Step 2: shell persistence

1. ⌘N, type `# Hello`, Return, `This is **bold**`.
2. ⌘N again, type `second note`. Click the first note in the list, then the second.
3. ⌘Q. Check `pgrep -x "Theo Notes Dev"` prints nothing.
4. `q` shows both notes with the exact text (`'# Hello' || char(10) || 'This is **bold**'`).
5. Relaunch (step 0.4 `open …`). The new pid must differ. Both notes are listed and the text is shown.
6. Screenshot → `docs/m0/shell.png`.

## Item 1: hiding and caret movement

1. In a note, type `**bold** and # heading` on line 1 and `[link](https://example.com)` on line 2.
2. With the caret on another line: `**`, `#` and `(https://example.com)` are hidden. Screenshot → `docs/m0/hiding.png`.
3. Put the caret at the end of `bold`, then press ← and → repeatedly. The caret must never stop
   inside a hidden `**`, and one keypress must cross a hidden range.
4. Click in the middle of the word `bold` and in the link text. The caret must land where you clicked.
5. PASS if 2–4 hold. Note any caret jump.

## Item 2: IME composition after `**bold**`

1. Type `**bold** ` and put the caret right after it.
2. `swift scripts/gate/input-source.swift select com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese`
3. Type `nihongo` (the layout is QWERTZ: send key codes for n-i-h-o-n-g-o, or type them by hand). Press Space to convert and Return to commit.
4. `q`: the text must be `**bold** 日本語` (or the chosen candidate). The `**` must be intact and there must be no
   doubled or missing kana. While composing, the marked text must be underlined and must not be hidden.
5. Repeat with `com.apple.inputmethod.SCIM.ITABC` and `zhongwen` + Space → `中文`.
6. `swift scripts/gate/input-source.swift select com.apple.keylayout.ABC-QWERTZ` to restore.

## Item 3: spellcheck

1. Type `teh ` and wait 2 s. It needs a red underline. Screenshot → `docs/m0/spellcheck.png`.
2. Right-click `teh` and choose `the`. `q` must show `the`.

## Item 4: Writing Tools

1. Select a sentence, right-click, and look for **Writing Tools** in the menu. Screenshot → `docs/m0/writing-tools.png`.
2. Choose Proofread or Rewrite and apply. `q` must show the rewritten text.
3. If Apple Intelligence is off or unavailable, record NOT VERIFIED with the reason.

## Item 5: accessibility

1. `swift scripts/gate/ax-dump.swift "$(pgrep -x "Theo Notes Dev")"`: the output must contain an AXWebArea / AXTextArea
   (or AXStaticText values) with the note text. `AXIsProcessTrusted: false` means step 0.2 is missing.
2. Optional: turn VoiceOver on (⌘F5) and check that it reads the line under the caret.

## Item 6: undo/redo (keyboard) after typing and after an external write

1. Type `one two` in a note, wait 1 s, then press ⌘Z and ⇧⌘Z. The text must disappear and come back.
2. External write while the note is open (use the id from `q`):
   ```sh
   sqlite3 "$DB" "update note set text = text || char(10) || 'external', revision = revision + 1 where id = '<id>'"
   notifyutil -p com.truebrewbirdie.baerchen.db-changed
   ```
   `external` must appear in the editor without a reload flash.
3. ⌘Z must remove `external` (spec §3.3: an external edit is its own undo step). ⌘Z again must undo the typing,
   and ⇧⌘Z twice must restore both. After each step, `q` must match the screen (wait 1 s).
4. Check the Edit menu's Undo and Redo items too (not only the keyboard shortcuts).

## Item 7: WebContent kill while typing

1. Type a line and wait about 1 s (for the acks).
2. `scripts/gate/kill-webcontent.sh` prints the killed pid and "(gone)".
3. The editor must come back within about 1 s with identical text. `scripts/gate/kill-webcontent.sh --dry-run` must show a **new** pid.
4. Type one more character. `q` must show the full text, including that character.

## Item 8: dictation (manual, Jan)

1. Press the dictation shortcut (🎤 or Fn Fn) in a note and dictate "hello from dictation".
2. The text must appear, and `q` must show it within 1 s.

## Cleanup

`scripts/gate/input-source.swift select com.apple.keylayout.ABC-QWERTZ`. Keep or delete the gate data dir.
