// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import GRDB

/// A new publisher takes ownership of its container; older async results cannot take it back.
@MainActor final class MobileCardPublicationPublisher {
    struct Prepared {
        let snapshot: WidgetSnapshot
        fileprivate let epoch: UUID
        fileprivate let generation: UInt64
    }
    // File URL equality includes directory/trailing-slash representation, which can change
    // after the first write creates the container. Ownership is keyed by canonical path instead.
    private static var owners: [String: UUID] = [:]
    private weak var library: MobileLibrary?
    private let container: URL
    private let ownershipKey: String
    private let libraryID: String
    private var epoch = UUID()
    private var generation: UInt64 = 0
    /// A failed write may leave old text readable. Clear only after redaction or verified removal/unavailability.
    private(set) var needsScrub = true
    private let writeSnapshot: (WidgetSnapshot, URL) throws -> Void
    private let removeSnapshot: (URL) throws -> Void
    private let beforeBackgroundBuild: @Sendable () async throws -> Void
    private var backgroundPreparations: [UUID: Task<WidgetSnapshot, Error>] = [:]
    var hasBackgroundPreparations: Bool { !backgroundPreparations.isEmpty }

    /// Cancelling a host Task cannot interrupt an in-flight synchronous database read.
    /// Close/restore must await this barrier before tearing down the captured database.
    func waitForBackgroundPreparations() async {
        while !backgroundPreparations.isEmpty {
            let current = backgroundPreparations
            for (id, task) in current {
                _ = await task.result
                backgroundPreparations.removeValue(forKey: id)
            }
        }
    }

    init(library: MobileLibrary, container: URL, now: Date = .now,
         writeSnapshot: @escaping (WidgetSnapshot, URL) throws -> Void = { try $0.write(to: $1) },
         removeSnapshot: @escaping (URL) throws -> Void = { try MobileCardPublicationPublisher.removeSnapshotFile(in: $0) },
         beforeBackgroundBuild: @escaping @Sendable () async throws -> Void = {}) throws {
        self.library = library
        self.writeSnapshot = writeSnapshot
        self.removeSnapshot = removeSnapshot
        self.beforeBackgroundBuild = beforeBackgroundBuild
        let target = container.standardizedFileURL.resolvingSymlinksInPath()
        self.container = target
        ownershipKey = Self.containerKey(target)
        libraryID = MobileCardPublication.libraryID(for: library.paths)
        Self.owners[self.ownershipKey] = epoch
        guard try Self.scrubSnapshot(.locked(libraryID: libraryID, now: now), in: self.container,
            write: writeSnapshot, remove: removeSnapshot, ownsContainer: { Self.owners[self.ownershipKey] == self.epoch }) else {
            throw WidgetSnapshot.Invalid.publication
        }
        needsScrub = false
    }

    /// Call synchronously BEFORE privacy/library transitions, then invalidate widget timelines.
    @discardableResult func scrub(now: Date = .now) throws -> Bool {
        guard Self.owners[ownershipKey] == epoch else { return false }
        epoch = UUID()
        Self.owners[ownershipKey] = epoch
        needsScrub = true // Invalidate first, even when the filesystem refuses the cleanup.
        guard try Self.scrubSnapshot(.locked(libraryID: libraryID, now: now), in: container,
            write: writeSnapshot, remove: removeSnapshot, ownsContainer: { Self.owners[self.ownershipKey] == self.epoch }) else { return false }
        needsScrub = false
        return true
    }

    /// Startup uses the same write-or-unlink contract and fences any prior in-process publisher.
    static func scrubForStartup(in container: URL, now: Date = .now,
        writeSnapshot: (WidgetSnapshot, URL) throws -> Void = { try $0.write(to: $1) },
        removeSnapshot: (URL) throws -> Void = { try MobileCardPublicationPublisher.removeSnapshotFile(in: $0) }) throws {
        let target = container.standardizedFileURL.resolvingSymlinksInPath()
        let key = containerKey(target), owner = UUID()
        owners[key] = owner
        guard try scrubSnapshot(.locked(libraryID: "startup", now: now), in: target,
            write: writeSnapshot, remove: removeSnapshot, ownsContainer: { owners[key] == owner }) else {
            throw WidgetSnapshot.Invalid.publication
        }
    }

