#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

"""Compare two local Theo Notes library snapshots without disclosing note contents."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys


def digest(value):
    def encode(item):
        if isinstance(item, bytes):
            return {"bytes": item.hex()}
        raise TypeError("Unsupported database value")
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False, default=encode).encode()).digest()


def milliseconds(value):
    if value is None:
        return None
    if isinstance(value, (float, int)):
        # GRDB numeric dates are Unix seconds.
        seconds = value
    else:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        seconds = parsed.timestamp()
    # Match Swift's rounded() (ties away from zero).
    import math
    return math.floor(seconds * 1000 + 0.5) if seconds >= 0 else math.ceil(seconds * 1000 - 0.5)


def file_digest(root, note_id, filename):
    # Do not follow malformed references or symlinks outside the attachment tree.
    if any(not part or part in (".", "..") or "/" in part or "\\" in part
           for part in (note_id, filename)):
        return "unsafe", None
    directory = root / "Attachments" / note_id
    path = directory / filename
    try:
        if directory.is_symlink() or (root / "Attachments").is_symlink():
            return "unsafe", None
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                return "unsafe", None
            hasher = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(chunk)
            after = os.fstat(stream.fileno())
            current = path.stat(follow_symlinks=False)
            fingerprint = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if fingerprint(before) != fingerprint(after) or fingerprint(after) != fingerprint(current):
                return "changed_during_read", None
            return "present", hasher.digest()
    except FileNotFoundError:
        return "missing", None
    except OSError:
        return "unreadable", None


def snapshot(root):
    db = sqlite3.connect((root / "Baerchen.sqlite").as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        db.execute("PRAGMA query_only=ON")
        db.execute("BEGIN")
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        def count(table):
            return db.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0] if table in tables else None
        notes, attachments = {}, {}
        locations = {"notes": 0, "archive": 0, "trash": 0}
        file_counts = {k: 0 for k in ("present", "missing", "unsafe", "unreadable", "changed_during_read")}
        rows = list(db.execute("SELECT * FROM note"))
        for row in rows:
            note = dict(row)
            locations[note["location"]] = locations.get(note["location"], 0) + 1
            fields = ("text", "title", "location", "isPinnedGlobal", "isReadOnly", "isLocked", "encryptedPayload")
            semantic = {field: note[field] for field in fields}
            semantic["text"] = "" if note["isLocked"] else (note["text"] or "")
            for field in ("createdAt", "modifiedAt", "trashedAt", "archivedAt"):
                semantic[field] = milliseconds(note[field])
            for name, query in (
                ("directTags", "SELECT t.displayPath FROM tag t JOIN note_tag n ON t.id=n.tagId WHERE n.noteId=? AND n.isDirect=1"),
                ("pinnedTags", "SELECT t.displayPath FROM tag t JOIN note_pin n ON t.id=n.tagId WHERE n.noteId=?"),
            ):
                semantic[name] = sorted(r[0] for r in db.execute(query, (note["id"],)))
            # SyncNotePayload.capture(includeRetained:true) includes deleted/retained files.
            refs = list(db.execute("SELECT id,filename FROM attachment WHERE noteId=? ORDER BY id", (note["id"],)))
            semantic["attachmentNames"] = {r["id"]: r["filename"] for r in refs}
            conflict = db.execute("SELECT originalNoteId,rejectedMutationId,remoteRevision FROM sync_conflict WHERE noteId=?", (note["id"],)).fetchone() if "sync_conflict" in tables else None
            semantic["conflict"] = list(conflict) if conflict else None
            notes[note["id"]] = digest(semantic)
            for ref in refs:
                status, checksum = file_digest(root, note["id"], ref["filename"])
                file_counts[status] += 1
                attachments[ref["id"]] = (status, checksum)
        cursor = db.execute("SELECT sequence FROM sync_cursor WHERE id=1").fetchone() if "sync_cursor" in tables else None
        enabled = db.execute("SELECT enabled FROM sync_control WHERE id=1").fetchone() if "sync_control" in tables else None
        summary = {
            "notes": len(notes), "locations": locations,
            "attachment_references_including_retained": len(attachments), "attachment_files": file_counts,
            "sync_enabled": bool(enabled[0]) if enabled else None,
            "pending_upload_entities": count("sync_dirty"), "outbox_mutations": count("sync_outbox"),
            "pending_download_entities": count("sync_inbox"), "pull_cursor": cursor[0] if cursor else None,
            "staging_batches": count("staging_batch"), "privacy_transitions": count("privacy_transition"),
        }
        summary["pending_uploads_by_entity_type"] = dict(db.execute(
            "SELECT entityType,COUNT(*) FROM sync_dirty GROUP BY entityType"
        )) if "sync_dirty" in tables else None
        return notes, attachments, summary
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Pass library roots containing Baerchen.sqlite and Attachments/. SQLite is opened mode=ro "
        "in a read transaction; preserve -wal/-shm alongside a copied database. No titles, text, IDs, "
        "paths or hashes are printed. DB transactions do not freeze attachment files or both devices. "
        "Use quiescent snapshots after sync settles; missing source files can keep pending uploads nonzero."
    ))
    parser.add_argument("left", type=Path, help="First library root (e.g. Mac production)")
    parser.add_argument("right", type=Path, help="Second library root (e.g. copied iPhone library)")
    args = parser.parse_args()
    try:
        left_notes, left_files, left = snapshot(args.left.expanduser().resolve())
        right_notes, right_files, right = snapshot(args.right.expanduser().resolve())
    except (sqlite3.Error, OSError, ValueError, KeyError, TypeError):
        print("Comparison failed: library unavailable or schema/data unsupported; no private details emitted.", file=sys.stderr)
        return 2
    common = left_notes.keys() & right_notes.keys()
    files = left_files.keys() & right_files.keys()
    comparable = {key for key in files if left_files[key][0] == right_files[key][0] == "present"}
    changed = sum(left_notes[key] != right_notes[key] for key in common)
    file_changed = sum(left_files[key][1] != right_files[key][1] for key in comparable)
    report = {
        "scope": "Local snapshots only; not a consistent cross-device snapshot until queues settle. File reads are not atomic with the database.",
        "left": left, "right": right,
        "both_queues_settled": all(
            side["sync_enabled"] and all(side[key] == 0 for key in (
                "pending_upload_entities", "outbox_mutations", "pending_download_entities",
                "staging_batches", "privacy_transitions")) for side in (left, right)
        ),
        "comparison": {
            "notes_only_left": len(left_notes.keys() - right_notes.keys()),
            "notes_only_right": len(right_notes.keys() - left_notes.keys()),
            "notes_semantically_equal": len(common) - changed, "notes_semantically_different": changed,
            "attachment_refs_only_left": len(left_files.keys() - right_files.keys()),
            "attachment_refs_only_right": len(right_files.keys() - left_files.keys()),
            "attachment_contents_equal": len(comparable) - file_changed,
            "attachment_contents_different": file_changed,
            "common_attachment_refs_without_two_readable_files": len(files) - len(comparable),
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    # An equal comparison with shared missing files is still incomplete file acceptance.
    complete = (left_notes == right_notes and left_files == right_files
                and len(comparable) == len(left_files) == len(right_files))
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main())
