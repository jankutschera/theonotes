// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Darwin

struct WatchWireBinding: Codable, Equatable, Sendable {
    let libraryID: String
    let epoch: UUID
}
enum WatchWireOperationKind: String, Codable, Equatable, Sendable { case create, append, task }
extension WatchWireCommand {
    var kind: WatchWireOperationKind {
        switch action { case .create: .create; case .append: .append; case .setTask: .task }
    }
}

/// Only unsent command text is persisted, under complete file protection on Apple mobile OSes.
/// Snapshots and read authorization never enter this file. Retries reuse these exact commands.
@MainActor final class WatchCommandOutbox {
    static let deliveryLifetime: TimeInterval = 86_400
    // Legacy stores could contain 256 drafts plus 256 pending; JSON may escape each byte sixfold.
    private static let maximumBytes = 64 * 1_024 * 1_024
    struct Delivery: Codable, Equatable {
        let createdAt: Date
        let expiresAt: Date
        var expired: Bool
    }
    struct Draft: Codable, Equatable, Sendable {
        let id: UUID
        let text: String
    }
    struct Completion: Codable, Equatable, Sendable {
        let ack: WatchWireAck
        let kind: WatchWireOperationKind
    }
    private struct State: Codable {
        var version = 1
        var binding: WatchWireBinding?
        var pending: [WatchWireCommand] = []
        var completed: [Completion] = []
        var drafts: [Draft] = []
        var delivery: [UUID: Delivery]? = [:]
        var lastObservedAt: Date?
        var parentSyncDepth: Int?
    }
    private let url: URL
    private var state: State
    private(set) var requiresDurabilityRetry = false
    var beforeRenameForTesting: (() throws -> Void)?
    var beforeDirectorySyncForTesting: (() throws -> Void)?
    var beforeParentDirectorySyncForTesting: ((URL) throws -> Void)?
    var binding: WatchWireBinding? { state.binding }
    var pending: [WatchWireCommand] { state.pending }
    var completed: [Completion] { state.completed }
    var drafts: [Draft] { state.drafts }
    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Self.maximumBytes else { throw WatchWireError.storage }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.version == 1, state.pending.count <= 256, state.completed.count <= 64, state.drafts.count <= 512,
                  state.pending.count + state.drafts.count <= 512,
                  Set(state.pending.map(\.id)).count == state.pending.count,
                  Set(state.completed.map(\.ack.commandID)).count == state.completed.count,
                  Set(state.pending.map(\.id)).isDisjoint(with: state.completed.map(\.ack.commandID)),
                  Set(state.drafts.map(\.id)).count == state.drafts.count,
                  Set(state.pending.map(\.id)).isDisjoint(with: state.drafts.map(\.id)),
                  state.binding.map({ watchHashValid($0.libraryID) }) ?? true else { throw WatchWireError.storage }
            for command in state.pending { try command.validate() }
            for draft in state.drafts {
                guard draft.text.utf8.count <= 16_384, !draft.text.contains("\0"),
                      !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WatchWireError.storage }
            }
            for completion in state.completed {
                guard completion.ack.version == 1, watchHashValid(completion.ack.libraryID) else { throw WatchWireError.storage }
                switch completion.ack.result {
                case .applied(let id, let revision), .appliedArchived(let id, let revision), .appliedTrashed(let id, let revision):
                    guard UUID(uuidString: id) != nil, revision >= 0, revision < Int.max else { throw WatchWireError.storage }
                case .refused: break
                }
            }
            if state.delivery == nil {
                // Older local requests have no trustworthy deadline; preserve them for explicit retry.
                state.delivery = Dictionary(uniqueKeysWithValues: state.pending.map { ($0.id, Delivery(createdAt: $0.createdAt, expiresAt: $0.createdAt, expired: true)) })
                try commit(state)
            }
            guard Set(state.delivery?.keys.map { $0 } ?? []) == Set(state.pending.map(\.id)),
                  state.pending.allSatisfy({ state.delivery?[$0.id]?.createdAt == $0.createdAt }),
                  (0...16).contains(state.parentSyncDepth ?? 2),
                  state.lastObservedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  state.delivery?.values.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite &&
                      $0.expiresAt.timeIntervalSince1970.isFinite && $0.createdAt <= $0.expiresAt }) == true else { throw WatchWireError.storage }
            requiresDurabilityRetry = true
            try retryDurability()
        } else { state = State() }
    }
    private func commit(_ next: State) throws {
        try retryDurability()
        var next = next
        var ancestor = url.deletingLastPathComponent(), createdDepth = 0
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard createdDepth < 16 else { throw WatchWireError.storage }
            createdDepth += 1; ancestor.deleteLastPathComponent()
        }
        // Remember the depth across process restarts, including first-created Application Support.
        next.parentSyncDepth = max(2, max(next.parentSyncDepth ?? 2, createdDepth))
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.maximumBytes else { throw WatchWireError.capacity }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS) || os(watchOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: attributes) else { throw WatchWireError.storage }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        try beforeRenameForTesting?()
        guard rename(temporary.path, url.path) == 0 else { throw WatchWireError.storage }
        // After rename, retain the matching state but block delivery until directory durability is confirmed.
        state = next
        requiresDurabilityRetry = true
        try retryDurability()
    }
    func retryDurability() throws {
        guard requiresDurabilityRetry else { return }
        try beforeDirectorySyncForTesting?()
        var directoryURL = url.deletingLastPathComponent()
        for depth in 0...(state.parentSyncDepth ?? 2) {
            if depth > 0 { try beforeParentDirectorySyncForTesting?(directoryURL) }
            let directory = open(directoryURL.path, O_RDONLY)
            guard directory >= 0 else { throw WatchWireError.storage }
            let result = fsync(directory); Darwin.close(directory)
            guard result == 0 else { throw WatchWireError.storage }
            directoryURL.deleteLastPathComponent()
        }
        requiresDurabilityRetry = false
    }
    func bind(libraryID: String, epoch: UUID) throws {
        guard watchHashValid(libraryID) else { throw WatchWireError.invalid }
        let binding = WatchWireBinding(libraryID: libraryID, epoch: epoch)
        guard state.binding != binding else { return }
        var next = state; next.binding = binding; try commit(next)
    }
    func enqueue(_ command: WatchWireCommand, now: Date = .now) throws {
        guard now.timeIntervalSince1970.isFinite else { throw WatchWireError.clock }
        try command.validate()
        guard state.binding == WatchWireBinding(libraryID: command.libraryID, epoch: command.epoch) else { throw WatchWireError.binding }
        if let prior = state.pending.first(where: { $0.id == command.id }) {
            guard prior == command else { throw WatchWireError.invalid }
            try retryDurability()
            return
        }
        guard !state.completed.contains(where: { $0.ack.commandID == command.id }),
              !state.drafts.contains(where: { $0.id == command.id }) else { throw WatchWireError.invalid }
        guard state.pending.count < 256, state.pending.count + state.drafts.count < 512 else { throw WatchWireError.capacity }
        var next = state; next.pending.append(command)
        let expires = max(command.createdAt, min(now.addingTimeInterval(Self.deliveryLifetime), command.createdAt.addingTimeInterval(WatchWireCommand.maximumAge)))
        next.delivery?[command.id] = Delivery(createdAt: command.createdAt, expiresAt: expires,
            expired: now < command.createdAt || now >= expires || (state.lastObservedAt.map({ now < $0 }) ?? false))
        next.lastObservedAt = max(state.lastObservedAt ?? now, now)
        try commit(next)
    }
    @discardableResult func acknowledge(_ ack: WatchWireAck) throws -> Bool {
        guard let command = state.pending.first(where: { $0.id == ack.commandID }), ack.matches(command) else { return false }
        var next = state
        if case .refused = ack.result {
            let text: String?
            switch command.action { case .create(let value), .append(_, _, let value): text = value; case .setTask: text = nil }
            if let text {
                next.drafts.append(Draft(id: command.id, text: text))
            }
        }
        next.pending.removeAll { $0.id == command.id }
        next.delivery?.removeValue(forKey: command.id)
        next.completed.append(Completion(ack: ack, kind: command.kind))
        next.completed = Array(next.completed.suffix(64))
        try commit(next)
        return true
    }
    func recoverDraft(id: UUID, command: WatchWireCommand) throws {
        try command.validate()
        guard state.drafts.contains(where: { $0.id == id }), command.id != id,
              state.binding == WatchWireBinding(libraryID: command.libraryID, epoch: command.epoch),
              case .create = command.action,
              !state.pending.contains(where: { $0.id == command.id }),
              !state.completed.contains(where: { $0.ack.commandID == command.id }),
              !state.drafts.contains(where: { $0.id == command.id }) else { throw WatchWireError.invalid }
        guard state.pending.count < 256 else { throw WatchWireError.capacity }
        var next = state
        next.drafts.removeAll { $0.id == id }
        next.pending.append(command)
        let now = Date()
        let expires = max(command.createdAt, min(now.addingTimeInterval(Self.deliveryLifetime), command.createdAt.addingTimeInterval(WatchWireCommand.maximumAge)))
        next.delivery?[command.id] = Delivery(createdAt: command.createdAt, expiresAt: expires,
            expired: now < command.createdAt || now >= expires || (state.lastObservedAt.map({ now < $0 }) ?? false))
        next.lastObservedAt = max(state.lastObservedAt ?? now, now)
        try commit(next)
    }
    /// Move the original payload atomically; an already submitted transfer can still apply remotely.
    func keepPendingDictation(id: UUID) throws -> WatchWireCommand {
        guard let command = state.pending.first(where: { $0.id == id }) else { throw WatchWireError.invalid }
        let text: String
        switch command.action {
        case .create(let value), .append(_, _, let value): text = value
        case .setTask: throw WatchWireError.invalid
        }
        var next = state
        next.pending.removeAll { $0.id == id }
        next.delivery?.removeValue(forKey: id)
        next.drafts.append(Draft(id: id, text: text))
        try commit(next)
        return command
    }
    func updateDraft(id: UUID, text: String) throws {
        try retryDurability()
        guard let index = state.drafts.firstIndex(where: { $0.id == id }) else { throw WatchWireError.invalid }
        guard text.utf8.count <= 16_384, !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchWireError.invalid
        }
        guard state.drafts[index].text != text else { return }
        var next = state; next.drafts[index] = Draft(id: id, text: text); try commit(next)
    }
    func saveDraft(id: UUID, text: String) throws {
        if state.drafts.contains(where: { $0.id == id }) { try updateDraft(id: id, text: text); return }
        guard text.utf8.count <= 16_384, !text.contains("\0"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.pending.contains(where: { $0.id == id }), !state.completed.contains(where: { $0.ack.commandID == id }) else { throw WatchWireError.invalid }
        guard state.pending.count + state.drafts.count < 512 else { throw WatchWireError.capacity }
        var next = state; next.drafts.append(Draft(id: id, text: text)); try commit(next)
    }
    func delivery(for id: UUID) -> Delivery? { state.delivery?[id] }
    func mayDeliver(_ command: WatchWireCommand, now: Date) -> Bool {
        guard !requiresDurabilityRetry, state.binding?.libraryID == command.libraryID, let delivery = state.delivery?[command.id],
              delivery.createdAt == command.createdAt,
              !delivery.expired, now >= delivery.createdAt, now < delivery.expiresAt,
              state.lastObservedAt.map({ now >= $0 }) ?? true else { return false }
        return true
    }
    func updateDeliveryClock(now: Date = .now) throws {
        guard now.timeIntervalSince1970.isFinite else { throw WatchWireError.clock }
        guard !state.pending.isEmpty else { return }
        var next = state
        let rollback = state.lastObservedAt.map({ now < $0 }) ?? false
        for command in state.pending {
            if rollback || now >= (state.delivery?[command.id]?.expiresAt ?? .distantPast) {
                next.delivery?[command.id]?.expired = true
            }
        }
        next.lastObservedAt = max(state.lastObservedAt ?? now, now)
        try commit(next)
    }
    func renewDelivery(id: UUID, now: Date = .now) throws {
        guard now.timeIntervalSince1970.isFinite, state.lastObservedAt.map({ now >= $0 }) ?? true else { throw WatchWireError.clock }
        guard let command = state.pending.first(where: { $0.id == id }) else { throw WatchWireError.invalid }
        guard now >= command.createdAt else { throw WatchWireError.clock }
        var next = state
        let expires = min(now.addingTimeInterval(Self.deliveryLifetime), command.createdAt.addingTimeInterval(WatchWireCommand.maximumAge))
        next.delivery?[id] = Delivery(createdAt: command.createdAt, expiresAt: expires, expired: now >= expires || now < command.createdAt)
        next.lastObservedAt = now
        try commit(next)
    }
}
