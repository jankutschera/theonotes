// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Darwin

/// Immutable, content-free scan contract. Inventory does not recover, rename, delete or write.
/// Hosts supply their own current session ownership; installation must revalidate under its fence.
public enum JournalRecoveryScan {
    public enum Source: Sendable, Equatable { case missing, existing, liveSession }
    public enum Blocker: Sendable, Equatable {
        case unlockRequired, waitingForSyncKey, activeSession, unavailable, ambiguous, pendingMarker
    }
    public struct File: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case journal, base }
        public let name: String
        public let kind: Kind
        public let suffix: String
        public init(name: String, kind: Kind, suffix: String) {
            self.name = name; self.kind = kind; self.suffix = suffix
        }
    }
    public struct Group: Sendable, Equatable {
        public let sourceID: String
        public let sourceExists: Bool
        public let hasLiveSession: Bool
        public let files: [File]
        public var source: Source { hasLiveSession ? .liveSession : sourceExists ? .existing : .missing }
        public init(sourceID: String, sourceExists: Bool, hasLiveSession: Bool, files: [File]) {
            self.sourceID = sourceID; self.sourceExists = sourceExists; self.hasLiveSession = hasLiveSession; self.files = files
        }
    }
    public struct Snapshot: Sendable, Equatable {
        public let groups: [Group]
        /// Marker association and validation remain the responsibility of the recovery phase.
        public let markers: [String]
        public init(groups: [Group], markers: [String]) { self.groups = groups; self.markers = markers }
    }
    /// A source can have saved copies and independent blockers at the same time.
    /// The evaluator must populate this only after the corresponding Core transaction commits.
    public struct Notice: Sendable {
        public let id: String
        public let noteIDs: [String]
        public let action: Action
        public init(id: String, noteIDs: [String], action: Action) {
            self.id = id; self.noteIDs = noteIDs; self.action = action
        }
    }
    public enum Action: Sendable {
        case retireSingle(MissingJournalRecovery.Retirement)
        case retireVariants(JournalVariantRecovery.Retirement)
        case quarantine(JournalQuarantine.Selection)
    }
    public struct Evaluation: Sendable {
        public let sourceID: String
        public let sourceExists: Bool
        public let hasLiveSession: Bool
        public let committed: [Notice]
        public let blockers: [Blocker]
        public let pendingActions: [Action]
        public let disposition: Disposition
        /// Name association only; not a marker validity or unlink proof.
        public let markerNames: [String]
        public var source: Source { hasLiveSession ? .liveSession : sourceExists ? .existing : .missing }
        public init(sourceID: String, sourceExists: Bool, hasLiveSession: Bool, committed: [Notice], blockers: [Blocker], pendingActions: [Action], disposition: Disposition = .none, markerNames: [String] = []) {
            self.sourceID = sourceID; self.sourceExists = sourceExists; self.hasLiveSession = hasLiveSession
            self.committed = committed; self.blockers = blockers; self.pendingActions = pendingActions
            self.disposition = disposition; self.markerNames = markerNames
        }
    }

    /// The caller establishes this state from the current library; `.waitingForSyncKey`
    /// means an envelope is pending and must not be treated as an unprotected library.
    public enum Protection: Sendable, Equatable { case unprotected, locked, waitingForSyncKey, unlocked }
    public enum Disposition: Sendable, Equatable {
        case none
        case single(suffix: String)
        case loneBase(suffix: String)
        case variants
        case existingMovedAside
        case quarantine(JournalQuarantineEligibility.Reason, [String])
    }
    public struct Classification: Sendable {
        public let groups: [Evaluation]
        /// Markers not matched to an inventoried source must be resolved separately.
        public let unassociatedMarkers: [String]
    }

    /// Classifies an immutable inventory without recovery, database writes or file mutation.
    /// Results are advisory: the caller must revalidate under the operation's existing fence.
    public static func classify(_ snapshot: Snapshot, directory: URL, protection: Protection,
                                access: LockedNoteAccess?, dirtyLiveSessionIDs: Set<String> = []) -> Classification {
        var matched = Set<String>()
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let groups = snapshot.groups.map { group -> Evaluation in
            // Snapshot initializers are public. Validate the exact inventory mapping before
            // touching the filesystem; do not trust synthetic names, suffixes or source IDs.
            let id = group.sourceID
            let validID = !id.isEmpty && !id.hasPrefix(".") && !id.contains("/") &&
                !id.contains("\\") && !id.utf8.contains(0)
            let names = group.files.map(\.name)
            let validFiles = Set(names).count == names.count && group.files.allSatisfy { file in
                guard !file.name.contains("/"), !file.name.contains("\\"),
                      !file.name.utf8.contains(0), JournalRecoveryFiles.validSuffix(file.suffix),
                      let marker = file.name.range(of: ".jsonl") ?? file.name.range(of: ".base") else { return false }
                let expectedKind: File.Kind = file.name[marker] == ".jsonl" ? .journal : .base
                return String(file.name[..<marker.lowerBound]) == id &&
                    String(file.name[marker.upperBound...]) == file.suffix && file.kind == expectedKind
            }
            guard validID && validFiles else {
                return Evaluation(sourceID: id, sourceExists: group.sourceExists,
                                  hasLiveSession: group.hasLiveSession, committed: [],
                                  blockers: [.unavailable], pendingActions: [])
            }
            var blockers: [Blocker] = []
            var disposition: Disposition = .none
            let variantHash = digest(group.sourceID)
            let fileHashes = Set(group.files.map { digest(group.sourceID + "\0" + $0.suffix) })
            let markers = snapshot.markers.filter { marker in
                [".variant-confirm-", ".variant-aborted-"].contains { marker == $0 + variantHash + ".json" } ||
                [".retirement-", ".discard-"].contains { prefix in fileHashes.contains { marker == prefix + $0 + ".json" } }
            }
            matched.formUnion(markers)
            if !markers.isEmpty { blockers.append(.pendingMarker) }
            if group.hasLiveSession { blockers.append(.activeSession) }
            if dirtyLiveSessionIDs.contains(group.sourceID) && !group.sourceExists {
                if protection == .locked { blockers.append(.unlockRequired) }
                if protection == .waitingForSyncKey { blockers.append(.waitingForSyncKey) }
            }
            do {
                // An empty journal is a normal cached-note artifact. Do not read its paired base
                // or manufacture an action merely because an editor was once opened.
                var meaningful: [File] = []
                for file in group.files {
                    let path = directory.appendingPathComponent(file.name).path
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadNoSuchFile) }
                    if info.st_size > 0 { meaningful.append(file) }
                }
                let hasJournal = meaningful.contains { $0.kind == .journal }
                let hasMovedAside = meaningful.contains { !$0.suffix.isEmpty }
                // Ordinary existing-note journals belong to NoteSession, never orphan recovery.
                if !meaningful.isEmpty && (hasJournal || hasMovedAside || !group.sourceExists) &&
                    (!group.sourceExists || hasMovedAside) {
                    if !group.sourceExists && protection == .locked { blockers.append(.unlockRequired) }
                    if !group.sourceExists && protection == .waitingForSyncKey { blockers.append(.waitingForSyncKey) }
                    if protection == .unlocked && access == nil { blockers.append(.unlockRequired) }
                    if meaningful.count == 1, let lone = meaningful.first, lone.kind == .base {
                        let bytes = try JournalRecoveryFiles.readRegular(directory.appendingPathComponent(lone.name),
                            failure: CocoaError(.fileReadNoSuchFile), tooLarge: CocoaError(.fileReadTooLarge))
                        if bytes.starts(with: Data("BJB1:".utf8)) {
                            if let access, protection == .unlocked {
                                try access.verifyRecoveryClassification(directory: directory)
                                do {
                                    let journal = try EditJournal(recoveryDirectory: directory, noteId: group.sourceID,
                                        suffix: lone.suffix, encryptionKey: access.journalKey(), baseOnly: true)
                                    if try journal.base() != nil { disposition = .loneBase(suffix: lone.suffix) }
                                    else { blockers.append(.unavailable) }
                                } catch JournalProtectionError.authenticationFailed {
                                    disposition = .quarantine(.damaged, [lone.name])
                                } catch is DecodingError {
                                    disposition = .quarantine(.damaged, [lone.name])
                                }
                            } else { blockers.append(protection == .waitingForSyncKey || protection == .unprotected ? .waitingForSyncKey : .unlockRequired) }
                        } else {
                            do {
                                let journal = try EditJournal(recoveryDirectory: directory, noteId: group.sourceID,
                                    suffix: lone.suffix, encryptionKey: nil, baseOnly: true)
                                if try journal.base() != nil { disposition = .loneBase(suffix: lone.suffix) }
                                else { blockers.append(.unavailable) }
                            } catch is DecodingError {
                                disposition = .quarantine(.damaged, [lone.name])
                            }
                        }
                    } else { switch try JournalQuarantineEligibility.assess(noteId: group.sourceID, directory: directory, access: access) {
                    case .none: break
                    case .requiresKey:
                        if protection == .unlocked, access != nil {
                            // Eligibility returns requiresKey for an authenticated sealed pair too.
                            let journals = meaningful.filter { $0.kind == .journal }
                            let bases = meaningful.filter { $0.kind == .base }
                            if journals.count == 1, bases.count == 1, journals[0].suffix == bases[0].suffix {
                                disposition = group.sourceExists ? .existingMovedAside : .single(suffix: journals[0].suffix)
                            } else { blockers.append(.unavailable) }
                        } else {
                            blockers.append(protection == .waitingForSyncKey || protection == .unprotected ? .waitingForSyncKey : .unlockRequired)
                        }
                    case .recoverablePlain:
                        if protection == .locked { blockers.append(.unlockRequired) }
                        if protection == .waitingForSyncKey { blockers.append(.waitingForSyncKey) }
                        let journals = meaningful.filter { $0.kind == .journal }
                        let bases = meaningful.filter { $0.kind == .base }
                        if group.sourceExists { disposition = .existingMovedAside }
                        else if journals.count == 1, bases.count == 1, journals[0].suffix == bases[0].suffix {
                            disposition = .single(suffix: journals[0].suffix)
                        } else { disposition = .variants }
                    case let .eligible(reason, names):
                        disposition = .quarantine(reason, names)
                    } }
                }
            } catch {
                blockers.append(.unavailable)
                disposition = .none
            }
            // A candidate is never offered while a live writer, missing key or unresolved
            // marker could make the apparent file state unsafe to act on.
            if group.sourceExists && group.files.contains(where: { !$0.suffix.isEmpty }) &&
                group.files.contains(where: { $0.suffix.isEmpty && $0.kind == .journal }) {
                // A source's canonical and moved-aside files must be separated by a dedicated
                // reader before assigning any action; the shared eligibility reader sees both.
                blockers.append(.ambiguous)
            }
            if !blockers.isEmpty { disposition = .none }
            return Evaluation(sourceID: group.sourceID, sourceExists: group.sourceExists,
                              hasLiveSession: group.hasLiveSession, committed: [],
                              blockers: blockers.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                              pendingActions: [], disposition: disposition, markerNames: markers.sorted())
        }
        return Classification(groups: groups, unassociatedMarkers: snapshot.markers.filter { !matched.contains($0) })
    }

    public static func inventory(directory: URL, existingNoteIDs: Set<String>, liveSessionIDs: Set<String>) throws -> Snapshot {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        var groups: [String: [File]] = [:]
        for name in names where !name.hasPrefix(".") {
            guard let range = name.range(of: ".jsonl") ?? name.range(of: ".base") else { continue }
            let id = String(name[..<range.lowerBound]), suffix = String(name[range.upperBound...])
            guard !id.isEmpty, JournalRecoveryFiles.validSuffix(suffix) else { continue }
            let kind: File.Kind = name[range] == ".jsonl" ? .journal : .base
            groups[id, default: []].append(File(name: name, kind: kind, suffix: suffix))
        }
        for id in liveSessionIDs where groups[id] == nil { groups[id] = [] }
        let result = groups.keys.sorted().map { id in
            Group(sourceID: id, sourceExists: existingNoteIDs.contains(id), hasLiveSession: liveSessionIDs.contains(id), files: groups[id] ?? [])
        }
        let markers = names.filter { name in
            [".retirement-", ".discard-", ".variant-confirm-", ".variant-aborted-"].contains { name.hasPrefix($0) }
        }
        return Snapshot(groups: result, markers: markers)
    }
}
