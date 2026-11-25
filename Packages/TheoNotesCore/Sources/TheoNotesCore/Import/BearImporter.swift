// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import GRDB
import os

private let importLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

/// Outcome of one pull. `created + updated + unchanged + conflicts + deletedInTheoNotes + errored
/// records == total` for a run that was not cancelled. Errors are `"<bearID>: <message>"`, never note text.
public struct BearImportReport: Equatable, Sendable {
    /// Entries `bearcli list` returned (including ones that could not be decoded).
    public var total = 0
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    /// Notes changed in both apps: the Theo Notes note was kept, Bear's version became a copy.
    public var conflicts = 0
    /// Locked Bear notes written as title-only stubs in this run.
    public var lockedStubs = 0
    public var attachmentsCopied = 0
    /// Previously imported notes Bear no longer lists; left untouched in Theo Notes.
    public var missingInBear = 0
    /// Bear notes whose Theo Notes note was deleted permanently: skipped, never re-imported.
    public var deletedInTheoNotes = 0
    /// Per-note failures (`"<bearID>: <message>"`); the note was not written.
    public var errors: [String] = []
    /// Things dropped while the note was still written, e.g. a tag pin the text cannot carry.
    public var warnings: [String] = []
    /// `isCancelled` stopped the run between two notes.
    public var wasCancelled = false

    public init(
        total: Int = 0, created: Int = 0, updated: Int = 0, unchanged: Int = 0, conflicts: Int = 0,
        lockedStubs: Int = 0, attachmentsCopied: Int = 0, missingInBear: Int = 0, deletedInTheoNotes: Int = 0,
        errors: [String] = [], warnings: [String] = [], wasCancelled: Bool = false
    ) {
        self.total = total
        self.created = created
        self.updated = updated
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.lockedStubs = lockedStubs
        self.attachmentsCopied = attachmentsCopied
        self.missingInBear = missingInBear
        self.deletedInTheoNotes = deletedInTheoNotes
        self.errors = errors
        self.warnings = warnings
        self.wasCancelled = wasCancelled
    }
}

/// "Pull from Bear" (spec D13): imports every Bear note through the read-only `BearCLIClient`
/// and, on later runs, applies Bear-side changes. Bear ids live in `external_ref(source='bear')`.
/// Each note (with its attachments) is one transaction, so a failing or cancelled run keeps every
/// note written before it. Never writes to Bear.
public final class BearImporter: Sendable {
    public static let source = "bear"
    static let lockedStubBody = "This note is locked in Bear and could not be imported."

    private let store: NoteStore
    private let paths: AppPaths
    private let cli: any BearCLIClient
    private let now: @Sendable () -> Date

    public init(store: NoteStore, paths: AppPaths, cli: any BearCLIClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.paths = paths
        self.cli = cli
        self.now = now
    }

    /// Throws only when Bear cannot be listed at all; per-note failures go to `errors`.
    /// `progress(done, total)` is called before the first note and after each one.
    public func pull(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> BearImportReport {
        try paths.createDirectories()
        let list = try cli.listAll()
        let readOnly = try cli.readOnlyIDs()
        let refs = try store.externalRefs(source: Self.source)

        var report = BearImportReport(total: list.records.count + list.errors.count, errors: list.errors)
        let listed = Set(list.records.map(\.id)).union(list.undecodedIDs)
        report.missingInBear = refs.values.filter { $0.noteId != nil && !listed.contains($0.externalId) }.count

        progress(0, list.records.count)
        for (index, record) in list.records.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            do {
                try pullOne(record, readOnly: readOnly.contains(record.id), ref: refs[record.id], into: &report)
            } catch StoreError.externalRefTombstoned {
                // Deleted permanently in Theo Notes while this note was pulled.
                report.deletedInTheoNotes += 1
            } catch {
                report.errors.append("\(record.id): \(Self.describe(error))")
            }
            progress(index + 1, list.records.count)
        }
        importLogger.info("""
            pull from Bear: total \(report.total), created \(report.created), updated \(report.updated), \
            unchanged \(report.unchanged), conflicts \(report.conflicts), errors \(report.errors.count)
            """)
        return report
    }

