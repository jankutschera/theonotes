// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite struct WidgetFollowupTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot() -> WidgetSnapshot {
        let note = WidgetSnapshot.NoteCard(id: "selected", title: "Current title", firstLine: "Body")
        return WidgetSnapshot(libraryID: "library", generatedAt: now, redacted: false,
            nextUp: [.init(date: now, state: .empty)], pinned: [note], inbox: [note], lastOpened: note)
    }

    @Test func removedPinAndEmptyTagPreserveSelectionWithoutRenderingAnotherTarget() {
        let value = snapshot()
        let pin = NoteWidgetQuery.resolve(identifiers: ["library:removed"], snapshot: value).first
        #expect(pin?.id == "library:removed")
        #expect(value.selectedPinnedNote(entityID: pin?.id) == nil)
        #expect(value.selectedPinnedNote(entityID: nil) == nil)
        let tag = TagWidgetQuery.resolve(identifiers: ["library:empty-tag"], snapshot: value).first
        #expect(tag?.id == "library:empty-tag")
        let selected = value.selectedList(entityID: tag?.id)
        #expect(selected.isEmpty)
        #expect(value.selectedList(entityID: nil).map(\.id) == ["selected"])
        #expect(value.selectedList(entityID: "invalid").isEmpty)
        #expect(value.selectedList(entityID: "other:").isEmpty)
    }

    @Test func unreadableRedactedAndOtherLibraryEntitiesKeepOnlyOpaqueIdentity() {
        for value in [Optional<WidgetSnapshot>.none, .some(.locked(libraryID: "library", now: now)), .some(snapshot())] {
            let note = NoteWidgetQuery.resolve(identifiers: ["old:secret", "invalid", "library:"], snapshot: value)
            #expect(note.map(\.id) == ["old:secret"])
            #expect(note.first?.title == "Unavailable Note")
            let tag = TagWidgetQuery.resolve(identifiers: ["old:secret", "library:", "invalid"], snapshot: value)
            #expect(tag.map(\.id) == ["old:secret", "library:"])
            #expect(tag.first?.title == "Unavailable List")
        }
    }

    @Test func unreadableNextUpIsNeutralAndLastOpenedNeverCreatesOrSearches() {
        #expect(WidgetRoutes.nextUpTitle(snapshot: nil, at: now) == "Open Theo Notes")
        #expect(WidgetRoutes.nextUpSymbol(snapshot: nil, at: now) == "note.text")
        #expect(WidgetRoutes.nextUpTitle(snapshot: snapshot(), at: now) == "Nothing next")
        for value in [Optional<WidgetSnapshot>.none, .some(.locked(libraryID: "library", now: now))] {
            #expect(WidgetRoutes.lastOpened(snapshot: value) == WidgetRoutes.openApp())
            #expect(URLComponents(url: WidgetRoutes.lastOpened(snapshot: value), resolvingAgainstBaseURL: false)?.queryItems == nil)
        }
        #expect(WidgetRoutes.lastOpenedSymbol(snapshot: nil) == "note.text")
        #expect(WidgetRoutes.lastOpenedSymbol(snapshot: .locked(libraryID: "library", now: now)) == "lock")
    }

    @Test func newWireOmitsUnusedNotesAndReadsLegacyPublications() throws {
        var json = try #require(JSONSerialization.jsonObject(with: snapshot().encoded()) as? [String: Any])
        #expect(json["notes"] == nil)
        json["notes"] = [["id": "legacy", "title": "Unused legacy text", "firstLine": "Unused"]]
        let read = try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: json), now: now)
        #expect(read == snapshot())
        #expect(!(try #require(JSONSerialization.jsonObject(with: read.encoded()) as? [String: Any])).keys.contains("notes"))
        json = try #require(JSONSerialization.jsonObject(with: WidgetSnapshot.locked(libraryID: "library", now: now).encoded()) as? [String: Any])
        json["notes"] = [["id": "legacy", "title": "Must not leak", "firstLine": "Unused"]]
        #expect(throws: WidgetSnapshot.Invalid.self) { try WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: json), now: now) }
    }

    @Test func publicationUsesAtomicUntilFirstUnlockWritePolicyAndRoundTrips() throws {
        // Exact equality rejects additional/weaker protection flags as well as missing ones.
        #expect(WidgetSnapshot.writeOptions == [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try snapshot().write(to: root)
        #expect(WidgetSnapshot.read(container: root, now: now) == snapshot())
    }

    #if os(iOS) && !targetEnvironment(simulator)
    @Test func physicalDeviceSnapshotHasUntilFirstUnlockProtectionAttribute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try snapshot().write(to: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(WidgetSnapshot.relativePath).path)
        let protection = try #require(attributes[.protectionKey], "Snapshot has no file-protection attribute")
        // Foundation can return the NSString/String raw value rather than its Swift wrapper.
        // Require an actual attribute and the exact class; missing/unknown values must fail.
        let rawValue = (protection as? FileProtectionType)?.rawValue ?? (protection as? String)
        #expect(rawValue == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
            "Unexpected file protection: \(String(reflecting: protection)); type: \(String(reflecting: type(of: protection)))")
    }
    #endif
}
