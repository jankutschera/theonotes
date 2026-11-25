// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Testing
@testable import TheoNotesCore

@Suite @MainActor struct JournalVariantRecoveryTests {
    @Test(arguments: [0, 1, 2, 3, 4]) func staleVariantConfirmationNeverInvalidatesRetainedHolder(change: Int) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        let firstEdit = ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])
        #expect(holder.apply(txId: "initial", baseRevision: 0, changeSet: firstEdit, origin: nil) == .acked(revision: 1))
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        try Data("damaged".utf8).write(to: journal.baseURL)
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        let names = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path)
        let markerName = try #require(names.first { $0.hasPrefix(".variant-confirm-") })
        let selection = try JournalQuarantine.inspectVariantFallback(store: library.store, markerName: markerName)
        let confirmation = try JournalQuarantine.confirmVariantFallback(selection, store: library.store)
        var added: NoteSession?
        if change == 1 {
            let edit = ChangeSet(sections: [.retain(5), .replace(deleteLength: 0, insert: " retained")])
            #expect(holder.apply(txId: "late", baseRevision: holder.revision, changeSet: edit, origin: nil) == .acked(revision: 2))
        } else if change == 2 {
            let marker = library.paths.journal.appendingPathComponent(markerName), temp = library.paths.root.appendingPathComponent("fixture-marker")
            try FileManager.default.moveItem(at: marker, to: temp)
            _ = try library.db.pool.write { try NoteStore.insert(id: note.id, text: "restored", now: .now, in: $0) }
            added = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
            try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
            if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
            try FileManager.default.moveItem(at: temp, to: marker)
        } else if change >= 3 {
            let receiptURL = confirmation.directory.appendingPathComponent(".confirmation.json")
            let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
            var receipt = try #require(parsed as? [String: Any])
            if change == 3 { receipt["version"] = 2 }
            else {
                var entries = try #require(receipt["entries"] as? [[String: Any]])
                entries[0]["boundMarker"] = true
                receipt["entries"] = entries
            }
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL)
        } else { try Data("changed after prompt".utf8).write(to: journal.baseURL) }
        let before = holder.text
        #expect(throws: (any Error).self) { try JournalQuarantine.resumeVariantFallback(confirmation, store: library.store) }
        #expect(!holder.isInvalidated && holder.text == before)
        if let added { #expect(!added.isInvalidated) }
        #expect(FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(markerName).path))
        #expect(FileManager.default.fileExists(atPath: confirmation.directory.appendingPathComponent(".confirmation.json").path))
    }
    @Test func finishPendingSkipsOnlyExcludedMarkerAndLaterResumes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        var journals: [EditJournal] = [], ids: [String] = []
        for text in ["base", "else"] {
            let note = try library.store.create(text: text)
            try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
            let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
            try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: text))
            try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
            let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
            #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
            journals.append(journal); ids.append(note.id)
        }
        let skipped = try JournalVariantRecovery.finishPending(store: library.store, access: nil, excluding: [ids[0]])
        #expect(skipped == [ids[0]])
        #expect(FileManager.default.fileExists(atPath: journals[0].baseURL.path))
        #expect(!FileManager.default.fileExists(atPath: journals[1].baseURL.path))
        #expect(try JournalVariantRecovery.finishPending(store: library.store, access: nil, excluding: []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: journals[0].baseURL.path))
    }
    @Test func confirmedVariantFallbackMovesOnlyBoundDamagedRemaindersAndResumes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        let base = journal.baseURL, bytes = Data("damaged base".utf8)
        try bytes.write(to: base)
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        let directoryNames = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path)
        let marker = try #require(directoryNames.first { $0.hasPrefix(".variant-confirm-") })
        let selection = try JournalQuarantine.inspectVariantFallback(store: library.store, markerName: marker)
        #expect(throws: (any Error).self) { try JournalQuarantine.confirm(selection) }
        let confirmed = try JournalQuarantine.confirmVariantFallback(selection, store: library.store)
        #expect(throws: (any Error).self) { try JournalQuarantine.resume(confirmed) }
        #expect(throws: (any Error).self) { try JournalQuarantine.resumeVariantFallback(confirmed, store: library.store, afterMove: { _ in throw CocoaError(.fileWriteUnknown) }) }
        try JournalQuarantine.resumeVariantFallback(confirmed, store: library.store)
        #expect(try Data(contentsOf: confirmed.directory.appendingPathComponent(base.lastPathComponent)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(marker).path))
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func automaticVariantFallbackWaitsForRetainedSessionWithoutInvalidatingIt() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        let damaged = Data("damaged".utf8)
        try damaged.write(to: journal.baseURL)
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        let names = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path)
        let name = try #require(names.first { $0.hasPrefix(".variant-confirm-") })
        let selected = try JournalQuarantine.inspectVariantFallback(store: library.store, markerName: name)
        let confirmed = try JournalQuarantine.confirmVariantFallback(selected, store: library.store)
        // Model an independently retained holder opening before marker discovery after restart.
        let marker = library.paths.journal.appendingPathComponent(name), temporary = library.paths.root.appendingPathComponent("marker-held-for-fixture")
        try FileManager.default.moveItem(at: marker, to: temporary)
        _ = try library.db.pool.write { try NoteStore.insert(id: note.id, text: "restored", now: .now, in: $0) }
        let holder = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        try library.db.pool.write { try $0.execute(sql: "DELETE FROM note WHERE id=?", arguments: [note.id]) }
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try FileManager.default.moveItem(at: temporary, to: marker)
        #expect(throws: (any Error).self) { try JournalQuarantine.resumeVariantFallbackAutomatically(confirmed, store: library.store) }
        #expect(!holder.isInvalidated && FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: journal.baseURL) == damaged)
        try holder.invalidate()
        try JournalQuarantine.resumeVariantFallbackAutomatically(confirmed, store: library.store)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
    @Test(arguments: [2, 4]) func missingVariantCopiesRecoverEveryBoundBaseAfterCrash(count: Int) throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        var originals: [URL: Data] = [journal.baseURL: try Data(contentsOf: journal.baseURL)]
        for index in 1..<count {
            let url = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed.\(index)")
            let bytes = try JSONEncoder().encode(JournalBase(storeRevision: note.revision, baseText: "bas\(index)"))
            try bytes.write(to: url); originals[url] = bytes
        }
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(saved.notes.count == count)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        for (url, bytes) in originals where !FileManager.default.fileExists(atPath: url.path) { try bytes.write(to: url) }
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        let recovered = try library.store.allNotes().filter { !saved.notes.map(\.id).contains($0.id) }
        #expect(recovered.count == count)
        #expect(recovered.contains { $0.text.contains("base") })
        for index in 1..<count { #expect(recovered.contains { $0.text.contains("bas\(index)") }) }
        for url in originals.keys { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func protectedVariantCrashRecoversMultipleBasesOnlyWithVaultKey() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        // A backup accepts only envelopes within the public KDF range.
        let access = try library.access(iterations: 100_000), note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let extra = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: note.revision, baseText: "bas2")).write(to: extra)
        let originals = [journal.baseURL: try Data(contentsOf: journal.baseURL), extra: try Data(contentsOf: extra)]
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: access)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: access, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        for (url, data) in originals where !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        #expect(throws: (any Error).self) { try JournalVariantRecovery.finishPending(store: library.store, access: nil) }
        for (url, bytes) in originals { #expect(try Data(contentsOf: url) == bytes) }
        try JournalVariantRecovery.finishPending(store: library.store, access: access)
        let notes = try library.store.allNotes().filter { !saved.notes.map(\.id).contains($0.id) }
        #expect(notes.count == 2 && notes.allSatisfy(\.isLocked))
        let texts = try notes.map { try access.note(id: $0.id)?.text ?? "" }
        #expect(texts.contains { $0.contains("bas2") })
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func abortedSourceCrashWithMissingCopiesRecoversAllBoundBases() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "restored source")
        let dir = library.paths.journal
        let names = [note.id + ".base.unreplayed", note.id + ".base.unreplayed.1", note.id + ".jsonl.unreplayed"]
        let base0 = try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "base"))
        let base1 = try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "bas2"))
        let entry = JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")]))
        var line = try JSONEncoder().encode(entry); line.append(10)
        for (name, bytes) in zip(names, [base0, base1, line]) { try bytes.write(to: dir.appendingPathComponent(name)) }
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": names]).write(to: dir.appendingPathComponent(".variant-aborted-\(hash).json"))
        let saved = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: nil)
        #expect(saved.notes.count == 2)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        try base0.write(to: dir.appendingPathComponent(names[0])); try base1.write(to: dir.appendingPathComponent(names[1]))
        let journal = dir.appendingPathComponent(names[2])
        if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        let recovered = try library.store.allNotes().filter { $0.id != note.id && !saved.notes.map(\.id).contains($0.id) }
        #expect(recovered.count == 2 && recovered.contains { $0.text.contains("bas2") })
        #expect(try library.store.note(id: note.id)?.text == "restored source")
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store).isEmpty)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func movedAsideRecoveryPreservesExistingSourceAndCanonicalFiles() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "current source")
        let dir = library.paths.journal
        let movedBase = dir.appendingPathComponent(note.id + ".base.unreplayed")
        let movedJournal = dir.appendingPathComponent(note.id + ".jsonl.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Base")).write(to: movedBase)
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")]))
        var data = try JSONEncoder().encode(entry); data.append(10); try data.write(to: movedJournal)
        let canonicalBase = dir.appendingPathComponent(note.id + ".base")
        let canonicalJournal = dir.appendingPathComponent(note.id + ".jsonl")
        let canonicalBytes = Data("canonical remains untouched".utf8)
        try canonicalBytes.write(to: canonicalBase); try canonicalBytes.write(to: canonicalJournal)
        let result = try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: nil)
        #expect(result.notes.count == 1 && result.notes[0].text.contains("Base edit"))
        #expect(Set(result.sourceNames) == Set([movedBase.lastPathComponent, movedJournal.lastPathComponent]))
        #expect(try library.store.note(id: note.id)?.text == "current source")
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil)
        #expect(!FileManager.default.fileExists(atPath: movedBase.path))
        #expect(!FileManager.default.fileExists(atPath: movedJournal.path))
        #expect(try Data(contentsOf: canonicalBase) == canonicalBytes)
        #expect(try Data(contentsOf: canonicalJournal) == canonicalBytes)
        #expect(try library.store.note(id: note.id)?.text == "current source")
    }
    @Test func movedAsideRetirementRefusesChangedSource() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "current")
        let dir = library.paths.journal
        let base = dir.appendingPathComponent(note.id + ".base.unreplayed")
        let journal = dir.appendingPathComponent(note.id + ".jsonl.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Base")).write(to: base)
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")]))
        var data = try JSONEncoder().encode(entry); data.append(10); try data.write(to: journal)
        let result = try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: nil)
        _ = try library.store.updateText(id: note.id, text: "changed", expectedRevision: note.revision, now: .now)
        #expect(throws: JournalVariantRecovery.Failure.changed) { try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil) }
        #expect(FileManager.default.fileExists(atPath: base.path) && FileManager.default.fileExists(atPath: journal.path))
    }
    @Test func movedAsideConfirmedRetirementResumesAfterInterruption() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "source")
        let dir = library.paths.journal
        let base = dir.appendingPathComponent(note.id + ".base.unreplayed")
        let journal = dir.appendingPathComponent(note.id + ".jsonl.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Base")).write(to: base)
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")]))
        var data = try JSONEncoder().encode(entry); data.append(10); try data.write(to: journal)
        let canonical = dir.appendingPathComponent(note.id + ".jsonl")
        let canonicalBytes = Data("canonical remains".utf8); try canonicalBytes.write(to: canonical)
        let result = try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) {
            try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil,
                                                               afterRemove: { throw CocoaError(.fileWriteUnknown) })
        }
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(FileManager.default.fileExists(atPath: base.path))
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        #expect(!FileManager.default.fileExists(atPath: base.path) && !FileManager.default.fileExists(atPath: journal.path))
        #expect(try Data(contentsOf: canonical) == canonicalBytes)
        #expect(try library.store.note(id: note.id)?.text == "source")
        #expect(try library.store.note(id: result.notes[0].id) != nil)
    }
    @Test func movedAsideMissingCopyAfterInterruptedRetirementSavesRemainingBase() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "source")
        let base = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        let journal = library.paths.journal.appendingPathComponent(note.id + ".jsonl.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 0, baseText: "Base")).write(to: base)
        let entry = JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")]))
        var bytes = try JSONEncoder().encode(entry); bytes.append(10); try bytes.write(to: journal)
        let first = try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(first.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        #expect(!FileManager.default.fileExists(atPath: journal.path) && FileManager.default.fileExists(atPath: base.path))
        try library.store.trash(first.notes.map(\.id)); try library.store.deletePermanently(first.notes.map(\.id))
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        #expect(try library.store.note(id: note.id)?.text == "source")
        #expect(try library.store.allNotes().contains { $0.id != note.id && $0.text.contains("Base") })
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }
    @Test func movedAsideAuthenticatedSealedPairRecoversWithoutTouchingSource() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "source")
        let access = try library.access()
        let temp = library.paths.root.appendingPathComponent("sealed-fixture")
        let journal = try EditJournal(directory: temp, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 0, baseText: "Base"))
        try journal.append(JournalEntry(txId: "one", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " edit")])))
        let baseDest = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        let journalDest = library.paths.journal.appendingPathComponent(note.id + ".jsonl.unreplayed")
        try FileManager.default.copyItem(at: journal.baseURL, to: baseDest)
        try FileManager.default.copyItem(at: journal.fileURL, to: journalDest)
        #expect(throws: JournalVariantRecovery.Failure.requiresKey) { try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: nil) }
        let result = try JournalVariantRecovery.recoverMovedAside(noteId: note.id, store: library.store, access: access)
        #expect(result.notes.count == 1 && result.notes[0].isLocked && result.notes[0].text.contains("Base edit"))
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: access)
        #expect(try library.store.note(id: note.id)?.text == "source")
        #expect(!FileManager.default.fileExists(atPath: baseDest.path) && !FileManager.default.fileExists(atPath: journalDest.path))
    }
    @Test func missingVariantCopyAfterCrashRecoversLoneBaseAndCompletes() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let originalBase = try Data(contentsOf: journal.baseURL)
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        // Model a partial retirement that left only the base, preserving exact marker-bound bytes.
        let baseName = note.id + ".base"
        if !FileManager.default.fileExists(atPath: journal.baseURL.path) {
            try originalBase.write(to: journal.baseURL)
        }
        if FileManager.default.fileExists(atPath: journal.fileURL.path) { try FileManager.default.removeItem(at: journal.fileURL) }
        try library.store.trash(saved.notes.map(\.id)); try library.store.deletePermanently(saved.notes.map(\.id))
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        #expect(try library.store.allNotes().contains { $0.text.contains("base") && !saved.notes.map(\.id).contains($0.id) })
        #expect(!FileManager.default.fileExists(atPath: library.paths.journal.appendingPathComponent(baseName).path))
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func plainAndSealedLoneBasesAreRecoveredInSeparateSteps() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "restored"), access = try library.access()
        let temporary = library.paths.root.appendingPathComponent("sealed-fixture")
        let sealed = try EditJournal(directory: temporary, noteId: note.id, encryptionKey: access.journalKey())
        try sealed.writeBase(JournalBase(storeRevision: 1, baseText: "sealed text"))
        let plainName = note.id + ".base", sealedName = note.id + ".base.unreplayed"
        try JSONEncoder().encode(JournalBase(storeRevision: 1, baseText: "plain text")).write(to: library.paths.journal.appendingPathComponent(plainName))
        try FileManager.default.copyItem(at: sealed.baseURL, to: library.paths.journal.appendingPathComponent(sealedName))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [plainName, sealedName]]).write(to: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let first = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: access)
        #expect(first.notes.count == 1 && first.notes[0].text.contains("plain text"))
        try JournalVariantRecovery.removeAfterConfirmation(first.retirement, store: library.store, access: access)
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store) == [sealedName])
        let second = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: access)
        #expect(second.notes.count == 1 && second.notes[0].text.contains("sealed text"))
        try JournalVariantRecovery.removeAfterConfirmation(second.retirement, store: library.store, access: access)
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store).isEmpty)
    }
    @Test func sealedLoneBaseFromDifferentVaultIsOfferedForMoveAfterUnlock() throws {
        let library = try PrivacyTestLibrary(), other = try PrivacyTestLibrary(); defer { library.cleanup(); other.cleanup() }
        let note = try library.store.create(text: "restored"), access = try library.access(), otherAccess = try other.access()
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: otherAccess.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "different vault"))
        try FileManager.default.removeItem(at: journal.fileURL)
        let name = note.id + ".base"
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [name]]).write(to: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        #expect(throws: JournalVariantRecovery.Failure.requiresKey) { try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: nil) }
        #expect(throws: JournalVariantRecovery.Failure.sealedAmbiguous) { try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: access) }
        #expect(FileManager.default.fileExists(atPath: journal.baseURL.path))
    }
    @Test func readableAbortedBasesBecomeSeparateVariantsAndDamagedBytesRemain() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "restored")
        let files = [note.id + ".base", note.id + ".base.unreplayed", note.id + ".base.unreplayed.1"]
        try JSONEncoder().encode(JournalBase(storeRevision: 1, baseText: "first")).write(to: library.paths.journal.appendingPathComponent(files[0]))
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "second")).write(to: library.paths.journal.appendingPathComponent(files[1]))
        try Data("damaged".utf8).write(to: library.paths.journal.appendingPathComponent(files[2]))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": files]).write(to: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        let result = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: nil)
        #expect(result.notes.count == 2 && result.notes.contains { $0.text.contains("first") } && result.notes.contains { $0.text.contains("second") })
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil)
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store) == [files[2]])
        #expect(try Data(contentsOf: library.paths.journal.appendingPathComponent(files[2])) == Data("damaged".utf8))
    }

    @Test func authenticatedSealedAbortedPairIsSavedSeparately() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "restored"), access = try library.access()
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        let files = [note.id + ".jsonl", note.id + ".base"]
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": files]).write(to: library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json"))
        #expect(throws: JournalVariantRecovery.Failure.requiresKey) { try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: nil) }
        let result = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: access)
        #expect(result.notes.count == 1 && result.notes[0].isLocked && result.notes[0].text.contains("secret!"))
        #expect(try library.store.note(id: note.id)?.text == "restored")
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: access)
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store).isEmpty)
    }
    @Test func readableAbortedLoneBaseIsSavedAsSeparateRecovery() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "restored source")
        let name = note.id + ".base.unreplayed"
        try JSONEncoder().encode(JournalBase(storeRevision: 1, baseText: "orphan base text")).write(to: library.paths.journal.appendingPathComponent(name))
        let hash = SHA256.hash(data: Data(note.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = library.paths.journal.appendingPathComponent(".variant-aborted-\(hash).json")
        try JSONSerialization.data(withJSONObject: ["noteId": note.id, "files": [name]]).write(to: marker)
        let result = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: nil)
        #expect(result.notes.count == 1 && result.notes[0].text.contains("orphan base text"))
        #expect(try library.store.note(id: note.id)?.text == "restored source")
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func normalActiveJournalWithoutVariantStateHasNoRestoredLeftovers() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "normal")
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "normal"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        #expect(try JournalVariantRecovery.restoredSourceLeftovers(noteId: note.id, store: library.store).isEmpty)
    }
    @Test func lockedPartialMarkerBlocksOnlySourceReplayUntilUnlockAndSeparateHandling() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access(iterations: 100_000)
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        let saved = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: access)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(saved.retirement, store: library.store, access: access, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        _ = try library.db.pool.write { db in try NoteStore.insert(id: note.id, text: "base", now: .now, in: db) }
        access.revoke()
        let before = try Data(contentsOf: journal.baseURL)
        #expect(throws: (any Error).self) { try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal) }
        #expect(try Data(contentsOf: journal.baseURL) == before && library.store.note(id: note.id)?.text == "base")
        let other = try library.store.create(text: "Other note")
        let otherSession = try NoteSession(noteId: other.id, store: library.store, journalDirectory: library.paths.journal)
        #expect(otherSession.text == "Other note")
        let unlocked = try NotePrivacy(store: library.store).unlock(password: "fixture-password")
        try MissingJournalRecovery.finishRetirements(directory: library.paths.journal, store: library.store, access: nil)
        #expect(throws: JournalProtectionError.keyRequired) { try JournalVariantRecovery.finishPending(store: library.store, access: nil) }
        try JournalVariantRecovery.finishPending(store: library.store, access: unlocked)
        let leftovers = try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store)
        #expect(!leftovers.isEmpty)
        #expect(throws: (any Error).self) { try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal) }
        let recovered = try JournalVariantRecovery.recoverAborted(noteId: note.id, store: library.store, access: unlocked)
        #expect(!recovered.notes.isEmpty && recovered.notes.allSatisfy(\.isLocked))
        try JournalVariantRecovery.removeAfterConfirmation(recovered.retirement, store: library.store, access: unlocked)
        #expect(try JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store).isEmpty)
        let reopened = try NoteSession(noteId: note.id, store: library.store, journalDirectory: library.paths.journal)
        #expect(reopened.text == "base")
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
    @Test func restoredSourceBlocksVariantRemovalAndNormalReplayCanProceed() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let original = try library.store.create(text: "base")
        try library.store.trash([original.id]); try library.store.deletePermanently([original.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: original.id)
        try journal.writeBase(JournalBase(storeRevision: original.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let extraName = original.id + ".base.unreplayed", extra = library.paths.journal.appendingPathComponent(extraName)
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: extra)
        let result = try JournalVariantRecovery.recover(noteId: original.id, store: library.store, access: nil)
        let before = try Data(contentsOf: journal.fileURL)
        _ = try library.db.pool.write { db in try NoteStore.insert(id: original.id, text: "base", now: .now, in: db) }
        #expect(throws: JournalVariantRecovery.Failure.changed) { try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil) }
        #expect(try Data(contentsOf: journal.fileURL) == before)
        let session = try NoteSession(noteId: original.id, store: library.store, journalDirectory: library.paths.journal)
        try session.flush()
        #expect(try library.store.note(id: original.id)?.text == "base!")
        let leftovers = try JournalVariantRecovery.restoredSourceLeftovers(noteId: original.id, store: library.store)
        #expect(leftovers == [extraName])
        let selection = try JournalQuarantine.inspect(libraryRoot: library.paths.root, fileNames: leftovers)
        try JournalQuarantine.resume(JournalQuarantine.confirm(selection))
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
        #expect(result.notes.count == 2)
    }

    @Test func restoredSourceBlocksCrashResumeWithoutRemovingRemainingFiles() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let extra = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: extra)
        let result = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(throws: (any Error).self) { try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil, afterRemove: { throw CocoaError(.fileWriteUnknown) }) }
        _ = try library.db.pool.write { db in try NoteStore.insert(id: note.id, text: "base", now: .now, in: db) }
        let before = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path).filter { !$0.hasPrefix(".variant-confirm-") }.sorted()
        let snapshots = try before.map { try Data(contentsOf: library.paths.journal.appendingPathComponent($0)) }
        try JournalVariantRecovery.finishPending(store: library.store, access: nil)
        let after = try FileManager.default.contentsOfDirectory(atPath: library.paths.journal.path).filter { !$0.hasPrefix(".variant-aborted-") }.sorted()
        #expect(after == before)
        #expect(try after.map { try Data(contentsOf: library.paths.journal.appendingPathComponent($0)) } == snapshots)
        #expect(try Set(JournalVariantRecovery.abortedSourceFiles(noteId: note.id, store: library.store)) == Set(before))
        #expect(throws: JournalVariantRecovery.Failure.changed) { try JournalVariantRecovery.clearResolvedAbortedSourceFiles(noteId: note.id, store: library.store) }
    }
    @Test func plausibleWrongLengthMatchIsMarkedUncertainAndOtherBytesStay() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "else"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let other = library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed")
        let original = try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "actual longer"))
        try original.write(to: other)
        let result = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(result.notes.count == 1 && result.notes[0].text.contains("pairing is uncertain") && result.notes[0].text.contains("else!"))
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil)
        #expect(try Data(contentsOf: other) == original)
    }
    @Test func ambiguousSealedGroupRequiresUnlockThenMovesAside() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base"), access = try library.access()
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try Data("extra".utf8).write(to: library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        #expect(throws: JournalVariantRecovery.Failure.requiresKey) { try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil) }
        #expect(throws: JournalVariantRecovery.Failure.sealedAmbiguous) { try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: access) }
        #expect(try library.store.allNotes().isEmpty)
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func failedGroupStateWriteRollsBackEveryVariant() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        try library.db.pool.write { try $0.execute(sql: "CREATE TRIGGER fail_variants BEFORE INSERT ON setting WHEN NEW.key LIKE 'journal.variants.%' BEGIN SELECT RAISE(ABORT, 'test'); END") }
        #expect(throws: (any Error).self) { try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil) }
        #expect(try library.store.allNotes().isEmpty)
        #expect(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }
    @Test func twoPlausiblePairingsCreateTwoVariantsBeforeRemoval() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: library.paths.journal.appendingPathComponent(note.id + ".base.unreplayed"))
        let result = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(result.notes.count == 2)
        #expect(result.notes.contains { $0.text.contains("base!") })
        #expect(result.notes.contains { $0.text.contains("else!") })
        #expect(result.notes.allSatisfy { $0.text.contains("Recovered edits, variant") })
        let replay = try JournalVariantRecovery.recover(noteId: note.id, store: library.store, access: nil)
        #expect(Set(result.notes.map(\.id)) == Set(replay.notes.map(\.id)))
        try JournalVariantRecovery.removeAfterConfirmation(result.retirement, store: library.store, access: nil)
        _ = try LibraryBackup(database: library.db, paths: library.paths).createRolling()
    }
}
