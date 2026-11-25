// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

enum WatchWireError: Error, Equatable {
    case invalid, unauthorized, outOfOrder, storage, capacity, binding, clock
    case pendingDurability(UUID)
}
func watchHashValid(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
private func watchTextValid(_ value: String, limit: Int) -> Bool { value.utf8.count <= limit && !value.contains("\0") }

enum WatchWireAction: Codable, Equatable, Sendable {
    case create(text: String)
    case append(noteID: String, revision: Int, text: String)
    case setTask(noteID: String, revision: Int, sourceSHA256: String, utf16Offset: Int, expectedMarker: String, checked: Bool)
}
struct WatchWireCommand: Codable, Equatable, Sendable {
    var version = 1
    let id: UUID
    let libraryID: String
    let epoch: UUID
    let createdAt: Date
    let action: WatchWireAction
    static let maximumAge: TimeInterval = 7 * 86_400
    init(version: Int = 1, id: UUID, libraryID: String, epoch: UUID, createdAt: Date = .now, action: WatchWireAction) {
        self.version = version; self.id = id; self.libraryID = libraryID; self.epoch = epoch
        self.createdAt = createdAt; self.action = action
    }
    func validate() throws {
        guard version == 1, watchHashValid(libraryID), createdAt.timeIntervalSince1970.isFinite else { throw WatchWireError.invalid }
        switch action {
        case .create(let text), .append(_, _, let text):
            guard watchTextValid(text, limit: 16_384), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WatchWireError.invalid }
        case .setTask(_, _, let hash, let offset, let marker, _):
            guard watchHashValid(hash), (0...1_048_576).contains(offset), ["[ ]", "[x]", "[X]"].contains(marker) else { throw WatchWireError.invalid }
        }
        switch action {
        case .create: break
        case .append(let id, let revision, _), .setTask(let id, let revision, _, _, _, _):
            guard UUID(uuidString: id) != nil, revision >= 0, revision < Int.max - 1 else { throw WatchWireError.invalid }
        }
    }
}
enum WatchWireRefusal: String, Codable, Equatable, Sendable {
    case epochMismatch, identifierReused, privacy, missingTarget, staleTarget, readOnly, invalidCommand, wrongLibrary, unavailable, expired
}
enum WatchWireResult: Codable, Equatable, Sendable {
    case applied(noteID: String, revision: Int)
    case appliedArchived(noteID: String, revision: Int)
    case appliedTrashed(noteID: String, revision: Int)
    case refused(WatchWireRefusal)
}
struct WatchWireAck: Codable, Equatable, Sendable {
    var version = 1
    let commandID: UUID
    let libraryID: String
    let epoch: UUID
    let result: WatchWireResult
    func matches(_ command: WatchWireCommand) -> Bool {
        guard version == 1, commandID == command.id, libraryID == command.libraryID, epoch == command.epoch,
              (try? command.validate()) != nil else { return false }
        switch result {
        case .refused: return true
        case .applied(let id, let revision), .appliedArchived(let id, let revision), .appliedTrashed(let id, let revision):
            guard UUID(uuidString: id) != nil, revision >= 0, revision < Int.max else { return false }
            switch command.action {
            case .create: return true
            case .append(let target, let expected, _): return id == target && revision == expected + 1
            case .setTask(let target, let expected, _, _, let marker, let checked):
                return id == target && revision == expected + (checked == (marker != "[ ]") ? 0 : 1)
            }
        }
    }
}
struct WatchWireTask: Codable, Equatable, Sendable {
    let title: String
    let isChecked: Bool
    let sourceSHA256: String
    let utf16Offset: Int
    let expectedMarker: String
    var isValid: Bool {
        watchTextValid(title, limit: 256) && watchHashValid(sourceSHA256) &&
        (0...1_048_576).contains(utf16Offset) && ["[ ]", "[x]", "[X]"].contains(expectedMarker) &&
        isChecked == (expectedMarker != "[ ]")
    }
}
struct WatchWireNote: Codable, Equatable, Sendable {
    let id: String
    let revision: Int
    let title: String
    let text: String
    let tasks: [WatchWireTask]
}
struct WatchWireHello: Codable, Equatable, Sendable {
    let id: UUID
    let issuedAt: Date
    let expiresAt: Date
    static let lifetime: TimeInterval = 30
    static let clockSkew: TimeInterval = 5
    func validate(now: Date) throws {
        guard issuedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              issuedAt <= now.addingTimeInterval(Self.clockSkew), now < expiresAt, expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= Self.lifetime else { throw WatchWireError.unauthorized }
    }
}
struct WatchWireSnapshot: Codable, Equatable, Sendable {
    var version = 1
    let libraryID: String
    let epoch: UUID
    let generation: UInt64
    let authorizationID: UUID
    let issuedAt: Date
    let expiresAt: Date
    let redacted: Bool
    let notes: [WatchWireNote]
    func sanitizingTasks() -> Self {
        var remaining = 256
        let clean = notes.map { note in
            var seen = Set<Int>()
            let tasks = note.tasks.filter { $0.isValid && seen.insert($0.utf16Offset).inserted }.prefix(min(64, remaining))
            remaining -= tasks.count
            return WatchWireNote(id: note.id, revision: note.revision, title: note.title, text: note.text, tasks: Array(tasks))
        }
        return Self(version: version, libraryID: libraryID, epoch: epoch, generation: generation,
                    authorizationID: authorizationID, issuedAt: issuedAt, expiresAt: expiresAt, redacted: redacted, notes: clean)
    }
    func validate(now: Date) throws {
        try WatchWireHello(id: authorizationID, issuedAt: issuedAt, expiresAt: expiresAt).validate(now: now)
        guard version == 1, watchHashValid(libraryID), notes.count <= 15,
              Set(notes.map(\.id)).count == notes.count, !redacted || notes.isEmpty,
              notes.reduce(0, { $0 + $1.tasks.count }) <= 256,
              notes.allSatisfy({ note in
                  UUID(uuidString: note.id) != nil && note.revision >= 0 && note.revision < Int.max - 1 &&
                  watchTextValid(note.title, limit: 256) && watchTextValid(note.text, limit: 32_768) &&
                  note.tasks.count <= 64 && Set(note.tasks.map(\.utf16Offset)).count == note.tasks.count && note.tasks.allSatisfy(\.isValid)
              }), notes.reduce(0, { total, note in
                  total + note.title.utf8.count + note.text.utf8.count + note.tasks.reduce(0, { $0 + $1.title.utf8.count })
              }) <= 131_072 else { throw WatchWireError.invalid }
    }
}
enum WatchWirePacket: Codable, Equatable, Sendable {
    case hello(WatchWireHello), command(WatchWireCommand), ack(WatchWireAck), snapshot(WatchWireSnapshot), redact
    static let maximumBytes = 1_048_576
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WatchWireError.invalid }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw WatchWireError.invalid }
    }
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw WatchWireError.invalid }
        return data
    }
}