    /// Decides per record. Bear's text changed = its hash differs from `lastSeenTextHash`; the
    /// local text changed = its hash differs from `importedTextHash` (the text last written) and
    /// from Bear's last text. Pins, moves and other metadata-only changes are never text edits.
    /// - no ref → import; tombstoned ref → skip; same record hash → unchanged;
    /// - Bear text changed, local text not → replace the text in place;
    /// - Bear text unchanged → keep the text, merge metadata;
    /// - both texts changed → keep the Theo Notes note, import Bear's version as a conflict copy and
    ///   move the ref to it (the copy mirrors Bear from then on).
    /// Metadata merges per field (`SourceMetadata.merge`): location, global pin, tag pins and
    /// read-only take Bear's value only when that field changed in Bear since the last pull.
    private func pullOne(
        _ record: BearNoteRecord, readOnly: Bool, ref: ExternalRef?, into report: inout BearImportReport
    ) throws {
        let bearText = try Self.text(of: record)
        let bearMeta = Self.metadata(of: record, readOnly: readOnly)
        let refWrite = ExternalRefWrite(
            source: Self.source, externalId: record.id, lastSeenModified: record.modified,
            lastSeenHash: Self.hash(record, readOnly: readOnly), lastSeenTextHash: NoteStore.textHash(bearText),
            lastSeenMeta: bearMeta)

        guard let ref else {
            let draft = try makeDraft(record, readOnly: readOnly, fetchAttachments: true)
            try store.importNote(draft, externalRef: refWrite)
            countWrite(draft, record, pinsFromBear: true, into: &report)
            report.created += 1
            return
        }
        guard let noteId = ref.noteId, let current = try store.note(id: noteId) else {
            report.deletedInTheoNotes += 1
            return
        }
        if ref.lastSeenHash == refWrite.lastSeenHash {
            report.unchanged += 1
            return
        }

        let currentTextHash = NoteStore.textHash(current.text)
        let bearTextChanged = refWrite.lastSeenTextHash != ref.lastSeenTextHash
        let localTextChanged = currentTextHash != ref.importedTextHash && currentTextHash != ref.lastSeenTextHash

        if !(bearTextChanged && localTextChanged) {
            var draft = try makeDraft(record, readOnly: readOnly, fetchAttachments: bearTextChanged)
            let local = SourceMetadata(
                location: current.location, isPinnedGlobal: current.isPinnedGlobal,
                tagPins: try store.tagPins(noteId: noteId), isReadOnly: current.isReadOnly)
            let merged = SourceMetadata.merge(source: bearMeta, lastSeen: ref.lastSeenMeta, local: local)
            draft.location = merged.location
            draft.isPinnedGlobal = merged.isPinnedGlobal
            draft.tagPins = merged.tagPins
            draft.isReadOnly = merged.isReadOnly
            let pinsFromBear = ref.lastSeenMeta.map {
                Set($0.tagPins.map(NoteStore.pinKey)) != Set(bearMeta.tagPins.map(NoteStore.pinKey))
            } ?? true
            do {
                if bearTextChanged {
                    try store.replaceImported(
                        noteID: noteId, draft: draft, expectedRevision: current.revision, externalRef: refWrite)
                    countWrite(draft, record, pinsFromBear: pinsFromBear, into: &report)
                    if record.locked, !current.text.hasSuffix(Self.lockedStubBody) {
                        report.warnings.append("\(record.id): locked in Bear since the last pull; the text was replaced by the locked stub")
                    }
                } else {
                    if localTextChanged { draft.modifiedAt = current.modifiedAt }
                    try store.applyImportedMetadata(
                        noteID: noteId, draft: draft, expectedRevision: current.revision, externalRef: refWrite)
                    if pinsFromBear { warnSkippedPins(record, draft: draft, text: current.text, into: &report) }
                }
                report.updated += 1
                return
            } catch StoreError.revisionConflict where bearTextChanged {
                // Edited in Theo Notes while we fetched: keep that edit, make a conflict copy.
            } catch StoreError.noteNotFound(let id) where id == noteId {
                // Deleted permanently in Theo Notes while we fetched: the ref is a tombstone now.
                report.deletedInTheoNotes += 1
                return
            }
        }

        var draft = try makeDraft(record, readOnly: readOnly, fetchAttachments: true)
        draft.text = Self.markingConflict(draft.text, day: Self.localDay(now()))
        try store.importNote(draft, externalRef: refWrite)
        countWrite(draft, record, pinsFromBear: true, into: &report)
        report.conflicts += 1
    }

    private func countWrite(
        _ draft: ImportedNoteDraft, _ record: BearNoteRecord, pinsFromBear: Bool, into report: inout BearImportReport
    ) {
        report.attachmentsCopied += draft.attachments.count
        if record.locked { report.lockedStubs += 1 }
        if pinsFromBear { warnSkippedPins(record, draft: draft, text: draft.text, into: &report) }
    }

