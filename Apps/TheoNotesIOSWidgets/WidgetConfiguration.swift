// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import Foundation

enum WidgetPublication {
    static func read(now: Date = Date()) -> WidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "THEONOTES_AppGroupIdentifier") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return WidgetSnapshot.read(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group), now: now)
    }
}
struct NoteWidgetEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let defaultQuery = NoteWidgetQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title.isEmpty ? "Untitled Note" : title)") }
    init(libraryID: String, note: WidgetSnapshot.NoteCard) { id = libraryID + ":" + note.id; title = note.title }
    init(id: String, title: String) { self.id = id; self.title = title }
    var parts: (library: String, note: String)? {
        let value = id.split(separator: ":", maxSplits: 1).map(String.init)
        return value.count == 2 ? (value[0], value[1]) : nil
    }
}
struct NoteWidgetQuery: EntityQuery {
    func suggestedEntities() async throws -> [NoteWidgetEntity] {
        guard let snapshot = WidgetPublication.read(), !snapshot.redacted else { return [] }
        // Configuration resolves current data; a saved entity title is never used for rendering.
        return snapshot.pinnedSuggestions.map { NoteWidgetEntity(libraryID: snapshot.libraryID, note: $0) }
    }
    func entities(for identifiers: [String]) async throws -> [NoteWidgetEntity] {
        Self.resolve(identifiers: identifiers, snapshot: WidgetPublication.read())
    }
    static func resolve(identifiers: [String], snapshot: WidgetSnapshot?) -> [NoteWidgetEntity] {
        identifiers.compactMap { id in
            guard let parts = widgetEntityParts(id), !parts.1.isEmpty else { return nil }
            let note = snapshot?.pinnedNote(entityID: id)
            return NoteWidgetEntity(id: id, title: note?.title ?? "Unavailable Note")
        }
    }
}
struct PinnedNoteConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned Note"
    static let description = IntentDescription("Choose an unprotected pinned note to display.")
    @Parameter(title: "Note") var note: NoteWidgetEntity?
}
struct TagWidgetEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag or Inbox"
    static let defaultQuery = TagWidgetQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(libraryID: String, tag: String?) { id = libraryID + ":" + (tag ?? ""); title = tag.map { "#" + $0 } ?? "Inbox" }
    init(id: String, title: String) { self.id = id; self.title = title }
    var parts: (library: String, tag: String?)? {
        let value = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return value.count == 2 ? (value[0], value[1].isEmpty ? nil : value[1]) : nil
    }
}
struct TagWidgetQuery: EntityQuery {
    func suggestedEntities() async throws -> [TagWidgetEntity] {
        guard let snapshot = WidgetPublication.read(), !snapshot.redacted else { return [] }
        return [TagWidgetEntity(libraryID: snapshot.libraryID, tag: nil)] + snapshot.tags.map { TagWidgetEntity(libraryID: snapshot.libraryID, tag: $0.id) }
    }
    func entities(for identifiers: [String]) async throws -> [TagWidgetEntity] {
        Self.resolve(identifiers: identifiers, snapshot: WidgetPublication.read())
    }
    static func resolve(identifiers: [String], snapshot: WidgetSnapshot?) -> [TagWidgetEntity] {
        identifiers.compactMap { id in
            guard let parts = widgetEntityParts(id) else { return nil }
            let available = snapshot.map { !$0.redacted && $0.libraryID == parts.0 && (parts.1.isEmpty || $0.tagExists(parts.1)) } ?? false
            let title = available ? (parts.1.isEmpty ? "Inbox" : "#" + parts.1) : "Unavailable List"
            return TagWidgetEntity(id: id, title: title)
        }
    }
}
struct NoteListConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Tag or Inbox"
    @Parameter(title: "List") var list: TagWidgetEntity?
}

// Preserve a saved selection's opaque identity even when its current data is unavailable.
// This prevents optional AppEntity resolution from silently selecting another note or Inbox.
private func widgetEntityParts(_ id: String) -> (String, String)? {
    let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty,
          parts.allSatisfy({ $0.utf8.count <= 256 && !$0.contains("\0") }) else { return nil }
    return (parts[0], parts[1])
}
