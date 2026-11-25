// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Darwin
import GRDB

/// The caller must stop all journal writers and obtain explicit confirmation before calling confirm.
/// This type never deletes journal bytes. Its private receipt contains file identity metadata only.
public enum JournalQuarantine {
    public static func confirmationMessage(base: String, includesUnavailableKeyFiles: Bool) -> String {
        guard includesUnavailableKeyFiles else { return base }
        return base + " These files stay encrypted. If the notes key arrives later, Theo Notes cannot recover them automatically. If another device still has your notes password, keep waiting."
    }
    public enum Failure: Error { case invalidPath, changed, io }
    fileprivate struct Identity: Codable, Equatable, Sendable {
        let device: UInt64, inode: UInt64, size: Int64, seconds: Int64, nanos: Int64
    }
    fileprivate struct Entry: Codable, Sendable { let name: String; let identity: Identity; var damagedMarker: Bool? = nil; var boundMarker: Bool? = nil }
    fileprivate struct VariantBinding: Codable, Sendable { let sourceID: String, markerName: String; let movedAside: Bool; let sources: [String]; let aborted: String? }
    private struct Receipt: Codable, Sendable { let version: Int; let entries: [Entry]; var variant: VariantBinding? = nil }
    public struct Selection: Sendable {
        fileprivate let root: URL
        fileprivate let entries: [Entry]
        fileprivate var variant: VariantBinding? = nil
        fileprivate var variantFence: NoteSessionFence? = nil
        /// Notes whose files move with a damaged aborted marker; never while one has a live session.
        fileprivate var abortedNoteIDs: Set<String> = []
    }
    public struct Confirmation: Sendable {
        fileprivate let root: URL
        public let directory: URL
        fileprivate var variantFence: NoteSessionFence? = nil
    }

    /// Capture the exact file identities shown to the person for confirmation.
    public static func inspect(libraryRoot: URL, fileNames: [String]) throws -> Selection {
        let root = libraryRoot.standardizedFileURL
        try requireDirectory(root)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try requireDirectory(journal)
        guard !fileNames.isEmpty, Set(fileNames).count == fileNames.count else { throw Failure.invalidPath }
        let entries = try fileNames.map { name in
            guard validName(name) else { throw Failure.invalidPath }
            return Entry(name: name, identity: try identity(journal.appendingPathComponent(name)))
        }
        return Selection(root: root, entries: entries)
    }

    /// Only structurally damaged confirmation markers may be moved, under the caller's writer fence.
    public static func inspectDamagedMarker(libraryRoot: URL, fileName: String) throws -> Selection {
        let root = libraryRoot.standardizedFileURL
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try requireDirectory(root); try requireDirectory(journal)
        guard validMarkerName(fileName) else { throw Failure.invalidPath }
        let url = journal.appendingPathComponent(fileName)
        let captured = try identity(url)
        guard try damagedMarker(url) else { throw Failure.invalidPath }
        guard try identity(url) == captured else { throw Failure.changed }
        return Selection(root: root, entries: [Entry(name: fileName, identity: captured, damagedMarker: true)])
    }

