// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation

/// Shared wire contract only. The extension never opens the library database.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct NoteCard: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let firstLine: String
    }
    struct TagList: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let notes: [NoteCard]
    }
    struct NextUpEntry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case candidate, empty, locked }
        let date: Date
        let state: State
        var noteId: String? = nil
        var kind: String? = nil
        var title: String? = nil
        var line: String? = nil
    }
    static let relativePath = "Card/mobile-widgets.json"
    static let maximumBytes = 2 * 1024 * 1024
    static let lifetime: TimeInterval = 24 * 3600
    var version = 1
    var libraryID: String
    var generatedAt: Date
    var redacted: Bool
    var nextUp: [NextUpEntry]
    var pinned: [NoteCard] = []
    var inbox: [NoteCard] = []
    var tags: [TagList] = []
    var lastOpened: NoteCard? = nil
    /// Targeted records for existing configurations, independent of discovery windows.
    var configuredPins: [NoteCard] = []
    var configuredTags: [TagList] = []

    static func locked(libraryID: String, now: Date) -> Self {
        Self(libraryID: libraryID, generatedAt: now, redacted: true, nextUp: [.init(date: now, state: .locked)])
    }
    enum Invalid: Error { case publication }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= maximumBytes else { throw Invalid.publication }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(Self.self, from: data)
        try value.validate(now: now)
        return value
    }
    func validate(now: Date) throws {
        func text(_ value: String, maximum: Int) -> Bool {
            value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value == 0 }
        }
        func identifier(_ value: String) -> Bool { !value.isEmpty && text(value, maximum: 256) }
        func cards(_ values: [NoteCard], limit: Int) -> Bool {
            values.count <= limit && Set(values.map(\.id)).count == values.count && values.allSatisfy {
                identifier($0.id) && text($0.title, maximum: 256) && text($0.firstLine, maximum: 512)
            }
        }
        guard version == 1, identifier(libraryID), generatedAt.timeIntervalSince1970.isFinite,
              generatedAt <= now.addingTimeInterval(300), now.timeIntervalSince(generatedAt) <= Self.lifetime,
              !nextUp.isEmpty, nextUp.count <= 10,
              cards(pinned, limit: 200), cards(inbox, limit: 20), tags.count <= 100,
              cards(configuredPins, limit: 200), configuredTags.count <= 100,
              Set(configuredTags.map(\.id)).count == configuredTags.count,
              configuredTags.allSatisfy({ identifier($0.id) && cards($0.notes, limit: 20) }),
              Set(tags.map(\.id)).count == tags.count,
              tags.allSatisfy({ identifier($0.id) && cards($0.notes, limit: 20) }),
              lastOpened.map({ cards([$0], limit: 1) }) ?? true else { throw Invalid.publication }
        var prior = Date.distantPast
        for entry in nextUp {
            guard entry.date.timeIntervalSince1970.isFinite, entry.date > prior,
                  entry.date >= generatedAt.addingTimeInterval(-1), entry.date <= generatedAt.addingTimeInterval(Self.lifetime + 1) else { throw Invalid.publication }
            prior = entry.date
            if entry.state == .candidate {
                guard let id = entry.noteId, identifier(id), let kind = entry.kind,
                      ["reminder", "todo", "capture"].contains(kind), let title = entry.title,
                      text(title, maximum: 256), entry.line.map({ text($0, maximum: 512) }) ?? true else { throw Invalid.publication }
            } else {
                guard entry.noteId == nil, entry.kind == nil, entry.title == nil, entry.line == nil else { throw Invalid.publication }
            }
        }
        guard nextUp[0].date <= generatedAt.addingTimeInterval(1) else { throw Invalid.publication }
        if redacted {
            guard nextUp.count == 1, nextUp[0].state == .locked, pinned.isEmpty,
                  inbox.isEmpty, tags.isEmpty, lastOpened == nil,
                  configuredPins.isEmpty, configuredTags.isEmpty else { throw Invalid.publication }
        }
    }
    func selectedPinnedNote(entityID: String?) -> NoteCard? {
        guard let entityID else { return nil }
        return pinnedNote(entityID: entityID)
    }
    func selectedList(entityID: String?) -> [NoteCard] {
        guard let entityID else { return list(tag: nil, libraryID: libraryID) }
        let parts = entityID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return [] }
        return list(tag: parts[1].isEmpty ? nil : parts[1], libraryID: parts[0])
    }
    /// Suggestions are bounded gallery choices. Stored identities resolve directly against the
    /// bounded pinned publication, independently of suggestion enumeration.
    var pinnedSuggestions: [NoteCard] { redacted ? [] : Array(pinned.prefix(200)) }
    func pinnedNote(entityID: String) -> NoteCard? {
        let components = entityID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard !redacted, components.count == 2, components[0] == libraryID else { return nil }
        return configuredPins.first { $0.id == components[1] } ?? pinned.first { $0.id == components[1] }
    }
    func list(tag: String?, libraryID: String?) -> [NoteCard] {
        guard !redacted, libraryID == self.libraryID else { return [] }
        guard let tag else { return inbox }
        return (configuredTags.first { $0.id == tag } ?? tags.first { $0.id == tag })?.notes ?? []
    }
    func tagExists(_ id: String) -> Bool {
        !redacted && (configuredTags.contains { $0.id == id } || tags.contains { $0.id == id })
    }
    func nextUpEntry(at date: Date) -> NextUpEntry? {
        guard date.timeIntervalSince(generatedAt) <= Self.lifetime else { return nil }
        return nextUp.last { $0.date <= date }
    }
    /// No previous-value cache: missing, replaced, oversized or corrupt files are empty immediately.
    static func read(container: URL?, now: Date = Date()) -> Self? {
        guard let container else { return nil }
        let url = container.appendingPathComponent(relativePath)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= maximumBytes else { return nil }
        do {
            var bytes = Data()
            while let part = try handle.read(upToCount: min(64 * 1024, maximumBytes - bytes.count + 1)), !part.isEmpty {
                bytes.append(part)
                guard bytes.count <= maximumBytes else { return nil }
            }
            var after = stat(), path = stat()
            guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, bytes.count == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  path.st_mode & S_IFMT == S_IFREG, path.st_ino == after.st_ino, path.st_dev == after.st_dev else { return nil }
            return try decode(bytes, now: now)
        } catch { return nil }
    }
    /// Shared by the production write and policy test. Simulator filesystems do not expose
    /// NSFileProtectionKey; actual protection remains a mandatory physical-device readback.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    func write(to container: URL) throws {
        try validate(now: generatedAt)
        let bytes = try encoded()
        guard bytes.count <= Self.maximumBytes else { throw Invalid.publication }
        let url = container.appendingPathComponent(Self.relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: Self.writeOptions)
    }
}

