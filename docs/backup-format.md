# Theo Notes backup and recovery

The mobile Settings → Backup and Restore screen creates a `.baerchen-backup` archive,
exports it through the system document picker and lists local recovery copies. A selected
archive is verified before the screen shows its date, note count, locked-note count and
attachment count. Merge is the default and preserves existing note IDs. Replace All asks
for confirmation and first creates a verified safety archive of the current library.

Version 1 is a ZIP64-capable ZIP with a SHA-256 manifest, one `<note-id>.textbundle` per
note, and `library.json`. Each bundle contains `info.json`, an exact-source `record.json`,
and `assets/`. Ordinary notes also contain a portable `text.md` with asset-relative links.
Locked notes contain no plaintext Markdown: their BNC1 body and BCH1 attachment files
remain encrypted under the note-password vault. Titles and tags retain their normal
visible semantics. Attachments retained for undo or generous relative-link recovery are
included even when the derived attachment row is tombstoned.

An attachment whose file was already absent is recorded with `isMissing: true` and its
stable identity, filename and metadata. Its bytes are not fabricated. Review distinguishes
the available-file count from the missing-file count; restoration preserves the missing
link and identity. A missing record must not also have an asset file in the archive.
Older version-1 records without this optional field still require their asset bytes.
Symlinks, including dangling files and note directories, are rejected rather than treated
as missing. This allows incomplete imports and partially downloaded notes to be backed up.

The manifest covers every file other than itself. Restore checks the path inventory,
hashes, byte counts, schema versions, identifiers and relationships before mutation.
Archive extraction refuses symlinks, traversal, duplicate case/Unicode paths, file-parent
collisions, bad CRCs and oversized entries. Extraction streams data and removes partial
output on failure. Device authentication credentials and account master keys are not
portable backup metadata.

Restore stages attachment files first, then commits note and metadata changes together
with durable file-install markers. Launch recovery finishes interrupted installation.
Restoring into an empty library adopts the backup's note-password envelope. A Merge
between different password vaults asks for both passwords and re-encrypts content into
the current vault, streaming attachment plaintext only through memory. Wrong passwords
and identity collisions abort the transaction. Replace All adopts the backup password.
Sync dirty markers and immutable in-flight mutations survive a restore; restored changes
remain ordinary local changes for the sync engine.

## Version 2: focus state

Version 2 adds the capture and Next Up state. The manifest `version` is 2 and `library.json`
carries `version: 2`. The reader accepts 1 and 2 and refuses anything newer as unsupported.
A build that predates version 2 refuses a version 2 archive through its existing
`version == 1` check, so no older build can mis-read it.

`record.json` of each note gains optional fields; all of them are absent in a version 1
archive, and an archive whose manifest says 1 but carries one is refused:

- `captureSource`: one of the capture source names (`share`, `voice`, `lockscreen`,
  `shortcut`, `command`, `mcp`) or absent.
- `lastOpenedAt`: milliseconds since 1970. Absent for a locked note, which keeps no UI state.
- `pings`: reminders as `{id, anchorLine?, anchorHash?, fireAt, firedAt?, createdAt}`. The line
  and the hash are both present or both absent. A locked note has at most one reminder and it
  has no anchor.
- `hides`: Next Up hides as `{candidateKey, hiddenUntil}` for `note:<id>`, `todo:<id>:<line>:<hash>`
  and `ping:<id>` keys, always of the note the record belongs to. A locked note has none.
- `snapshots`: note history as `{id, takenAt, text?, sealedText?}`. An unlocked note carries
  `text`; a locked note carries `sealedText` only, the ciphertext exactly as stored. Locked
  snapshots are never opened for the archive, so the archive holds no plaintext of a locked
  note.

`library.json` gains `notTodayUntil`, the end of the library-wide "Not Today" hide.

Restore treats every one of these fields as hostile input. Before anything is written it
checks identifiers (valid and unique across the archive), anchors, per-note limits (at most
1000 reminders, 1000 hides and 100 snapshots), text length, the ciphertext prefix and that
every date lies between 0001-01-01 00:00:00 and 9999-12-31 23:59:59.999 UTC (milliseconds
since 1970, also within the sync revision range). In a version 1 archive the fields must be
absent: a key that is present as `null` is refused as well. Any failure refuses the whole
archive and the library stays as it was.

Creating a backup fails with a clear error, and leaves no file behind, when a locked note has
a plaintext snapshot or an unlocked note a sealed one; such a row is never written in the
clear and never skipped.

A Merge adds the focus state of the notes it adds and leaves the focus state of notes that
already exist alone. When a Merge re-keys locked notes into a different password vault, their
sealed snapshots are re-sealed under the current vault key with their own snapshot context.
Replace All replaces the focus state with the archive's. Notification bookkeeping and share
receipts are device-local and are never part of an archive. Restored reminders are planned
again by the app after the restore.

Restoring into a note that a voice capture is writing into first stops that capture (as a lock
does), so a locked row never lands next to a capture's plaintext journal.

The app also creates daily database recovery snapshots using SQLite's online backup API,
keeping seven. These `.sqlite` snapshots are internal database recovery files, separate
from portable archives and their attachment copies. They are never made by copying a
live database/WAL file. Locking a note removes catalogued local copies containing its old
plaintext, plus abandoned app-owned archive/staging files left by an interrupted backup.
Copies deliberately exported outside the app's backup directory remain the user's files.

Focused verification covers exact source, metadata and stable asset IDs; default Merge;
Replace All and its safety archive; encrypted restoration into an empty library; merging
different password vaults; unchanged libraries after corruption/wrong passwords;
retained encrypted attachments; daily retention; and privacy cleanup of old/orphan copies.
Mobile runtime and Files-provider interaction still require device acceptance.
