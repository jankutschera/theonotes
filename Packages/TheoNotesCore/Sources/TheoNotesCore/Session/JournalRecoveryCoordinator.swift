// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB

/// Shared recovery execution; callers provide all live session IDs and run under their
/// platform's admission fence. Core actions independently revalidate their writer proofs.
@MainActor public enum JournalRecoveryCoordinator {
    public enum KeyState: Sendable, Equatable { case unlockRequired, waitingForSyncKey }
    public struct Single: Sendable {
        public let sourceID: String
        public let suffix: String
        public let note: Note
        public let retirement: MissingJournalRecovery.Retirement
    }
    public struct Variants: Sendable {
        public let sourceID: String
        public let notes: [Note]
        public let sourceMustExist: Bool
        public let retirement: JournalVariantRecovery.Retirement
    }
    public struct Report: Sendable {
        public var singles: [Single] = []
        public var variants: [Variants] = []
        public var quarantineFiles: [String] = []
        public var keyUnavailableFiles: [String] = []
        public var keyState: KeyState?
        public var hasUncommittedRecovery = false
        public var cleanupPending = false
        public var variantMarkerNeedsAttention = false
        public var failedSourceIDs: [String] = []
        public var unassociatedMarkers: [String] = []
        /// Markers with a byte-preserving Move aside exit (S2/N9).
        public var markerMoves: [String] = []
    }

