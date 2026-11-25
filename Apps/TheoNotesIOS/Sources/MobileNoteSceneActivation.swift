// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import TheoNotesCore
import UIKit

/// A window instance plus opaque routing identity, never a title, body or filesystem path.
/// Explicit opens create a fresh windowID; Codable restoration preserves that same ID.
struct MobileNoteSceneAddress: Hashable, Codable, Sendable {
    let windowID: UUID
    let libraryID: String
    let noteID: String
    enum Invalid: Error { case address, activity, unavailable }
    init(windowID: UUID = UUID(), libraryID: String, noteID: String) throws {
        guard libraryID.utf8.count == 64,
              libraryID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              noteID.utf8.count == 36, UUID(uuidString: noteID) != nil else { throw Invalid.address }
        self.windowID = windowID; self.libraryID = libraryID; self.noteID = noteID
    }
    private enum CodingKeys: String, CodingKey { case windowID, libraryID, noteID }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(windowID: values.decode(UUID.self, forKey: .windowID),
            libraryID: values.decode(String.self, forKey: .libraryID), noteID: values.decode(String.self, forKey: .noteID))
    }
}

/// Process-local intent only: never Codable, restored from disk or put in an activity.
/// A failed OS activation expires, and bounded eviction cannot expose note content.
@MainActor struct MobileExplicitWindowRequests {
    static let capacity = 64
    static let lifetime: TimeInterval = 120
    private var entries: [UUID: (address: MobileNoteSceneAddress, requested: Date)] = [:]
    var count: Int { entries.count }
    mutating func mark(_ address: MobileNoteSceneAddress, now: Date = .now) {
        entries = entries.filter { now >= $0.value.requested && now.timeIntervalSince($0.value.requested) < Self.lifetime }
        entries[address.windowID] = (address, now)
        if entries.count > Self.capacity, let oldest = entries.min(by: {
            $0.value.requested == $1.value.requested ? $0.key.uuidString < $1.key.uuidString : $0.value.requested < $1.value.requested
        }) { entries.removeValue(forKey: oldest.key) }
    }
    mutating func consume(_ address: MobileNoteSceneAddress, now: Date = .now) -> Bool {
        guard let entry = entries[address.windowID], entry.address == address else { return false }
        entries.removeValue(forKey: address.windowID)
        return now >= entry.requested && now.timeIntervalSince(entry.requested) < Self.lifetime
    }
}

@MainActor enum MobileNoteSceneActivation {
    nonisolated static let activityType = MobileIdentity.noteWindowActivityType
    private static var explicitRequests = MobileExplicitWindowRequests()
    static func requestedAddress(noteID: String, library: MobileLibrary) throws -> MobileNoteSceneAddress {
        let value = try address(noteID: noteID, library: library)
        explicitRequests.mark(value)
        return value
    }
    static func consumeExplicitRequest(_ address: MobileNoteSceneAddress) -> Bool {
        explicitRequests.consume(address)
    }
    private static let addressKey = "sceneAddress"
    enum Resolution { case note(Note), waitingForUnlock, unavailable }

    static var supportsMultipleWindows: Bool {
        supportsMultipleWindows(idiom: UIDevice.current.userInterfaceIdiom,
            supportsScenes: UIApplication.shared.supportsMultipleScenes)
    }
    nonisolated static func supportsMultipleWindows(idiom: UIUserInterfaceIdiom, supportsScenes: Bool) -> Bool {
        idiom == .pad && supportsScenes
    }
    static func address(noteID: String, library: MobileLibrary) throws -> MobileNoteSceneAddress {
        guard !library.appLocked, !library.isClosed, !library.isClosing, !library.libraryOperationBusy,
              let note = try library.store.note(id: noteID), note.deletedAt == nil else {
            throw MobileNoteSceneAddress.Invalid.unavailable
        }
        return try MobileNoteSceneAddress(libraryID: MobileCardPublication.libraryID(for: library.paths), noteID: noteID)
    }
    /// Resolve only in the destination scene. Never mutate shared navigation or treat
    /// a restoration/drag address as authorization to read protected text.
    static func resolve(_ address: MobileNoteSceneAddress, library: MobileLibrary) -> Resolution {
        guard !library.isClosed, !library.isClosing, !library.libraryOperationBusy,
              address.libraryID == MobileCardPublication.libraryID(for: library.paths) else { return .unavailable }
        if library.appLocked { return .waitingForUnlock }
        guard let note = try? library.store.note(id: address.noteID), note.deletedAt == nil else { return .unavailable }
        guard library.canRead(note) else { return .waitingForUnlock }
        return .note(note)
    }
    static func activity(for address: MobileNoteSceneAddress) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "Note"
        activity.targetContentIdentifier = address.windowID.uuidString
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        // Fixed-size validated identifiers make this encoding bounded and infallible.
        if let bytes = try? JSONEncoder().encode(address) { activity.userInfo = [addressKey: bytes] }
        return activity
    }
    static func address(from activity: NSUserActivity) throws -> MobileNoteSceneAddress {
        guard activity.activityType == activityType, let info = activity.userInfo,
              info.count == 1, let bytes = info[addressKey] as? Data, bytes.count <= 1024 else {
            throw MobileNoteSceneAddress.Invalid.activity
        }
        let address = try JSONDecoder().decode(MobileNoteSceneAddress.self, from: bytes)
        guard activity.targetContentIdentifier == address.windowID.uuidString else { throw MobileNoteSceneAddress.Invalid.activity }
        return address
    }
    /// UIKit recognizes NSUserActivity drags as requests for a new scene. NSString is
    /// additionally registered so existing SwiftUI String tag drops keep their UUID payload.
    static func dragProvider(for address: MobileNoteSceneAddress) -> NSItemProvider {
        let provider = NSItemProvider(object: activity(for: address))
        provider.registerObject(address.noteID as NSString, visibility: .all)
        provider.suggestedName = "Note"
        return provider
    }
    static func dragProvider(noteID: String, library: MobileLibrary) throws -> NSItemProvider {
        dragProvider(for: try address(noteID: noteID, library: library))
    }
}