    /// Select only a valid interrupted variant marker and its exact remaining base files.
    @MainActor public static func inspectVariantFallback(store: NoteStore, markerName: String) throws -> Selection {
        let root = store.paths.root.standardizedFileURL, directory = store.paths.journal.standardizedFileURL
        guard directory == root.appendingPathComponent("Journal"), validVariantMarkerName(markerName) else { throw Failure.invalidPath }
        let markerURL = directory.appendingPathComponent(markerName), markerIdentity = try identity(markerURL)
        let bytes = try JournalRecoveryFiles.readRegular(markerURL, failure: Failure.invalidPath)
        let proof = try store.db.pool.read { try JournalVariantRecovery.quarantineBinding(data: bytes, name: markerName, directory: directory, db: $0) }
        guard try identity(markerURL) == markerIdentity else { throw Failure.changed }
        // A valid, readable group of at most four must take the normal recovery path.
        if proof.sources.count <= 4 {
            var damaged = false
            for name in proof.sources {
                let data = try JournalRecoveryFiles.readRegular(directory.appendingPathComponent(name), failure: Failure.invalidPath)
                if data.starts(with: Data("BJB1:".utf8)) { throw JournalProtectionError.keyRequired }
                guard let base = try? JSONDecoder().decode(JournalBase.self, from: data), base.v == EditJournal.formatVersion else { damaged = true; continue }
            }
            guard damaged else { throw Failure.invalidPath }
        }
        let binding = VariantBinding(sourceID: proof.id, markerName: markerName, movedAside: proof.movedAside, sources: proof.sources, aborted: proof.aborted)
        var entries = try proof.sources.map { name in Entry(name: name, identity: try identity(directory.appendingPathComponent(name))) }
        if let aborted = proof.aborted { entries.append(Entry(name: aborted, identity: try identity(directory.appendingPathComponent(aborted)), boundMarker: true)) }
        entries.append(Entry(name: markerName, identity: markerIdentity, boundMarker: true))
        let fence = NoteSession.captureSessionFence(journalDirectory: directory, noteIDs: [proof.id])
        return Selection(root: root, entries: entries, variant: binding, variantFence: fence)
    }

    @MainActor public static func confirmVariantFallback(_ selection: Selection, store: NoteStore) throws -> Confirmation {
        guard let binding = selection.variant, let fence = selection.variantFence,
              selection.root == store.paths.root.standardizedFileURL else { throw Failure.invalidPath }
        return try store.db.pool.write { db in
            try validateVariant(binding, entries: selection.entries, root: selection.root, db: db, destination: nil)
            guard NoteSession.captureSessionFence(journalDirectory: store.paths.journal, noteIDs: [binding.sourceID]) == fence else { throw Failure.changed }
            var confirmation = try confirmImpl(selection)
            confirmation.variantFence = fence
            return confirmation
        }
    }