    private func warnSkippedPins(
        _ record: BearNoteRecord, draft: ImportedNoteDraft, text: String, into report: inout BearImportReport
    ) {
        for skipped in NoteStore.pinnableTags(draft.tagPins, text: text).skipped {
            report.warnings.append("\(record.id): pin in tag '\(skipped)' skipped (the note does not carry that tag)")
        }
    }

    /// Bear's version of the note. With `fetchAttachments`, every attachment is fetched first, so
    /// a failure fails the record before anything is written.
    private func makeDraft(
        _ record: BearNoteRecord, readOnly: Bool, fetchAttachments: Bool
    ) throws -> ImportedNoteDraft {
        let tagPins = record.pins.compactMap { pin -> String? in
            if case .tag(let name) = pin { return name }
            return nil
        }
        let attachments = record.locked || !fetchAttachments ? [] : try record.attachments.map { filename in
            ImportedAttachment(filename: filename, data: try cli.attachmentData(noteID: record.id, filename: filename))
        }
        return ImportedNoteDraft(
            text: try Self.text(of: record), createdAt: record.created, modifiedAt: record.modified,
            location: record.location, isPinnedGlobal: record.pins.contains(.global), tagPins: tagPins,
            isReadOnly: readOnly, attachments: attachments)
    }

    enum ImportError: Error, CustomStringConvertible {
        case noContent

        var description: String { "bearcli returned no content for an unlocked note" }
    }

    /// The content, or the stub for a locked note.
    static func text(of record: BearNoteRecord) throws -> String {
        if record.locked { return lockedStub(title: record.title) }
        guard let content = record.content else { throw ImportError.noContent }
        return content
    }

    // MARK: - Pure helpers

    static func metadata(of record: BearNoteRecord, readOnly: Bool) -> SourceMetadata {
        SourceMetadata(
            location: record.location, isPinnedGlobal: record.pins.contains(.global),
            tagPins: record.pins.compactMap { pin -> String? in
                if case .tag(let name) = pin { return name }
                return nil
            },
            isReadOnly: readOnly)
    }

    private static func pinStrings(_ record: BearNoteRecord) -> [String] {
        record.pins.map { pin -> String in
            switch pin {
            case .global: "global"
            case .tag(let name): "#" + name
            }
        }
    }

    private static func sha256(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 over the content and every imported flag, so any Bear-side change is seen.
    /// Attachment names are sorted: bearcli lists them in no stable order.
    static func hash(_ record: BearNoteRecord, readOnly: Bool) -> String {
        struct Input: Encodable {
            var content: String?, title: String, locked: Bool, location: String, pins: [String]
            var readOnly: Bool, created: Double, modified: Double, attachments: [String]
        }
        return sha256(Input(
            content: record.content, title: record.locked ? record.title : "", locked: record.locked,
            location: record.location.rawValue, pins: pinStrings(record).sorted(), readOnly: readOnly,
            created: record.created.timeIntervalSince1970, modified: record.modified.timeIntervalSince1970,
            attachments: record.attachments.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }))
    }

    /// `# <title>` + the locked notice. `#` in the title is escaped so the stub carries no tags.
    static func lockedStub(title: String) -> String {
        let escaped = title.replacingOccurrences(of: "#", with: "\\#")
        return "# \(escaped)\n\n\(lockedStubBody)"
    }

    /// Appends ` (<label> <day>)` to the first body line (after YAML front matter). A blank
    /// or code-fence first line gets a new line `<label> <day>` above it instead.
    static func markingConflict(_ text: String, day: String, label: String = "Bear conflict") -> String {
        let text = TextNormalization.normalizeLineEndings(text)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = NoteParser.frontMatterEnd(NoteParser.splitLines(text)) ?? 0
        let marker = "\(label) \(day)"
        guard index < lines.count else { return text + "\n" + marker }
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if lines.count == 1 { return marker }
            lines.insert(marker, at: index)
        } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            lines.insert(marker, at: index)
        } else {
            lines[index] = line + " (\(marker))"
        }
        return lines.joined(separator: "\n")
    }

    /// `YYYY-MM-DD` in the local time zone.
    static func localDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Error text for reports: kinds, codes, filenames and Bear messages, never note text.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as BearCLIError: error.description
        case let error as AttachmentFiles.FileError: error.description
        case let error as ImportError: error.description
        case let error as StoreError: "store error: \(error)"
        case let error as DatabaseError: "database error \(error.resultCode): \(error.message ?? "")"
        case let error as CocoaError: "file error \(error.code.rawValue)"
        default: String(describing: type(of: error))
        }
    }
}