/// Authorization and note contents are volatile. Every privacy boundary must call invalidate().
struct WatchSnapshotAuthorization {
    private var hello: WatchWireHello?
    private var snapshot: WatchWireSnapshot?
    private var lastObservedAt: Date?
    mutating func invalidate() { hello = nil; snapshot = nil; lastObservedAt = nil }
    mutating func authorize(_ hello: WatchWireHello, now: Date) throws {
        invalidate(); try hello.validate(now: now)
        self.hello = hello; lastObservedAt = now
    }
    private mutating func checkTime(_ now: Date) -> Bool {
        guard let hello, let lastObservedAt, now >= lastObservedAt, now < hello.expiresAt else { invalidate(); return false }
        self.lastObservedAt = now
        return true
    }
    mutating func accept(_ incoming: WatchWireSnapshot, now: Date) throws {
        // A valid redaction is unconditional: a lock event cannot depend on an old handshake.
        if incoming.redacted {
            guard incoming.version == 1, incoming.notes.isEmpty else { throw WatchWireError.invalid }
            invalidate(); return
        }
        guard checkTime(now), let hello, incoming.authorizationID == hello.id,
              incoming.issuedAt >= hello.issuedAt, incoming.expiresAt <= hello.expiresAt else { throw WatchWireError.unauthorized }
        try incoming.validate(now: now)
        if let snapshot {
            guard incoming.libraryID == snapshot.libraryID, incoming.epoch == snapshot.epoch else { throw WatchWireError.unauthorized }
            guard incoming.generation > snapshot.generation else { throw WatchWireError.outOfOrder }
        }
        snapshot = incoming
    }
    mutating func visibleNotes(now: Date) -> [WatchWireNote] {
        guard checkTime(now), let snapshot else { return [] }
        guard now < snapshot.expiresAt else { invalidate(); return [] }
        return snapshot.notes
    }
}
