// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct WidgetConfigurationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot() -> WidgetSnapshot {
        let a = WidgetSnapshot.NoteCard(id: "a", title: "Alpha", firstLine: "First")
        let b = WidgetSnapshot.NoteCard(id: "b", title: "Beta", firstLine: "Second")
        return WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .candidate, noteId: a.id, kind: "todo", title: a.title, line: "Do it")],
            pinned: [b], inbox: [a], tags: [.init(id: "work", notes: [b])], lastOpened: a)
    }
    @Test func configurationResolvesOnlyCurrentPublishedLibraryAndContent() throws {
        let value = try WidgetSnapshot.decode(snapshot().encoded(), now: now)
        #expect(value.list(tag: nil, libraryID: "library").map(\.id) == ["a"])
        #expect(value.list(tag: "work", libraryID: "library").map(\.id) == ["b"])
        #expect(value.list(tag: "removed", libraryID: "library").isEmpty)
    }
    @Test func pinnedConfigurationExcludesUnpinnedAndResolvesStoredPinsOutsideGeneralNotes() {
        var value = snapshot()
        value.pinned = (0..<75).map { .init(id: "pin-\($0)", title: "Pin \($0)", firstLine: "") }
        #expect(value.pinnedSuggestions.count == 75)
        #expect(value.pinnedSuggestions.allSatisfy { $0.id != "a" })
        #expect(value.pinnedNote(entityID: "library:pin-74")?.title == "Pin 74")
        #expect(value.pinnedNote(entityID: "library:a") == nil)
        #expect(value.pinnedNote(entityID: "old:pin-74") == nil)
        #expect(value.pinnedNote(entityID: "malformed") == nil)
        value.pinned.removeLast()
        #expect(value.pinnedNote(entityID: "library:pin-74") == nil)
        value.redacted = true
        #expect(value.pinnedSuggestions.isEmpty)
        #expect(value.pinnedNote(entityID: "library:pin-0") == nil)
    }

    @Test func configuredPinsAndTagsResolveOutsideSuggestionWindowsWithoutExpandingSuggestions() throws {
        var value = snapshot()
        let selected = WidgetSnapshot.NoteCard(id: "old-pin", title: "Configured pin", firstLine: "Still here")
        value.pinned = (0..<200).map { .init(id: "suggested-pin-\($0)", title: "Pin", firstLine: "") }
        value.tags = (0..<100).map { .init(id: "suggested-tag-\($0)", notes: []) }
        value.configuredPins = [selected]
        value.configuredTags = [.init(id: "old-tag", notes: [selected])]
        let read = try WidgetSnapshot.decode(value.encoded(), now: now)
        #expect(read.pinnedSuggestions.count == 200)
        #expect(!read.pinnedSuggestions.contains { $0.id == "old-pin" })
        #expect(read.tags.count == 100)
        #expect(!read.tags.contains { $0.id == "old-tag" })
        #expect(read.pinnedNote(entityID: "library:old-pin") == selected)
        #expect(read.pinnedNote(entityID: "other:old-pin") == nil)
        #expect(read.list(tag: "old-tag", libraryID: "library") == [selected])
        #expect(read.list(tag: "old-tag", libraryID: "other").isEmpty)
        #expect(read.tagExists("old-tag"))
        #expect(!read.tagExists("removed-tag"))
        let locked = WidgetSnapshot.locked(libraryID: "library", now: now)
        #expect(locked.configuredPins.isEmpty && locked.configuredTags.isEmpty)
        #expect(locked.pinnedNote(entityID: "library:old-pin") == nil)
        #expect(locked.list(tag: "old-tag", libraryID: "library").isEmpty)
        var leakyLocked = locked
        leakyLocked.configuredPins = [selected]
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(leakyLocked.encoded(), now: now) }
        leakyLocked.configuredPins = []
        leakyLocked.configuredTags = [.init(id: "old-tag", notes: [selected])]
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(leakyLocked.encoded(), now: now) }
    }

    @Test func configuredRecordsOverrideSuggestionCopiesAndRemainStrictlyBounded() throws {
        var value = snapshot()
        value.configuredPins = [.init(id: "b", title: "Updated configured pin", firstLine: "")]
        value.configuredTags = [.init(id: "work", notes: value.configuredPins)]
        #expect(value.pinnedNote(entityID: "library:b")?.title == "Updated configured pin")
        #expect(value.list(tag: "work", libraryID: "library").first?.title == "Updated configured pin")
        value.configuredPins = (0..<201).map { .init(id: "id-\($0)", title: "", firstLine: "") }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
        value.configuredPins = []
        value.configuredTags = (0..<101).map { .init(id: "tag-\($0)", notes: []) }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
    }

    @Test func oldSchemaWithoutConfiguredArraysDecodesWithEmptyConfiguredRecords() throws {
        var json = try #require(JSONSerialization.jsonObject(with: snapshot().encoded()) as? [String: Any])
        json.removeValue(forKey: "configuredPins"); json.removeValue(forKey: "configuredTags")
        let read = try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: json), now: now)
        #expect(read.configuredPins.isEmpty && read.configuredTags.isEmpty)
    }

    @Test func corruptStaleFutureAndLeakyRedactedPublicationsFailClosed() throws {
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(Data("bad".utf8), now: now) }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(snapshot().encoded(), now: now.addingTimeInterval(86401)) }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(snapshot().encoded(), now: now.addingTimeInterval(-301)) }
        var leaky = snapshot(); leaky.redacted = true
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(leaky.encoded(), now: now) }
        let locked = WidgetSnapshot.locked(libraryID: "library", now: now)
        let read = try WidgetSnapshot.decode(locked.encoded(), now: now)
        #expect(read.pinned.isEmpty && read.lastOpened == nil && read.nextUp.first?.title == nil)
    }
    @Test func unsupportedVersionAndOversizedFieldsAreRefused() throws {
        var value = snapshot(); value.version = 2
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
        value = snapshot(); value.pinned = [.init(id: "a", title: String(repeating: "x", count: 257), firstLine: "")]
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
    }
}

@Suite struct WidgetPublicationFileTests {
    @Test func replacementScrubsImmediatelyAndCorruptMissingAndSymlinkFilesNeverReturnPriorText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let note = WidgetSnapshot.NoteCard(id: "a", title: "Private fixture", firstLine: "Fixture body")
        let open = WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .empty)], inbox: [note], lastOpened: note)
        try open.write(to: root)
        #expect(WidgetSnapshot.read(container: root, now: now)?.inbox.first?.title == "Private fixture")
        try WidgetSnapshot.locked(libraryID: "library", now: now).write(to: root)
        #expect(WidgetSnapshot.read(container: root, now: now)?.inbox.isEmpty == true)
        let file = root.appendingPathComponent(WidgetSnapshot.relativePath)
        try Data("broken".utf8).write(to: file)
        #expect(WidgetSnapshot.read(container: root, now: now) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(WidgetSnapshot.read(container: root, now: now) == nil)
        let outside = root.appendingPathComponent("outside.json")
        try open.encoded().write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(WidgetSnapshot.read(container: root, now: now) == nil)
    }
    @Test func lockedEntriesWithHiddenTextAndDuplicateOrUnorderedEntriesAreRejected() throws {
        let now = Date()
        var value = WidgetSnapshot.locked(libraryID: "library", now: now)
        value.nextUp = [.init(date: now, state: .locked, title: "must not leak")]
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
        value.nextUp = [.init(date: now, state: .empty), .init(date: now, state: .empty)]
        value.redacted = false
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(value.encoded(), now: now) }
    }
}
