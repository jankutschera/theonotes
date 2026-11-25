// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct JournalQuarantineEligibilityTests {
    @Test func movedAsideAssessmentExcludesCanonicalAndRejectsForgedNames() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "source")
        let dir = library.paths.journal
        let canonicalBase = note.id + ".base", canonicalJournal = note.id + ".jsonl"
        let movedBase = note.id + ".base.unreplayed", movedJournal = note.id + ".jsonl.unreplayed"
        let canonicalBytes = Data("canonical untouched".utf8)
        try canonicalBytes.write(to: dir.appendingPathComponent(canonicalBase))
        try canonicalBytes.write(to: dir.appendingPathComponent(canonicalJournal))
        try Data("broken base".utf8).write(to: dir.appendingPathComponent(movedBase))
        try Data("broken journal\n".utf8).write(to: dir.appendingPathComponent(movedJournal))
        let result = try JournalQuarantineEligibility.assessMovedAside(noteId: note.id, directory: dir, fileNames: [movedBase, movedJournal])
        guard case let .eligible(_, names) = result else { Issue.record("Expected damaged moved-aside group"); return }
        #expect(Set(names) == Set([movedBase, movedJournal]))
        #expect(try Data(contentsOf: dir.appendingPathComponent(canonicalBase)) == canonicalBytes)
        #expect(try Data(contentsOf: dir.appendingPathComponent(canonicalJournal)) == canonicalBytes)
        for invalid in [[canonicalBase], [canonicalJournal, movedBase], ["../outside"], ["other.base.unreplayed"], [movedBase, movedBase]] {
            #expect(throws: (any Error).self) { try JournalQuarantineEligibility.assessMovedAside(noteId: note.id, directory: dir, fileNames: invalid) }
        }
    }
    @Test func moreThanFourPlainVariantsOfferEntireGroupForPreservation() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        for index in 1...3 {
            let url = library.paths.journal.appendingPathComponent(id + ".base.unreplayed.\(index)")
            try JSONEncoder().encode(JournalBase(storeRevision: index + 1, baseText: "else")).write(to: url)
        }
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .recoverablePlain)
        let fifth = library.paths.journal.appendingPathComponent(id + ".base.unreplayed.4")
        try JSONEncoder().encode(JournalBase(storeRevision: 5, baseText: "last")).write(to: fifth)
        guard case .eligible(.ambiguous, let names) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) else { Issue.record("Expected whole over-limit group"); return }
        #expect(names.count == 6 && names.contains(fifth.lastPathComponent))
    }
    @Test func independentlyNumberedPlausibleBasesAreNeverGuessed() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString, journal = try EditJournal(directory: library.paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let other = library.paths.journal.appendingPathComponent(id + ".base.unreplayed")
        try JSONEncoder().encode(JournalBase(storeRevision: 2, baseText: "else")).write(to: other)
        #expect(try !MissingJournalRecovery.candidates(directory: library.paths.journal).contains { $0.noteId == id })
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .recoverablePlain)
    }
    @Test func plainPairWithExtraIsNotAutomaticallyAssociated() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let note = try library.store.create(text: "base")
        try library.store.trash([note.id]); try library.store.deletePermanently([note.id])
        let journal = try EditJournal(directory: library.paths.journal, noteId: note.id)
        try journal.writeBase(JournalBase(storeRevision: note.revision, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: " kept")])))
        let extraName = note.id + ".base.unreplayed"
        try Data("unreadable base".utf8).write(to: library.paths.journal.appendingPathComponent(extraName))
        #expect(try !MissingJournalRecovery.candidates(directory: library.paths.journal).contains { $0.noteId == note.id })
        #expect(try JournalQuarantineEligibility.assess(noteId: note.id, directory: library.paths.journal) == .recoverablePlain)
    }
    @Test func ambiguousGroupsProtectReadableAndLockedPairsAndRejectSymlinks() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        let extra = library.paths.journal.appendingPathComponent(id + ".base.unreplayed")
        try Data("extra".utf8).write(to: extra)
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .recoverablePlain)
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: journal.baseURL)
        #expect(throws: (any Error).self) { try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) }
    }
    @Test func ambiguousSealedPairRequiresVerifiedCurrentVault() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        try Data("extra".utf8).write(to: library.paths.journal.appendingPathComponent(id + ".base.unreplayed"))
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .requiresKey)
        guard case .eligible(.ambiguous, _) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal, access: access) else { Issue.record("Expected byte-preserving move after unlock"); return }
        access.revoke()
        #expect(throws: (any Error).self) { try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal, access: access) }
    }
    @Test func corruptSealedJournalRequiresCurrentAccessBeforeQuarantine() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        let valid = try Data(contentsOf: journal.fileURL)
        var broken = valid; broken[broken.count - 3] = broken[broken.count - 3] == 65 ? 66 : 65
        try broken.write(to: journal.fileURL)
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .requiresKey)
        guard case .eligible(.damaged, _) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal, access: access) else { Issue.record("Expected damaged with verified access"); return }
        #expect(try Data(contentsOf: journal.fileURL) == broken)
        access.revoke()
        #expect(throws: (any Error).self) { try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal, access: access) }
    }
    @Test func validPlainRecoveryIsNotQuarantinedButCorruptionAndAmbiguityAre() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id)
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "base"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(4), .replace(deleteLength: 0, insert: "!")])))
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .recoverablePlain)
        try Data("bad\n".utf8).write(to: journal.fileURL)
        guard case .eligible(.damaged, _) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) else { Issue.record("Expected damaged"); return }
        try Data("other".utf8).write(to: library.paths.journal.appendingPathComponent(id + ".base.unreplayed"))
        guard case .eligible(.ambiguous, _) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) else { Issue.record("Expected ambiguous"); return }
    }

    @Test func sealedFilesWithoutKeyAreNotTreatedAsDamagedAndMixedFilesAre() throws {
        let library = try PrivacyTestLibrary(); defer { library.cleanup() }
        let access = try library.access(), id = UUID().uuidString
        let journal = try EditJournal(directory: library.paths.journal, noteId: id, encryptionKey: access.journalKey())
        try journal.writeBase(JournalBase(storeRevision: 1, baseText: "secret"))
        try journal.append(JournalEntry(txId: "1", baseRevision: 0, changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 0, insert: "!")])))
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .requiresKey)
        let handle = try FileHandle(forWritingTo: journal.fileURL); try handle.seekToEnd(); try handle.write(contentsOf: Data("plaintext\n".utf8)); try handle.close()
        #expect(try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal) == .requiresKey)
        guard case .eligible(.mixed, _) = try JournalQuarantineEligibility.assess(noteId: id, directory: library.paths.journal, access: access) else { Issue.record("Expected mixed after unlock"); return }
    }
}
