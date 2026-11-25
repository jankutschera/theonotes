// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Darwin
import CryptoKit

/// Read-only classification. I/O errors propagate and sealed data is never classified corrupt
/// merely because a vault key is unavailable.
public enum JournalQuarantineEligibility {
    public enum Reason: Equatable, Sendable { case damaged, mixed, ambiguous }
    public enum Assessment: Equatable, Sendable {
        case none, recoverablePlain, requiresKey
        case eligible(Reason, [String])
    }

    /// The base digest is part of each entry's associated data, so this proves the actual
    /// pairing even when move-aside files were numbered independently. No file is modified.
    private static func isAuthenticatedSealed(base: Data, journal: Data, noteId: String, key: SymmetricKey) -> Bool {
        func open(_ data: Data, prefix: String, kind: String) throws -> Data {
            let marker = Data(prefix.utf8)
            guard data.starts(with: marker), let combined = Data(base64Encoded: data.dropFirst(marker.count)) else { throw JournalProtectionError.authenticationFailed }
            let aad = try JSONEncoder().encode([ProtocolLabels.journal, noteId, kind])
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
        }
        guard journal.last == UInt8(ascii: "\n") else { return false }
        let lines = journal.dropLast().split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else { return false }
        do {
            let saved = try JSONDecoder().decode(JournalBase.self, from: open(base, prefix: "BJB1:", kind: "base"))
            guard saved.v == EditJournal.formatVersion else { return false }
            let baseDigest = Data(SHA256.hash(data: base)).base64EncodedString()
            var previous = "", text = saved.baseText
            for (index, line) in lines.enumerated() {
                let raw = Data(line)
                let body = try open(raw, prefix: "BJE1:", kind: "entry:\(baseDigest):\(index):\(previous)")
                let entry = try JSONDecoder().decode(JournalEntry.self, from: body)
                guard entry.v == EditJournal.formatVersion else { return false }
                text = try entry.changeSet.apply(to: text)
                previous = Data(SHA256.hash(data: raw)).base64EncodedString()
            }
            return true
        } catch { return false }
    }

    public static func assess(noteId: String, directory: URL, access: LockedNoteAccess? = nil) throws -> Assessment {
        try assessNames(noteId: noteId, directory: directory, access: access,
                        names: FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// Classify exactly the current moved-aside group. Canonical files are never eligible;
    /// callers cannot omit a moved-aside sibling or inject another note's file.
    public static func assessMovedAside(noteId: String, directory: URL, fileNames: [String],
                                        access: LockedNoteAccess? = nil) throws -> Assessment {
        guard !noteId.isEmpty, !noteId.contains("/"), !noteId.contains("\\"),
              !noteId.hasPrefix("."), !noteId.utf8.contains(0), !fileNames.isEmpty,
              Set(fileNames).count == fileNames.count else { throw CocoaError(.fileReadInvalidFileName) }
        func isMoved(_ name: String) -> Bool {
            guard !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else { return false }
            return [noteId + ".jsonl", noteId + ".base"].contains { prefix in
                guard name.hasPrefix(prefix) else { return false }
                let suffix = String(name.dropFirst(prefix.count))
                return !suffix.isEmpty && JournalRecoveryFiles.validSuffix(suffix)
            }
        }
        guard fileNames.allSatisfy(isMoved) else { throw CocoaError(.fileReadInvalidFileName) }
        let actual = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(isMoved)
        guard Set(actual) == Set(fileNames) else { throw CocoaError(.fileReadUnknown) }
        return try assessNames(noteId: noteId, directory: directory, access: access, names: fileNames)
    }

    private static func assessNames(noteId: String, directory: URL, access: LockedNoteAccess?, names: [String]) throws -> Assessment {
        guard !noteId.isEmpty, !noteId.contains("/"), !noteId.contains("\\"), !noteId.hasPrefix("."),
              !noteId.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        func suffix(_ name: String, extension ext: String) -> String? {
            let prefix = noteId + ext
            guard name.hasPrefix(prefix) else { return nil }
            let tail = String(name.dropFirst(prefix.count))
            if JournalRecoveryFiles.validSuffix(tail) { return tail }
            return nil
        }
        let journals = names.compactMap { name in suffix(name, extension: ".jsonl").map { (name, $0) } }
        let bases = names.compactMap { name in suffix(name, extension: ".base").map { (name, $0) } }
        let all = (journals.map(\.0) + bases.map(\.0)).sorted()
        guard !all.isEmpty else { return .none }
        func bytes(_ name: String) throws -> Data {
            try JournalRecoveryFiles.readRegular(directory.appendingPathComponent(name),
                failure: CocoaError(.fileReadNoSuchFile), tooLarge: CocoaError(.fileReadTooLarge))
        }
        var contents: [String: Data] = [:]
        for name in all { contents[name] = try bytes(name) }
        let hasSealedBase = bases.contains { contents[$0.0]?.starts(with: Data("BJB1:".utf8)) == true }
        let hasSealedEntry = journals.contains { name, _ in
            (contents[name] ?? Data()).split(separator: UInt8(ascii: "\n")).contains { $0.starts(with: Data("BJE1:".utf8)) }
        }
        if hasSealedBase || hasSealedEntry {
            guard let access else { return .requiresKey }
            try access.verifyRecoveryClassification(directory: directory)
            let authenticated = try access.withVaultKey { key in
                bases.contains { baseName, _ in
                    journals.contains { journalName, _ in
                        isAuthenticatedSealed(base: contents[baseName]!, journal: contents[journalName]!, noteId: noteId, key: key)
                    }
                }
            }
            // A unique authenticated pair is recoverable normally. With extra independently
            // numbered files, even a valid pair must stay together in byte-preserving quarantine.
            if authenticated, journals.count == 1, bases.count == 1, journals[0].1 == bases[0].1 { return .requiresKey }
        }
        if journals.count != 1 || bases.count != 1 || journals[0].1 != bases[0].1 {
            var plausiblePlainPairs = 0
            for (journalName, _) in journals {
                for (baseName, _) in bases {
                    if JournalRecoveryFiles.replayPlain(base: contents[baseName]!, journal: contents[journalName]!) != nil {
                        plausiblePlainPairs += 1
                        if plausiblePlainPairs > 4 { return .eligible(.ambiguous, all) }
                    }
                }
            }
            if plausiblePlainPairs > 0 { return .recoverablePlain }
            return .eligible(.ambiguous, all)
        }
        let baseData = contents[bases[0].0]!, journalData = contents[journals[0].0]!
        let sealedBase = baseData.starts(with: Data("BJB1:".utf8))
        let entries = journalData.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let nonempty = entries.filter { !$0.isEmpty }
        let sealedCount = nonempty.filter { $0.starts(with: Data("BJE1:".utf8)) }.count
        if (sealedBase && sealedCount != nonempty.count) || (!sealedBase && sealedCount > 0) {
            return .eligible(.mixed, all)
        }
        if sealedBase || sealedCount > 0 { return .eligible(.damaged, all) }
        return JournalRecoveryFiles.replayPlain(base: baseData, journal: journalData) == nil ? .eligible(.damaged, all) : .recoverablePlain
    }
}