    private static func containerKey(_ container: URL) -> String {
        var path = container.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func scrubSnapshot(_ snapshot: WidgetSnapshot, in container: URL,
        write: (WidgetSnapshot, URL) throws -> Void, remove: (URL) throws -> Void,
        ownsContainer: () -> Bool) throws -> Bool {
        guard ownsContainer() else { return false }
        do { try write(snapshot, container) }
        catch {
            // An older/reentrant owner must never unlink the replacement owner's publication.
            guard ownsContainer() else { return false }
            try remove(container)
            try verifySnapshotUnavailable(in: container)
        }
        return ownsContainer()
    }

    /// Only unlink the known final entry. Never traverse a symlinked Card directory or remove a tree.
    static func removeSnapshotFile(in container: URL) throws {
        _ = try withSnapshotParent(in: container) { parent, filename in
            if unlinkat(parent, filename, 0) != 0 {
                let code = errno
                guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            } else if fsync(parent) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func verifySnapshotUnavailable(in container: URL) throws {
        _ = try withSnapshotParent(in: container) { parent, filename in
            var info = stat()
            guard fstatat(parent, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 else { throw CocoaError(.fileWriteUnknown) }
            let code = errno
            guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
    }

    private static func withSnapshotParent<T>(in container: URL, _ body: (Int32, String) throws -> T) throws -> T? {
        let root = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if root < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { close(root) }
        let parts = WidgetSnapshot.relativePath.split(separator: "/").map(String.init)
        precondition(parts.count == 2 && !parts.contains(".."))
        let parent = openat(root, parts[0], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 {
            let code = errno
            if code == ENOENT { return nil }
            if code == ENOTDIR {
                var entry = stat()
                if fstatat(root, parts[0], &entry, AT_SYMLINK_NOFOLLOW) == 0,
                   entry.st_mode & S_IFMT != S_IFDIR, entry.st_mode & S_IFMT != S_IFLNK {
                    // A regular blocker cannot contain a snapshot; preserve that unrelated entry.
                    return nil
                }
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { close(parent) }
        return try body(parent, parts[1])
    }

    private func reserveGeneration() throws -> (MobileLibrary, UUID, UInt64) {
        guard Self.owners[ownershipKey] == epoch, !needsScrub, let library,
              !library.isClosed, !library.isClosing else { throw WidgetSnapshot.Invalid.publication }
        // Newer work supersedes earlier work immediately, even if its build later fails.
        if generation == .max {
            epoch = UUID(); Self.owners[ownershipKey] = epoch; generation = 0
        }
        generation += 1
        return (library, epoch, generation)
    }

    func prepare(now: Date = .now, calendar: Calendar = .current,
                 configuredNoteIDs: Set<String> = [], configuredTagIDs: Set<String> = []) throws -> Prepared {
        let (library, reservedEpoch, reservedGeneration) = try reserveGeneration()
        return Prepared(snapshot: try MobileCardPublication.make(library: library, now: now, calendar: calendar,
            configuredNoteIDs: configuredNoteIDs, configuredTagIDs: configuredTagIDs),
            epoch: reservedEpoch, generation: reservedGeneration)
    }

    func prepareInBackground(now: Date = .now, calendar: Calendar = .current,
                 configuredNoteIDs: Set<String> = [], configuredTagIDs: Set<String> = []) async throws -> Prepared {
        try Task.checkCancellation()
        let (library, reservedEpoch, reservedGeneration) = try reserveGeneration()
        let store = library.store, database = library.database, paths = library.paths
        let appLockEnabled = library.appLockEnabled, beforeBuild = beforeBackgroundBuild
        let id = UUID()
        let worker = Task.detached(priority: .utility) {
            try await beforeBuild()
            try Task.checkCancellation()
            let snapshot = try MobileCardPublication.make(store: store, database: database, paths: paths,
                appLockEnabled: appLockEnabled, now: now, calendar: calendar,
                configuredNoteIDs: configuredNoteIDs, configuredTagIDs: configuredTagIDs)
            try Task.checkCancellation()
            return snapshot
        }
        backgroundPreparations[id] = worker
        defer { backgroundPreparations.removeValue(forKey: id) }
        let snapshot = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard Self.owners[ownershipKey] == reservedEpoch, epoch == reservedEpoch,
              generation == reservedGeneration, !needsScrub,
              !library.isClosed, !library.isClosing,
              !library.appLockEnabled || snapshot.redacted else { throw WidgetSnapshot.Invalid.publication }
        return Prepared(snapshot: snapshot, epoch: reservedEpoch, generation: reservedGeneration)
    }

    @discardableResult func publish(_ prepared: Prepared) throws -> Bool {
        guard Self.owners[ownershipKey] == epoch, prepared.epoch == epoch, !needsScrub,
              prepared.generation == generation,
              prepared.snapshot.libraryID == libraryID, let library, !library.isClosed, !library.isClosing else { return false }
        let eligible: Bool
        do { eligible = try stillEligible(prepared.snapshot, library: library) }
        catch {
            _ = try? scrub(now: prepared.snapshot.generatedAt)
            throw error
        }
        if (library.appLockEnabled && !prepared.snapshot.redacted) || !eligible {
            try scrub(now: prepared.snapshot.generatedAt)
            return false
        }
        do { try writeSnapshot(prepared.snapshot, container) }
        catch {
            // Best effort only: failure still propagates, and failed cleanup remains pending.
            _ = try? scrub(now: prepared.snapshot.generatedAt)
            throw error
        }
        return true
    }

    @discardableResult func refresh(now: Date = .now, calendar: Calendar = .current,
        configuredNoteIDs: Set<String> = [], configuredTagIDs: Set<String> = []) throws -> Bool {
        guard try scrub(now: now) else { return false }
        return try publish(prepare(now: now, calendar: calendar,
            configuredNoteIDs: configuredNoteIDs, configuredTagIDs: configuredTagIDs))
    }

    private func stillEligible(_ snapshot: WidgetSnapshot, library: MobileLibrary) throws -> Bool {
        let cards = snapshot.pinned + snapshot.inbox + snapshot.tags.flatMap(\.notes)
            + snapshot.configuredPins + snapshot.configuredTags.flatMap(\.notes)
            + (snapshot.lastOpened.map { [$0] } ?? [])
        let ids = Set(cards.map(\.id) + snapshot.nextUp.compactMap(\.noteId))
        let configuredPins = Set(snapshot.configuredPins.map(\.id))
        return try library.database.pool.read { db in
            for id in ids {
                guard let row = try Row.fetchOne(db, sql: "SELECT isLocked,location,deletedAt,isPinnedGlobal FROM note WHERE id=?", arguments: [id]),
                      row["isLocked"] as Bool == false, row["location"] as String == "notes",
                      row["deletedAt"] as Date? == nil else { return false }
                if configuredPins.contains(id), row["isPinnedGlobal"] as Bool == false,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM note_pin WHERE noteId=?)", arguments: [id]) != true { return false }
            }
            return true
        }
    }
}