    /// One entry for a blocking marker's exit: an interrupted variant marker whose remaining
    /// bases need Move aside (N9), otherwise a structurally damaged marker (S2).
    @MainActor public static func inspectMarker(store: NoteStore, markerName: String) throws -> Selection {
        if markerName.hasPrefix(".variant-confirm-"), let selection = try? inspectVariantFallback(store: store, markerName: markerName) { return selection }
        let marker = try inspectDamagedMarker(libraryRoot: store.paths.root, fileName: markerName)
        guard markerName.hasPrefix(".variant-aborted-") else { return marker }
        // A damaged aborted marker names no files: it moves with every file of its note.
        let journal = store.paths.journal, hash = String(markerName.dropFirst(".variant-aborted-".count).dropLast(5))
        var ids: Set<String> = [], names: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: journal.path).sorted() where validName(name) {
            let id = String(name[..<(name.range(of: ".jsonl") ?? name.range(of: ".base")!).lowerBound])
            guard SHA256.hash(data: Data(id.utf8)).map({ String(format: "%02x", $0) }).joined() == hash else { continue }
            ids.insert(id); names.append(name)
        }
        guard NoteSession.liveSessionIDs(journalDirectory: journal).isDisjoint(with: ids) else { throw Failure.changed }
        var selection = Selection(root: marker.root, entries: try names.map { Entry(name: $0, identity: try identity(journal.appendingPathComponent($0))) } + marker.entries)
        selection.abortedNoteIDs = ids
        return selection
    }

    /// Invoke only for the selection the person just confirmed; returns the folder it went to.
    @MainActor public static func moveAfterConfirmation(_ selection: Selection, store: NoteStore) throws -> URL {
        guard selection.variant != nil else {
            guard NoteSession.liveSessionIDs(journalDirectory: store.paths.journal).isDisjoint(with: selection.abortedNoteIDs) else { throw Failure.changed }
            let confirmation = try confirm(selection); try resume(confirmation); return confirmation.directory
        }
        let confirmation = try confirmVariantFallback(selection, store: store)
        try resumeVariantFallback(confirmation, store: store)
        return confirmation.directory
    }

    /// Restart: finish a confirmed move; a variant move never closes a live session here.
    @MainActor public static func resumeConfirmed(_ confirmation: Confirmation, store: NoteStore) throws {
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: confirmation.directory.appendingPathComponent(".confirmation.json")))
        if receipt.variant != nil { try resumeVariantFallbackAutomatically(confirmation, store: store) } else { try resume(confirmation) }
    }

    /// Invoke only for the precise selection the person just confirmed.
    public static func confirm(_ selection: Selection) throws -> Confirmation {
        guard selection.variant == nil else { throw Failure.invalidPath }
        return try confirmImpl(selection)
    }
    private static func confirmImpl(_ selection: Selection) throws -> Confirmation {
        let journal = selection.root.appendingPathComponent("Journal", isDirectory: true)
        try requireDirectory(selection.root); try requireDirectory(journal)
        for entry in selection.entries {
            guard try identity(journal.appendingPathComponent(entry.name)) == entry.identity else { throw Failure.changed }
            if entry.damagedMarker == true {
                guard try damagedMarker(journal.appendingPathComponent(entry.name)),
                      try identity(journal.appendingPathComponent(entry.name)) == entry.identity else { throw Failure.changed }
            }
        }
        let recovery = selection.root.appendingPathComponent("Recovery", isDirectory: true)
        let quarantine = recovery.appendingPathComponent("Quarantine", isDirectory: true)
        try createPrivateDirectory(recovery); try syncDirectory(selection.root)
        try createPrivateDirectory(quarantine); try syncDirectory(recovery)
        // Ruling 8 / N1: `<UTC timestamp>-<short uuid>`, sortable and still unique.
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withFullDate, .withTime, .withTimeZone])
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        let directory = quarantine.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try createPrivateDirectory(directory)
        let receipt = Receipt(version: 1, entries: selection.entries, variant: selection.variant)
        let url = directory.appendingPathComponent(".confirmation.json")
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize(); try file.close()
        try syncDirectory(directory); try syncDirectory(quarantine)
        return Confirmation(root: selection.root, directory: directory)
    }

    /// Re-open a previously confirmed operation after process restart.
    public static func confirmed(libraryRoot: URL, directory: URL) throws -> Confirmation {
        let root = libraryRoot.standardizedFileURL, dir = directory.standardizedFileURL
        let parent = root.appendingPathComponent("Recovery/Quarantine", isDirectory: true)
        // Older confirmations used a bare UUID; both forms resume.
        guard dir.deletingLastPathComponent() == parent, UUID(uuidString: dir.lastPathComponent) != nil ||
                dir.lastPathComponent.wholeMatch(of: /\d{8}T\d{6}Z-[0-9a-f]{8}/) != nil else { throw Failure.invalidPath }
        try requireDirectory(root); try requireDirectory(root.appendingPathComponent("Journal"))
        try requireDirectory(root.appendingPathComponent("Recovery")); try requireDirectory(parent); try requireDirectory(dir)
        return Confirmation(root: root, directory: dir)
    }

    public static func resume(_ confirmation: Confirmation) throws { try resume(confirmation, afterMove: { _ in }) }

    static func resume(_ confirmation: Confirmation, afterMove: (Int) throws -> Void) throws {
        try resumeImpl(confirmation, allowVariant: false, afterMove: afterMove)
    }
    @MainActor public static func resumeVariantFallback(_ confirmation: Confirmation, store: NoteStore) throws {
        try resumeVariantFallback(confirmation, store: store, afterMove: { _ in })
    }
    @MainActor static func resumeVariantFallback(_ confirmation: Confirmation, store: NoteStore, afterMove: (Int) throws -> Void) throws {
        try resumeVariantFallbackImpl(confirmation, store: store, automatic: false, afterMove: afterMove)
    }
    /// Restart-only path: never closes a retained session or resumes an unknown receipt.
    @MainActor public static func resumeVariantFallbackAutomatically(_ confirmation: Confirmation, store: NoteStore) throws {
        try resumeVariantFallbackImpl(confirmation, store: store, automatic: true, afterMove: { _ in })
    }
    @MainActor private static func resumeVariantFallbackImpl(_ confirmation: Confirmation, store: NoteStore, automatic: Bool, afterMove: (Int) throws -> Void) throws {
        let operation = try confirmed(libraryRoot: confirmation.root, directory: confirmation.directory)
        guard operation.root == store.paths.root.standardizedFileURL else { throw Failure.invalidPath }
        let receiptURL = operation.directory.appendingPathComponent(".confirmation.json")
        let receiptIdentity = try identity(receiptURL)
        let receiptBytes = try JournalRecoveryFiles.readRegular(receiptURL, failure: Failure.invalidPath)
        let receipt = try JSONDecoder().decode(Receipt.self, from: receiptBytes)
        try validateReceipt(receipt, allowVariant: true)
        guard let binding = receipt.variant else { throw Failure.invalidPath }
        try store.db.pool.write { db in
            guard try identity(receiptURL) == receiptIdentity,
                  try JournalRecoveryFiles.readRegular(receiptURL, failure: Failure.invalidPath) == receiptBytes else { throw Failure.changed }
            try validateReceipt(receipt, allowVariant: true)
            try validateVariant(binding, entries: receipt.entries, root: operation.root, db: db, destination: operation.directory)
            if automatic {
                guard !NoteSession.liveSessionIDs(journalDirectory: store.paths.journal).contains(binding.sourceID) else { throw Failure.changed }
            } else {
                guard let fence = confirmation.variantFence else { throw Failure.changed }
                try NoteSession.invalidateSessions(journalDirectory: store.paths.journal, noteIDs: [binding.sourceID], matching: fence)
            }
            try resumeImpl(operation, allowVariant: true, afterMove: afterMove)
        }
    }
    private static func resumeImpl(_ confirmation: Confirmation, allowVariant: Bool, afterMove: (Int) throws -> Void) throws {
        let operation = try confirmed(libraryRoot: confirmation.root, directory: confirmation.directory)
        let receiptURL = operation.directory.appendingPathComponent(".confirmation.json")
        _ = try identity(receiptURL)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        try validateReceipt(receipt, allowVariant: allowVariant)
        let completed = operation.directory.appendingPathComponent(".completed")
        if try optionalIdentity(completed) != nil {
            guard try Data(contentsOf: completed) == Data("complete-v1".utf8) else { throw Failure.changed }
            return
        }
        let journal = operation.root.appendingPathComponent("Journal", isDirectory: true)
        for (index, entry) in receipt.entries.enumerated() {
            let source = journal.appendingPathComponent(entry.name)
            let dest = operation.directory.appendingPathComponent(entry.name)
            let existingSource = try optionalIdentity(source), existingDest = try optionalIdentity(dest)
            if existingSource == nil, existingDest == entry.identity { continue }
            guard existingSource == entry.identity, existingDest == nil else { throw Failure.changed }
            if entry.damagedMarker == true {
                guard try damagedMarker(source), try identity(source) == entry.identity else { throw Failure.changed }
            }
            // No replacement, even if a destination appears after the identity check.
            guard renamex_np(source.path, dest.path, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
            try syncDirectory(journal); try syncDirectory(operation.directory)
            try afterMove(index)
        }
        try Data("complete-v1".utf8).write(to: completed, options: .atomic)
        let marker = try FileHandle(forWritingTo: completed)
        try marker.synchronize(); try marker.close()
        try syncDirectory(operation.directory)
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") &&
            (name.contains(".jsonl") || name.contains(".base"))
    }
    private static func validateReceipt(_ receipt: Receipt, allowVariant: Bool) throws {
        guard receipt.version == 1, (receipt.variant != nil) == allowVariant, !receipt.entries.isEmpty,
              Set(receipt.entries.map(\.name)).count == receipt.entries.count,
              receipt.entries.allSatisfy({ entry in
                  if entry.boundMarker == true { return allowVariant && entry.damagedMarker != true && validBoundMarkerName(entry.name) }
                  if entry.damagedMarker == true { return !allowVariant && validMarkerName(entry.name) }
                  return validName(entry.name)
              }) else { throw Failure.invalidPath }
    }
    private static func validMarkerName(_ name: String) -> Bool {
        for prefix in [".retirement-", ".variant-confirm-", ".discard-", ".variant-aborted-"] where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let hex = name.dropFirst(prefix.count).dropLast(5)
            return hex.utf8.count == 64 && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return false
    }
    private static func validVariantMarkerName(_ name: String) -> Bool {
        name.hasPrefix(".variant-confirm-") && validMarkerName(name)
    }
    private static func validBoundMarkerName(_ name: String) -> Bool {
        if validVariantMarkerName(name) { return true }
        let prefix = ".variant-aborted-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
        let hex = name.dropFirst(prefix.count).dropLast(5)
        return hex.utf8.count == 64 && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validateVariant(_ binding: VariantBinding, entries: [Entry], root: URL, db: Database, destination: URL?) throws {
        let directory = root.appendingPathComponent("Journal")
        guard validVariantMarkerName(binding.markerName), !binding.sources.isEmpty,
              Set(binding.sources).count == binding.sources.count,
              let markerEntry = entries.first(where: { $0.name == binding.markerName && $0.boundMarker == true }) else { throw Failure.invalidPath }
        let expectedNames = binding.sources + (binding.aborted.map { [$0] } ?? []) + [binding.markerName]
        guard entries.map(\.name) == expectedNames else { throw Failure.changed }
        func current(_ entry: Entry) throws -> URL {
            let source = directory.appendingPathComponent(entry.name)
            if let found = try optionalIdentity(source) {
                guard found == entry.identity else { throw Failure.changed }
                if let destination, try optionalIdentity(destination.appendingPathComponent(entry.name)) != nil { throw Failure.changed }
                return source
            }
            guard let destination else { throw Failure.changed }
            let saved = destination.appendingPathComponent(entry.name)
            guard try optionalIdentity(saved) == entry.identity else { throw Failure.changed }
            return saved
        }
        for entry in entries { _ = try current(entry) }
        let markerPath = try current(markerEntry)
        let markerData = try JournalRecoveryFiles.readRegular(markerPath, failure: Failure.invalidPath)
        let proof = try JournalVariantRecovery.quarantineBinding(data: markerData, name: binding.markerName, directory: directory, db: db, allowMoved: destination != nil)
        guard proof.id == binding.sourceID, proof.movedAside == binding.movedAside, proof.aborted == binding.aborted,
              Set(binding.sources).isSubset(of: Set(proof.allSources)), Set(proof.sources).isSubset(of: Set(binding.sources)) else { throw Failure.changed }
        if let aborted = binding.aborted {
            guard let entry = entries.first(where: { $0.name == aborted && $0.boundMarker == true }),
                  try Data(contentsOf: current(entry)) == proof.abortedBytes else { throw Failure.changed }
        }
    }
    private static func damagedMarker(_ url: URL) throws -> Bool {
        let bytes = try JournalRecoveryFiles.readRegular(url, failure: Failure.invalidPath, tooLarge: Failure.invalidPath)
        let name = url.lastPathComponent, directory = url.deletingLastPathComponent()
        if name.hasPrefix(".retirement-") { return MissingJournalRecovery.isDamagedMarker(bytes, name: name, directory: directory) }
        if name.hasPrefix(".discard-") { return MissingJournalRecovery.isDamagedDiscardMarker(bytes, name: name, directory: directory) }
        if name.hasPrefix(".variant-aborted-") { return JournalVariantRecovery.isDamagedAbortedMarker(bytes, name: name, directory: directory) }
        return JournalVariantRecovery.isDamagedMarker(bytes, name: url.lastPathComponent, directory: url.deletingLastPathComponent())
    }
    private static func identity(_ url: URL) throws -> Identity {
        let info = try JournalRecoveryFiles.identity(url, failure: Failure.invalidPath)
        return Identity(device: info.device, inode: info.inode, size: info.size, seconds: info.seconds, nanos: info.nanos)
    }
    private static func optionalIdentity(_ url: URL) throws -> Identity? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw Failure.io }
        return try identity(url)
    }
    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.invalidPath }
    }
    private static func createPrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw Failure.io }
        try requireDirectory(url)
    }
    private static func syncDirectory(_ url: URL) throws {
        try JournalRecoveryFiles.syncDirectory(url, failure: Failure.io)
    }

}
