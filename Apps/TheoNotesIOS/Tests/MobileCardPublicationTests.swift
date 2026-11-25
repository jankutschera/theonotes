// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileCardPublicationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }

    @Test func snapshotUsesPinnedAndInboxSemanticsAndExcludesPrivateOrRemovedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let plain = try library.store.create(text: "# Public\n\nVisible first line")
        let tagged = try library.store.create(text: "# Tagged\n\nVisible #parent/child")
        let idea = try library.store.create(text: "# Idea\n\n#idea")
        let template = try library.store.create(text: "# Template\n\n#template")
        let trashed = try library.store.create(text: "# Trash secret")
        let archived = try library.store.create(text: "# Archive secret")
        let protected = try library.store.create(text: "# Private secret\n\nPrivate body #private-tag")
        try library.store.setPinned([plain.id], pinned: true)
        try library.store.setPinned([tagged.id], pinned: true, inTag: "parent")
        try library.store.trash([trashed.id]); try library.store.archive([archived.id])
        try library.store.recordOpened(noteId: plain.id, now: Self.now.addingTimeInterval(-10))
        try library.store.recordOpened(noteId: tagged.id, now: Self.now)
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        try #require(library.privateAccess).lock(noteId: protected.id)
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar)
        #expect(Set(snapshot.pinned.map(\.id)) == Set([plain.id, tagged.id]))
        #expect(snapshot.inbox.contains { $0.id == plain.id })
        #expect(!snapshot.inbox.contains { $0.id == idea.id || $0.id == template.id })
        #expect(snapshot.tags.first { $0.id == "parent" }?.notes.contains { $0.id == tagged.id } == true)
        #expect(snapshot.lastOpened?.id == tagged.id)
        let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for excluded in [protected.id, trashed.id, archived.id, "Private body", "private-tag"] {
            #expect(!encoded.contains(excluded))
        }
    }

    @Test func appLockEnabledRedactsEvenWhileAuthenticated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Must not leave app\n\n- [ ] Private task")
        try await library.setAppLock(true, authenticate: {})
        #expect(library.appLockEnabled && !library.appLocked)
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar)
        #expect(snapshot.redacted && snapshot.pinned.isEmpty && snapshot.inbox.isEmpty)
        #expect(snapshot.tags.isEmpty && snapshot.lastOpened == nil)
        #expect(snapshot.nextUp.count == 1 && snapshot.nextUp.first?.state == .locked)
        #expect(!String(decoding: try snapshot.encoded(), as: UTF8.self).contains(note.id))
    }

    @Test func synchronousScrubInvalidatesPreparedPublicationAndStartupClearsOldText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Old private text")
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        let pending = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        #expect(try publisher.scrub(now: Self.now))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
        #expect(try !publisher.publish(pending))
        _ = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
        #expect(try !publisher.refresh(now: Self.now, calendar: Self.calendar))
    }

    @Test func librarySwitchFencesOldPublisherAndUsesDifferentLibraryIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let first = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("first")))
        let second = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("second")))
        defer { try? first.close(); try? second.close(); try? FileManager.default.removeItem(at: root) }
        _ = try first.store.create(text: "# First library")
        let old = try MobileCardPublicationPublisher(library: first, container: container, now: Self.now)
        let prepared = try old.prepare(now: Self.now, calendar: Self.calendar)
        let current = try MobileCardPublicationPublisher(library: second, container: container, now: Self.now)
        #expect(MobileCardPublication.libraryID(for: first.paths) != MobileCardPublication.libraryID(for: second.paths))
        #expect(try !old.publish(prepared))
        #expect(try !old.scrub(now: Self.now))
        #expect(try current.refresh(now: Self.now, calendar: Self.calendar))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.libraryID == MobileCardPublication.libraryID(for: second.paths))
    }

    @Test func relockTrashAndCorruptionNeverReusePreviousSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Previously visible")
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        try library.store.trash([note.id])
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.inbox.isEmpty == true)
        try Data("broken".utf8).write(to: container.appendingPathComponent(WidgetSnapshot.relativePath))
        #expect(WidgetSnapshot.read(container: container, now: Self.now) == nil)
    }

    @Test func newestPreparationSupersedesOlderWorkBeforeAndAfterPublishing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# First version")
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        let first = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        let added = try library.store.create(text: "# Newer visible note")
        let second = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        #expect(try !publisher.publish(first)) // Superseded even before the newer result is installed.
        #expect(try publisher.publish(second))
        #expect(try !publisher.publish(first))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.inbox.contains { $0.id == added.id } == true)
    }

    @Test func failedScrubStaysPendingAndCannotAuthorizePlaintextPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Previously published title")
        var failWrites = false
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
            writeSnapshot: { snapshot, target in
                if failWrites { throw CocoaError(.fileWriteNoPermission) }
                try snapshot.write(to: target)
            }, removeSnapshot: { target in
                if failWrites { throw CocoaError(.fileWriteNoPermission) }
                try MobileCardPublicationPublisher.removeSnapshotFile(in: target)
            })
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        let old = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        try await library.setAppLock(true, authenticate: {})
        failWrites = true
        #expect(throws: CocoaError.self) { try publisher.scrub(now: Self.now) }
        #expect(publisher.needsScrub)
        // A failed atomic write can leave the previous file readable. Never claim it was cleaned.
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.inbox.contains { $0.id == note.id } == true)
        #expect(try !publisher.publish(old))
        #expect(throws: WidgetSnapshot.Invalid.self) { try publisher.prepare(now: Self.now, calendar: Self.calendar) }
        #expect(throws: CocoaError.self) { try publisher.refresh(now: Self.now, calendar: Self.calendar) }
        #expect(publisher.needsScrub)
        failWrites = false
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        #expect(!publisher.needsScrub)
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
    }

    @Test(arguments: [false, true])
    func failedPublicationAttemptsScrubAndTracksWhetherCleanupSucceeded(failScrub: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Public title")
        var rejectPlaintext = false
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
            writeSnapshot: { snapshot, target in
                if rejectPlaintext && (!snapshot.redacted || failScrub) { throw CocoaError(.fileWriteUnknown) }
                try snapshot.write(to: target)
            }, removeSnapshot: { target in
                if rejectPlaintext && failScrub { throw CocoaError(.fileWriteNoPermission) }
                try MobileCardPublicationPublisher.removeSnapshotFile(in: target)
            })
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        let prepared = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        rejectPlaintext = true
        #expect(throws: CocoaError.self) { try publisher.publish(prepared) }
        #expect(publisher.needsScrub == failScrub)
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == !failScrub)
        #expect(try !publisher.publish(prepared))
        rejectPlaintext = false
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        #expect(!publisher.needsScrub)
    }

    @Test func failedNewOwnerScrubStillFencesThePreviousPublisher() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Old owner")
        let old = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(try old.refresh(now: Self.now, calendar: Self.calendar))
        let prepared = try old.prepare(now: Self.now, calendar: Self.calendar)
        #expect(throws: CocoaError.self) {
            _ = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
                writeSnapshot: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                removeSnapshot: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(try !old.publish(prepared))
        #expect(try !old.scrub(now: Self.now))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == false)
        let replacement = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(try replacement.refresh(now: Self.now, calendar: Self.calendar))
    }

    @Test(arguments: ["appLock", "noteLock", "trash"])
    func privacyChangesAfterPreparationScrubInsteadOfPublishing(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Must disappear")
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        let prepared = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        switch change {
        case "appLock": try await library.setAppLock(true, authenticate: {})
        case "noteLock":
            try await library.unlockNotes(password: "fixture-password", createPassword: true)
            try #require(library.privateAccess).lock(noteId: note.id)
        default: try library.store.trash([note.id])
        }
        #expect(try !publisher.publish(prepared))
        #expect(!publisher.needsScrub)
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
    }

    @Test func startupFallbackRemovesOnlyKnownSnapshotAndDoesNotFollowFinalSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(WidgetSnapshot.relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = target.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: unrelated)
        try MobileCardPublicationPublisher.scrubForStartup(in: root, now: Self.now,
            writeSnapshot: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
        #expect(WidgetSnapshot.read(container: root, now: Self.now) == nil)
    }

    @Test func failedRedactedWriteCanScrubByDeletingTheSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("group")
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Prior title")
        var rejectWrites = false
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
            writeSnapshot: { snapshot, target in
                if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
                try snapshot.write(to: target)
            })
        #expect(try publisher.refresh(now: Self.now, calendar: Self.calendar))
        let stale = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        rejectWrites = true
        #expect(try publisher.scrub(now: Self.now))
        #expect(!publisher.needsScrub)
        #expect(WidgetSnapshot.read(container: container, now: Self.now) == nil)
        #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent(WidgetSnapshot.relativePath).path))
        #expect(try !publisher.publish(stale))
    }

    @Test func scrubRefusesFalseRemovalAndNeverTraversesASymlinkedParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try WidgetSnapshot.locked(libraryID: "fixture", now: Self.now).write(to: root)
        #expect(throws: (any Error).self) {
            try MobileCardPublicationPublisher.scrubForStartup(in: root, now: Self.now,
                writeSnapshot: { _, _ in throw CocoaError(.fileWriteNoPermission) }, removeSnapshot: { _ in })
        }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Card"), to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Card"), withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try MobileCardPublicationPublisher.scrubForStartup(in: root, now: Self.now,
                writeSnapshot: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("mobile-widgets.json").path))
    }

    @Test func startupWithNonDirectoryBlockerProvesSnapshotUnreadableWithoutDeletingBlocker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("Card")
        try Data("keep blocker".utf8).write(to: blocker)
        try MobileCardPublicationPublisher.scrubForStartup(in: root, now: Self.now)
        #expect(WidgetSnapshot.read(container: root, now: Self.now) == nil)
        #expect(try Data(contentsOf: blocker) == Data("keep blocker".utf8))
    }

    @Test func ownershipChangeDuringFailedScrubCannotDeleteNewOwnersSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        let container = root.appendingPathComponent("group")
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# New owner's title")
        var replaceOwner = false
        var replacement: MobileCardPublicationPublisher?
        let old = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
            writeSnapshot: { snapshot, target in
                if replaceOwner {
                    replacement = try MobileCardPublicationPublisher(library: library, container: target, now: Self.now)
                    _ = try replacement?.refresh(now: Self.now, calendar: Self.calendar)
                    throw CocoaError(.fileWriteUnknown)
                }
                try snapshot.write(to: target)
            })
        replaceOwner = true
        #expect(try !old.scrub(now: Self.now))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.inbox.contains { $0.id == note.id } == true)
        #expect(try #require(replacement).refresh(now: Self.now, calendar: Self.calendar))
    }

    @Test(arguments: ["publisher", "startup"])
    func containerOwnershipSurvivesDirectoryCreationAndURLRepresentationChanges(replacement: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        let absentContainer = URL(fileURLWithPath: root.appendingPathComponent("group").path, isDirectory: false)
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(!FileManager.default.fileExists(atPath: absentContainer.path))
        _ = try library.store.create(text: "# Original owner title")
        let old = try MobileCardPublicationPublisher(library: library, container: absentContainer, now: Self.now)
        #expect(try old.refresh(now: Self.now, calendar: Self.calendar))
        let prepared = try old.prepare(now: Self.now, calendar: Self.calendar)
        let existingDirectory = URL(fileURLWithPath: absentContainer.path + "/", isDirectory: true)
        if replacement == "publisher" {
            _ = try MobileCardPublicationPublisher(library: library, container: existingDirectory, now: Self.now)
        } else {
            try MobileCardPublicationPublisher.scrubForStartup(in: existingDirectory, now: Self.now)
        }
        #expect(try !old.publish(prepared))
        #expect(try !old.scrub(now: Self.now))
        #expect(WidgetSnapshot.read(container: existingDirectory, now: Self.now)?.redacted == true)
    }

    @Test func configuredPinnedNoteOutsideRecentWindowIsStillPublishedAndRechecked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        var ids: [String] = []
        for index in 0..<201 {
            ids.append(try library.store.create(text: "# Pin \(index)", now: Self.now.addingTimeInterval(Double(index - 500))).id)
        }
        try library.store.setPinned(ids, pinned: true)
        let oldest = try #require(ids.first)
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredNoteIDs: [oldest])
        #expect(snapshot.pinned.count == 200 && !snapshot.pinned.contains { $0.id == oldest })
        #expect(snapshot.configuredPins.map(\.id) == [oldest])
        #expect(snapshot.pinnedNote(entityID: snapshot.libraryID + ":" + oldest)?.id == oldest)
        let container = root.appendingPathComponent("group")
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        let prepared = try publisher.prepare(now: Self.now, calendar: Self.calendar, configuredNoteIDs: [oldest])
        #expect(try publisher.publish(prepared))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.configuredPins.map(\.id) == [oldest])
        try library.store.setPinned([oldest], pinned: false)
        #expect(try !publisher.publish(prepared))
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
        #expect(try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredNoteIDs: [oldest]).configuredPins.isEmpty)
        try library.store.setPinned([oldest], pinned: true)
        try await library.unlockNotes(password: "fixture-password", createPassword: true)
        try #require(library.privateAccess).lock(noteId: oldest)
        #expect(try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredNoteIDs: [oldest]).configuredPins.isEmpty)
    }

    @Test func configuredTagOutsideSuggestionWindowHasTwentyCurrentEligibleNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        for index in 0..<102 {
            let tag = String(format: "tag%03d", index)
            _ = try library.store.create(text: "# \(tag)\n\n#\(tag)", now: Self.now.addingTimeInterval(Double(index - 500)))
        }
        var selected: [String] = []
        for index in 0..<25 {
            selected.append(try library.store.create(text: "# Configured \(index)\n\n#tag000", now: Self.now.addingTimeInterval(Double(index - 1000))).id)
        }
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredTagIDs: ["tag000"])
        #expect(snapshot.tags.count == 100 && !snapshot.tags.contains { $0.id == "tag000" })
        #expect(snapshot.configuredTags.map(\.id) == ["tag000"])
        #expect(snapshot.configuredTags.first?.notes.count == 20)
        #expect(snapshot.list(tag: "tag000", libraryID: snapshot.libraryID).count == 20)
        try library.store.trash(selected + (snapshot.configuredTags.first?.notes.map(\.id) ?? []))
        let after = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredTagIDs: ["tag000"])
        #expect(after.configuredTags.isEmpty)
        #expect(after.list(tag: "tag000", libraryID: after.libraryID).isEmpty)
    }

    @Test func tagSuggestionsPrioritizePinsThenRecentNoteActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Pinned tag\n\n#pinned", now: Self.now.addingTimeInterval(-1000))
        let opened = try library.store.create(text: "# Opened tag\n\n#opened", now: Self.now.addingTimeInterval(-900))
        _ = try library.store.create(text: "# Modified tag\n\n#modified", now: Self.now.addingTimeInterval(-100))
        try library.store.setTagPinned("pinned", pinned: true)
        try library.store.recordOpened(noteId: opened.id, now: Self.now)
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar)
        #expect(snapshot.tags.map(\.id) == ["pinned", "opened", "modified"])
    }

    @Test func configuredLimitsRejectOverflowAndAppLockDropsConfiguredContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(throws: WidgetSnapshot.Invalid.self) {
            try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
                configuredNoteIDs: Set((0..<201).map { "note-\($0)" }))
        }
        #expect(throws: WidgetSnapshot.Invalid.self) {
            try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
                configuredTagIDs: Set((0..<101).map { "tag-\($0)" }))
        }
        let note = try library.store.create(text: "# Configured secret\n\n#secret")
        try library.store.setPinned([note.id], pinned: true)
        try await library.setAppLock(true, authenticate: {})
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar,
            configuredNoteIDs: [note.id], configuredTagIDs: ["secret"])
        #expect(snapshot.redacted && snapshot.configuredPins.isEmpty && snapshot.configuredTags.isEmpty)
        #expect(!String(decoding: try snapshot.encoded(), as: UTF8.self).contains(note.id))
    }

    @Test func configuredContentStillHonorsTotalPublicationByteLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let tags = Set((0..<100).map { String(format: "window%03d", $0) })
        let text = "# " + String(repeating: "👩🏽‍💻", count: 100) + "\n\n" + String(repeating: "👩🏽‍💻", count: 100) +
            "\n\n" + tags.sorted().map { "#" + $0 }.joined(separator: " ")
        for _ in 0..<20 { _ = try library.store.create(text: text) }
        #expect(throws: WidgetSnapshot.Invalid.self) {
            try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar, configuredTagIDs: tags)
        }
    }

    @Test func outputIsBoundedAndUnicodeDoesNotExceedWireLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        for index in 0..<205 {
            _ = try library.store.create(text: "# \(index) " + String(repeating: "👩🏽‍💻", count: 100) + "\n\n" + String(repeating: "é", count: 600))
        }
        let snapshot = try MobileCardPublication.make(library: library, now: Self.now, calendar: Self.calendar)
        #expect(snapshot.inbox.count == 20)
        #expect(snapshot.inbox.allSatisfy { $0.title.utf8.count <= 256 && $0.firstLine.utf8.count <= 512 })
        #expect(try snapshot.encoded().count <= WidgetSnapshot.maximumBytes)
        #expect(try WidgetSnapshot.decode(snapshot.encoded(), now: Self.now) == snapshot)
    }
    @Test(arguments: ["scrub", "lock", "replacement", "cancel", "newer"])
    func delayedBackgroundPreparationCannotCrossPrivacyOrOwnershipBoundary(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root.appendingPathComponent("library")))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        _ = try library.store.create(text: "# Public fixture")
        let container = root.appendingPathComponent("group")
        let gate = PublicationBuildGate()
        let publisher = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now,
            beforeBackgroundBuild: { await gate.hold() })
        let task = Task { try await publisher.prepareInBackground(now: Self.now, calendar: Self.calendar) }
        await gate.waitUntilEntered()
        #expect(publisher.hasBackgroundPreparations)
        switch reason {
        case "scrub": _ = try publisher.scrub(now: Self.now)
        case "lock": try await library.setAppLock(true, authenticate: {})
        case "replacement": _ = try MobileCardPublicationPublisher(library: library, container: container, now: Self.now)
        case "cancel": task.cancel()
        default: _ = try publisher.prepare(now: Self.now, calendar: Self.calendar)
        }
        var waitFinished = false
        let wait = Task { await publisher.waitForBackgroundPreparations(); waitFinished = true }
        await Task.yield()
        #expect(!waitFinished)
        await gate.release()
        do { _ = try await task.value; Issue.record("Stale or cancelled background preparation succeeded") }
        catch is CancellationError { #expect(reason == "cancel") }
        catch is WidgetSnapshot.Invalid { #expect(reason != "cancel") }
        catch { Issue.record("Unexpected error: \(error)") }
        await wait.value
        #expect(waitFinished && !publisher.hasBackgroundPreparations)
        #expect(WidgetSnapshot.read(container: container, now: Self.now)?.redacted == true)
    }

    @Test func backgroundPreparationMatchesSynchronousBuilder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try MobileLibrary(paths: AppPaths(root: root))
        defer { try? library.close(); try? FileManager.default.removeItem(at: root) }
        let note = try library.store.create(text: "# Public #work")
        try library.store.setPinned([note.id], pinned: true)
        let publisher = try MobileCardPublicationPublisher(library: library, container: root.appendingPathComponent("group"), now: Self.now)
        let prepared = try await publisher.prepareInBackground(now: Self.now, calendar: Self.calendar,
            configuredNoteIDs: [note.id], configuredTagIDs: ["work"])
        #expect(prepared.snapshot == (try MobileCardPublication.make(library: library, now: Self.now,
            calendar: Self.calendar, configuredNoteIDs: [note.id], configuredTagIDs: ["work"])))
        #expect(try publisher.publish(prepared))
        #expect(!publisher.hasBackgroundPreparations)
    }

}

private actor PublicationBuildGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters.removeAll()
        await withCheckedContinuation { held = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() { held?.resume(); held = nil }
}