// Explicit additive decoding keeps version1 publications written before configured records valid.
// Kept in an extension so the memberwise construction API remains available to the app builder.
extension WidgetSnapshot {
    private enum CodingKeys: String, CodingKey {
        case version, libraryID, generatedAt, redacted, nextUp, pinned, inbox, tags, lastOpened
        case legacyNotes = "notes"
        case configuredPins, configuredTags
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(libraryID, forKey: .libraryID)
        try values.encode(generatedAt, forKey: .generatedAt)
        try values.encode(redacted, forKey: .redacted)
        try values.encode(nextUp, forKey: .nextUp)
        try values.encode(pinned, forKey: .pinned)
        try values.encode(inbox, forKey: .inbox)
        try values.encode(tags, forKey: .tags)
        try values.encodeIfPresent(lastOpened, forKey: .lastOpened)
        try values.encode(configuredPins, forKey: .configuredPins)
        try values.encode(configuredTags, forKey: .configuredTags)
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        libraryID = try values.decode(String.self, forKey: .libraryID)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        redacted = try values.decode(Bool.self, forKey: .redacted)
        nextUp = try values.decode([NextUpEntry].self, forKey: .nextUp)
        let legacyNotes = try values.decodeIfPresent([NoteCard].self, forKey: .legacyNotes) ?? []
        if redacted && !legacyNotes.isEmpty { throw Invalid.publication }
        pinned = try values.decode([NoteCard].self, forKey: .pinned)
        inbox = try values.decode([NoteCard].self, forKey: .inbox)
        tags = try values.decode([TagList].self, forKey: .tags)
        lastOpened = try values.decodeIfPresent(NoteCard.self, forKey: .lastOpened)
        configuredPins = try values.decodeIfPresent([NoteCard].self, forKey: .configuredPins) ?? []
        configuredTags = try values.decodeIfPresent([TagList].self, forKey: .configuredTags) ?? []
    }
}