    public static func recover(store: NoteStore, access: LockedNoteAccess?, liveSessionIDs: Set<String>,
                               dirtyLiveSessionIDs: Set<String>, existingReplayFailureIDs: Set<String> = [],
                               allowSealedMoveAside: Bool = false) throws -> Report {
        let directory = store.paths.journal
        // Snapshot the registry again immediately before synchronous resumption. The host
        // passes its snapshot too; unioning cannot accidentally unprotect a stale holder.
        let liveSessionIDs = liveSessionIDs.union(NoteSession.liveSessionIDs(journalDirectory: directory))
        let privacy = NotePrivacy(store: store)
        let protection: JournalRecoveryScan.Protection
        if access != nil { protection = .unlocked }
        else if try privacy.hasPassword { protection = .locked }
        else if try !store.canRecoverMissingJournalPlain() { protection = .waitingForSyncKey }
        else { protection = .unprotected }
        func missingKeyState() -> KeyState { protection == .waitingForSyncKey || protection == .unprotected ? .waitingForSyncKey : .unlockRequired }
        var report = Report()
        do {
            let skipped = try JournalVariantRecovery.finishPending(store: store, access: access, excluding: liveSessionIDs)
            if !skipped.isEmpty { report.variantMarkerNeedsAttention = true }
        } catch { report.variantMarkerNeedsAttention = true }
        do {
            let skipped = try MissingJournalRecovery.finishRetirements(directory: directory, store: store,
                                                                        access: access, excluding: liveSessionIDs)
            if !skipped.isEmpty { report.cleanupPending = true }
        } catch JournalProtectionError.keyRequired {
            report.cleanupPending = true; report.keyState = missingKeyState()
        } catch {
            report.cleanupPending = true; report.hasUncommittedRecovery = true
        }
        let existing = try store.db.pool.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM note")) }
        let inventory = try JournalRecoveryScan.inventory(directory: directory, existingNoteIDs: existing, liveSessionIDs: liveSessionIDs)
        let classified = JournalRecoveryScan.classify(inventory, directory: directory, protection: protection,
                                                       access: access, dirtyLiveSessionIDs: dirtyLiveSessionIDs)
        report.unassociatedMarkers = classified.unassociatedMarkers
        var quarantine: Set<String> = []
        let markerNames = Set(inventory.markers)
        let candidateIDs = existing.union(inventory.groups.map(\.sourceID))
        let abortedIDs = Set(candidateIDs.filter { id in
            let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            return markerNames.contains(".variant-aborted-" + hash + ".json")
        })
        for group in classified.groups {
            // Aborted sources use a separate marker-bound proof below, never normal replay.
            if abortedIDs.contains(group.sourceID) { continue }
            // A variant marker fences replay of its own note. Its committed variants must
            // not turn a retained holder into a global sync block for unrelated notes.
            if !group.markerNames.isEmpty && group.markerNames.allSatisfy({
                $0.hasPrefix(".variant-confirm-") || $0.hasPrefix(".variant-aborted-")
            }) {
                report.variantMarkerNeedsAttention = true
                continue
            }
            if group.blockers.contains(.unlockRequired) { report.keyState = .unlockRequired }
            if group.blockers.contains(.waitingForSyncKey), report.keyState == nil { report.keyState = .waitingForSyncKey }
            if allowSealedMoveAside, access == nil, (protection == .unprotected || protection == .waitingForSyncKey),
               !group.sourceExists, !group.hasLiveSession, group.blockers.contains(.waitingForSyncKey),
               let files = inventory.groups.first(where: { $0.sourceID == group.sourceID })?.files {
                do {
                    var hasSealed = false, allSealed = true
                    for file in files {
                        let bytes = try JournalRecoveryFiles.readRegular(directory.appendingPathComponent(file.name), failure: CocoaError(.fileReadUnknown))
                        let sealed: Bool
                        if file.kind == .base { sealed = bytes.starts(with: Data("BJB1:".utf8)) }
                        else {
                            let lines = bytes.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }
                            sealed = !lines.isEmpty && lines.allSatisfy { $0.starts(with: Data("BJE1:".utf8)) }
                        }
                        hasSealed = hasSealed || sealed
                        if !sealed && !(file.kind == .journal && bytes.isEmpty) { allSealed = false }
                    }
                    if hasSealed && allSealed {
                        quarantine.formUnion(files.map(\.name))
                        report.keyUnavailableFiles.append(contentsOf: files.map(\.name))
                    }
                } catch { report.failedSourceIDs.append(group.sourceID) }
            }
            if group.blockers.contains(.activeSession) && !group.sourceExists {
                // Do not open, rewrite or detach a journal held by any live session.
                if dirtyLiveSessionIDs.contains(group.sourceID) || !(inventory.groups.first(where: { $0.sourceID == group.sourceID })?.files.isEmpty ?? true) {
                    report.hasUncommittedRecovery = true
                }
                continue
            }
            if group.blockers.contains(.pendingMarker) {
                report.variantMarkerNeedsAttention = true
                continue
            }
            if group.blockers.contains(.unavailable) {
                report.failedSourceIDs.append(group.sourceID)
                if !group.sourceExists { report.hasUncommittedRecovery = true }
                continue
            }
            if group.sourceExists, !group.hasLiveSession,
               let rawGroup = inventory.groups.first(where: { $0.sourceID == group.sourceID }),
               rawGroup.files.contains(where: { !$0.suffix.isEmpty }),
               !group.blockers.contains(.unlockRequired), !group.blockers.contains(.waitingForSyncKey) {
                do {
                    let saved = try JournalVariantRecovery.recoverMovedAside(noteId: group.sourceID, store: store, access: access)
                    report.variants.append(.init(sourceID: group.sourceID, notes: saved.notes, sourceMustExist: true, retirement: saved.retirement))
                } catch JournalVariantRecovery.Failure.requiresKey {
                    report.keyState = missingKeyState(); report.hasUncommittedRecovery = true
                } catch {
                    // The filtered classifier rejects canonical files and incomplete selections.
                    // A readable pair is never quarantined merely because its commit failed.
                    let movedNames = rawGroup.files.filter { !$0.suffix.isEmpty }.map(\.name)
                    do {
                        switch try JournalQuarantineEligibility.assessMovedAside(noteId: group.sourceID, directory: directory,
                                                                                fileNames: movedNames, access: access) {
                        case let .eligible(_, names): quarantine.formUnion(names)
                        case .requiresKey: report.keyState = missingKeyState()
                        case .none, .recoverablePlain: report.failedSourceIDs.append(group.sourceID)
                        }
                    } catch { report.failedSourceIDs.append(group.sourceID) }
                    report.hasUncommittedRecovery = true
                }
                continue
            }
            guard group.blockers.isEmpty else {
                if !group.sourceExists { report.hasUncommittedRecovery = true }
                continue
            }
            do {
                switch group.disposition {
                case .none: break
                case let .single(suffix):
                    let saved = try MissingJournalRecovery.recover(noteId: group.sourceID, directory: directory, suffix: suffix, store: store, access: access)
                    report.singles.append(.init(sourceID: group.sourceID, suffix: suffix, note: saved.note, retirement: saved.retirement))
                case .variants:
                    let saved = try JournalVariantRecovery.recover(noteId: group.sourceID, store: store, access: access)
                    report.variants.append(.init(sourceID: group.sourceID, notes: saved.notes, sourceMustExist: false, retirement: saved.retirement))
                    let original = Set(inventory.groups.first(where: { $0.sourceID == group.sourceID })?.files.map(\.name) ?? [])
                    if !original.subtracting(saved.sourceNames).isEmpty { report.hasUncommittedRecovery = true }
                case .existingMovedAside:
                    let saved = try JournalVariantRecovery.recoverMovedAside(noteId: group.sourceID, store: store, access: access)
                    report.variants.append(.init(sourceID: group.sourceID, notes: saved.notes, sourceMustExist: true, retirement: saved.retirement))
                case let .quarantine(_, names):
                    quarantine.formUnion(names); report.hasUncommittedRecovery = true
                case let .loneBase(suffix):
                    try MissingJournalRecovery.recoverLoneBase(noteId: group.sourceID, suffix: suffix, directory: directory, store: store, access: access)
                }
            } catch JournalProtectionError.keyRequired {
                report.keyState = missingKeyState(); report.hasUncommittedRecovery = true
            } catch JournalVariantRecovery.Failure.requiresKey {
                report.keyState = missingKeyState(); report.hasUncommittedRecovery = true
            } catch {
                report.failedSourceIDs.append(group.sourceID); report.hasUncommittedRecovery = true
            }
        }
        // Process each aborted marker independently: malformed metadata for one note
        // must neither consume its bytes nor prevent recovery of unrelated notes.
        for noteID in abortedIDs.sorted() {
            do {
                let leftovers = try JournalVariantRecovery.abortedSourceFiles(noteId: noteID, store: store)
                if leftovers.isEmpty { try JournalVariantRecovery.clearResolvedAbortedSourceFiles(noteId: noteID, store: store); continue }
                report.cleanupPending = true
                guard !liveSessionIDs.contains(noteID) else { continue }
                do {
                    let saved = try JournalVariantRecovery.recoverAborted(noteId: noteID, store: store, access: access)
                    report.variants.append(.init(sourceID: noteID, notes: saved.notes, sourceMustExist: true, retirement: saved.retirement))
                } catch JournalVariantRecovery.Failure.requiresKey { report.keyState = missingKeyState() }
                catch {
                    if case let .eligible(_, names) = try JournalQuarantineEligibility.assess(noteId: noteID, directory: directory, access: access),
                       Set(names).isSubset(of: Set(leftovers)) { quarantine.formUnion(names) }
                    else { report.failedSourceIDs.append(noteID) }
                }
            } catch {
                report.cleanupPending = true; report.variantMarkerNeedsAttention = true
                report.failedSourceIDs.append(noteID)
            }
        }
        // Existing-note replay is performed by each host only after its normal session
        // lifecycle admits it. A failed replay is classified here without touching the source.
        for noteID in existingReplayFailureIDs {
            guard !liveSessionIDs.contains(noteID) else {
                report.cleanupPending = true; report.hasUncommittedRecovery = true
                report.failedSourceIDs.append(noteID); continue
            }
            do {
                switch try JournalQuarantineEligibility.assess(noteId: noteID, directory: directory, access: access) {
                case let .eligible(_, names):
                    quarantine.formUnion(names); report.cleanupPending = true; report.hasUncommittedRecovery = true
                case .requiresKey:
                    // S4: with the vault open this is an authenticated pair whose replay failed
                    // (I/O, database): retryable, never "unlock".
                    if access != nil { report.failedSourceIDs.append(noteID) } else { report.keyState = missingKeyState() }
                    report.cleanupPending = true; report.hasUncommittedRecovery = true
                case .none: break // Explicit handling may have removed the previous files.
                case .recoverablePlain:
                    report.failedSourceIDs.append(noteID); report.cleanupPending = true; report.hasUncommittedRecovery = true
                }
            } catch {
                report.failedSourceIDs.append(noteID); report.cleanupPending = true; report.hasUncommittedRecovery = true
            }
        }
        for group in inventory.groups where group.sourceExists {
            do {
                let leftovers = try JournalVariantRecovery.restoredSourceLeftovers(noteId: group.sourceID, store: store)
                if !leftovers.isEmpty { quarantine.formUnion(leftovers); report.cleanupPending = true }
            } catch {
                // A still-active canonical journal is not proof of a damaged remainder.
                // It remains under normal session ownership until replay finishes.
            }
        }
        report.markerMoves = inventory.markers.filter { (try? JournalQuarantine.inspectMarker(store: store, markerName: $0)) != nil }
        report.quarantineFiles = quarantine.sorted()
        report.failedSourceIDs = Array(Set(report.failedSourceIDs)).sorted()
        return report
    }
}
