// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CryptoKit
import Foundation
import os

private let appleNotesLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "import")

/// Outcome of one Apple Notes import. Lines are `"“<title>”: <message>"`, never note text.
public struct AppleNotesImportReport: Equatable, Sendable {
    /// Notes the listing returned (all folders, incl. skipped ones).
    public var total = 0
    public var created = 0
    public var updated = 0
    public var unchanged = 0
    /// Changed in both apps: the Theo Notes note was kept, Notes' version became a copy.
    public var conflicts = 0
    /// Password-protected notes: Notes does not expose them, skipped.
    public var passwordProtected = 0
    /// Notes in "Recently Deleted": skipped.
    public var recentlyDeleted = 0
    public var imagesCopied = 0
    /// Previously imported notes Notes no longer lists; left untouched in Theo Notes.
    public var missingInNotes = 0
    /// Notes whose Theo Notes note was deleted permanently: skipped, never re-imported.
    public var deletedInTheoNotes = 0
    public var errors: [String] = []
    public var warnings: [String] = []
    public var wasCancelled = false

    public init(
        total: Int = 0, created: Int = 0, updated: Int = 0, unchanged: Int = 0, conflicts: Int = 0,
        passwordProtected: Int = 0, recentlyDeleted: Int = 0, imagesCopied: Int = 0, missingInNotes: Int = 0,
        deletedInTheoNotes: Int = 0, errors: [String] = [], warnings: [String] = [], wasCancelled: Bool = false
    ) {
        self.total = total
        self.created = created
        self.updated = updated
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.passwordProtected = passwordProtected
        self.recentlyDeleted = recentlyDeleted
        self.imagesCopied = imagesCopied
        self.missingInNotes = missingInNotes
        self.deletedInTheoNotes = deletedInTheoNotes
        self.errors = errors
        self.warnings = warnings
        self.wasCancelled = wasCancelled
    }
}

/// Import from Apple Notes, repeatable like Pull from Bear. Notes ids live in
/// `external_ref(source='applenotes')`. Change detection never depends on the converted text
/// (ruling R13), so a better converter never rewrites existing notes:
/// - `lastSeenHash` = `f:<folder key>;m:<title+dates stamp>`: equal → skipped without a body fetch;
/// - `lastSeenTextHash` = hash of Notes' HTML body + title (the source text);
/// - local edit = the note's text no longer hashes to `importedTextHash` (the text last written).
/// Source text changed: unedited → rewritten in place, edited → conflict copy (the ref moves to the
/// copy). Only the folder changed: unedited → rewritten in place (new tag), edited → text kept and
/// a warning. Deleted permanently in Theo Notes → tombstone. Whether tags lead with the account is
/// decided at the first import and kept (setting `appleNotesImport.accountLevelTags`).
/// Bodies are fetched in batches; a failed batch is retried note by note. Cancel is checked
/// before every note. Never writes to Notes.
public final class AppleNotesImporter: Sendable {
    public static let source = "applenotes"
    static let conflictLabel = "Apple Notes conflict"
    /// Notes carries none of Theo Notes' flags; refs record this as "last seen".
    static let sourceMetadata = SourceMetadata(location: .notes, isPinnedGlobal: false, tagPins: [], isReadOnly: false)
    /// Names of the default folder: a note directly in it gets no folder tag.
    static let defaultFolderNames: Set<String> = ["notes", "notizen"]
    /// `"yes"` / `"no"` once decided; `""` before the first import with notes.
    public static let accountLevelTagsKey = SettingKey<String>("appleNotesImport.accountLevelTags", default: "")

    private let store: NoteStore
    private let paths: AppPaths
    private let client: any AppleNotesClient
    private let batchSize: Int
    private let now: @Sendable () -> Date
    private let convert: @Sendable (String) -> HTMLToMarkdown.Result

    /// `convert` is replaceable for tests (a different converter must not rewrite notes).
    public init(
        store: NoteStore, paths: AppPaths, client: any AppleNotesClient, batchSize: Int = 10,
        now: @escaping @Sendable () -> Date = { Date() },
        convert: @escaping @Sendable (String) -> HTMLToMarkdown.Result = { HTMLToMarkdown.convert($0) }
    ) {
        self.store = store
        self.paths = paths
        self.client = client
        self.batchSize = max(1, batchSize)
        self.now = now
        self.convert = convert
    }

    /// Throws only when Notes cannot be listed; per-note failures go to `errors`.
    /// `progress(done, total)` is called before the first note and after each one.
    public func pull(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> AppleNotesImportReport {
        try paths.createDirectories()
        let listing = try client.listing()
        let refs = try store.externalRefs(source: Self.source)
        var report = AppleNotesImportReport(total: listing.notes.count)
        let listed = Set(listing.notes.map(\.id))
        report.missingInNotes = refs.values.filter { $0.noteId != nil && !listed.contains($0.externalId) }.count

        let tagContext = TagContext(listing, includeAccount: try accountLevelTags(listing))
        struct Planned { var note: AppleNotesRecord; var tag: String?; var hash: String; var skip: Bool }
        var warnedFolders = Set<String>()
        let planned = listing.notes.map { note -> Planned in
            let skip = note.isPasswordProtected || listing.isRecentlyDeleted(note)
            let tag = tagContext.tag(for: note)
            if !skip, let warning = tag.warning, warnedFolders.insert(note.folderID ?? "").inserted {
                report.warnings.append(warning)
            }
            return Planned(note: note, tag: tag.tag, hash: Self.recordHash(note, listing: listing), skip: skip)
        }
        let needingBody = planned.filter { item in
            guard !item.skip else { return false }
            guard let ref = refs[item.note.id] else { return true }
            return ref.noteId != nil && ref.lastSeenHash != item.hash
        }.map(\.note.id)
        var nextBatch = 0
        var bodies: [String: AppleNotesBody] = [:]
        var bodyErrors: [String: String] = [:]
        /// Stall detection: two single-note timeouts with no successful request in between make
        /// the next request a one-note probe. If the probe answers, everything continues; if it
        /// times out too, Notes stopped answering and the rest of the run is reported unasked
        /// (worst case before giving up: one batch + three notes). Slow notes alone never block
        /// the others: any successful request resets the count.
        var notesStalled = false
        var singleTimeouts = 0
        var probing = false

        func fetch(_ batch: [String]) {
            guard !notesStalled else {
                for id in batch { bodyErrors[id] = Self.stalledMessage }
                return
            }
            guard !isCancelled() else { return }
            if probing, batch.count > 1 {
                fetch([batch[0]])
                fetch(Array(batch.dropFirst()))
                return
            }
            do {
                let result = try client.bodies(ids: batch, isCancelled: isCancelled)
                bodies.merge(result.bodies) { _, new in new }
                bodyErrors.merge(result.errors) { _, new in new }
                singleTimeouts = 0
                probing = false
            } catch AppleNotesError.cancelled {
                return
            } catch AppleNotesError.timedOut where batch.count == 1 {
                bodyErrors[batch[0]] = AppleNotesError.timedOut.description
                if probing {
                    notesStalled = true
                    return
                }
                singleTimeouts += 1
                if singleTimeouts >= 2 { probing = true }
            } catch let error as AppleNotesError where batch.count > 1 && error != .notAuthorized && error != .notesUnavailable {
                // One slow or huge note must not fail the others: retry one by one.
                for id in batch { fetch([id]) }
            } catch {
                for id in batch { bodyErrors[id] = Self.describe(error) }
            }
        }

        func body(for id: String) -> Result<AppleNotesBody, ImportError> {
            if bodies[id] == nil, bodyErrors[id] == nil, let start = needingBody[nextBatch...].firstIndex(of: id) {
                let batch = Array(needingBody[start..<min(needingBody.count, start + batchSize)])
                nextBatch = start + batch.count
                fetch(batch)
            }
            if let body = bodies.removeValue(forKey: id) { return .success(body) }
            return .failure(ImportError(message: bodyErrors[id] ?? "Notes returned no body"))
        }

        progress(0, planned.count)
        for (index, item) in planned.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            let note = item.note
            if listing.isRecentlyDeleted(note) {
                report.recentlyDeleted += 1
            } else if note.isPasswordProtected {
                report.passwordProtected += 1
                report.warnings.append("\(Self.label(note)): password-protected, skipped")
            } else if let ref = refs[note.id], ref.noteId == nil {
                report.deletedInTheoNotes += 1
            } else if let ref = refs[note.id], ref.lastSeenHash == item.hash {
                report.unchanged += 1
            } else {
                do {
                    let body = try body(for: note.id).get()
                    try importOne(note, body: body, tag: item.tag, hash: item.hash, ref: refs[note.id],
                                  folder: tagContext.displayPath(for: note), into: &report)
                } catch StoreError.externalRefTombstoned {
                    // Deleted permanently in Theo Notes while this note was read.
                    report.deletedInTheoNotes += 1
                } catch {
                    if isCancelled() {
                        report.wasCancelled = true
                        break
                    }
                    report.errors.append("\(Self.label(note)): \(Self.describe(error))")
                }
            }
            progress(index + 1, planned.count)
        }
        appleNotesLogger.info("""
            import from Apple Notes: total \(report.total), created \(report.created), updated \(report.updated), \
            unchanged \(report.unchanged), conflicts \(report.conflicts), locked \(report.passwordProtected), \
            errors \(report.errors.count)
            """)
        return report
    }

    /// The persisted decision, or (first import with notes) the decision from this listing,
    /// saved: the account leads the tag only when more than one account has notes.
    private func accountLevelTags(_ listing: AppleNotesListing) throws -> Bool {
        let settings = Settings(db: store.db)
        let stored = try settings.value(Self.accountLevelTagsKey)
        if stored == "yes" || stored == "no" { return stored == "yes" }
        let importable = listing.notes.filter { !$0.isPasswordProtected && !listing.isRecentlyDeleted($0) }
        let several = Set(importable.map(\.accountID)).count > 1
        if !importable.isEmpty { try settings.set(Self.accountLevelTagsKey, to: several ? "yes" : "no") }
        return several
    }

    private func importOne(
        _ note: AppleNotesRecord, body: AppleNotesBody, tag: String?, hash: String, ref: ExternalRef?,
        folder: String, into report: inout AppleNotesImportReport
    ) throws {
        let refWrite = ExternalRefWrite(
            source: Self.source, externalId: note.id, lastSeenModified: note.modified, lastSeenHash: hash,
            lastSeenTextHash: Self.sourceHash(body.html, name: note.name), lastSeenMeta: Self.sourceMetadata)
        /// The converted note; warnings are added to the report only when it is written.
        func converted() -> (draft: ImportedNoteDraft, warnings: [String]) {
            let result = convert(body.html)
            var text = Self.titled(result.markdown, name: note.name)
            if let tag { text = text.isEmpty ? tag : text + "\n\n" + tag }
            var warnings = result.warnings
            let missing = body.attachmentCount - result.images.count
            if missing > 0 {
                warnings.append("\(missing) attachment(s) not available through Notes scripting (only embedded images are imported)")
            }
            return (ImportedNoteDraft(text: text, createdAt: note.created, modifiedAt: note.modified,
                                      attachments: result.images), warnings)
        }
        func written(_ draft: ImportedNoteDraft, _ warnings: [String]) {
            report.imagesCopied += draft.attachments.count
            report.warnings += warnings.map { "\(Self.label(note)): \($0)" }
        }

        guard let ref, let noteId = ref.noteId, let current = try store.note(id: noteId) else {
            let (draft, warnings) = converted()
            try store.importNote(draft, externalRef: refWrite)
            report.created += 1
            written(draft, warnings)
            return
        }
        let localEdited = NoteStore.textHash(current.text) != ref.importedTextHash
        let sourceChanged = refWrite.lastSeenTextHash != ref.lastSeenTextHash
        let folderChanged = Self.folderPart(hash) != ref.lastSeenHash.map(Self.folderPart)
        // Local flags are Theo Notes' own (Notes has none).
        var keep = ImportedNoteDraft(
            text: current.text, createdAt: current.createdAt, modifiedAt: current.modifiedAt,
            location: current.location,
            isPinnedGlobal: current.isPinnedGlobal, tagPins: try store.tagPins(noteId: noteId), isReadOnly: current.isReadOnly)

        if (sourceChanged || folderChanged) && !localEdited {
            var (draft, warnings) = converted()
            draft.location = keep.location
            draft.isPinnedGlobal = keep.isPinnedGlobal
            draft.tagPins = keep.tagPins
            draft.isReadOnly = keep.isReadOnly
            if !sourceChanged { draft.modifiedAt = current.modifiedAt }
            do {
                try store.replaceImported(
                    noteID: noteId, draft: draft, expectedRevision: current.revision, externalRef: refWrite)
                report.updated += 1
                written(draft, warnings)
                return
            } catch StoreError.revisionConflict where sourceChanged {
                // Edited in Theo Notes while we fetched: keep that edit, make a conflict copy below.
            } catch StoreError.revisionConflict {
                // Folder-only change raced with a local edit: keep the edit; reported next run.
                report.unchanged += 1
                return
            }
        }
        if sourceChanged {
            var (copy, warnings) = converted()
            copy.text = BearImporter.markingConflict(copy.text, day: BearImporter.localDay(now()), label: Self.conflictLabel)
            try store.importNote(copy, externalRef: refWrite)
            report.conflicts += 1
            written(copy, warnings)
            return
        }
        // Notes' text unchanged: keep the note as it is and record what was seen.
        keep.text = current.text
        try store.applyImportedMetadata(
            noteID: noteId, draft: keep, expectedRevision: current.revision, externalRef: refWrite)
        report.unchanged += 1
        if folderChanged {
            report.warnings.append("""
                \(Self.label(note)): moved to \(folder.isEmpty ? "no folder" : "“\(folder)”") in Notes; \
                the folder tag was not changed because the note was edited in Theo Notes
                """)
        }
    }

    // MARK: - Helpers

    static let stalledMessage = "not read: Notes stopped answering (three notes in a row timed out)"

    struct ImportError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// `“<title>”` (or the id for an untitled note) for report lines.
    static func label(_ note: AppleNotesRecord) -> String {
        let title = note.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? note.id : "“\(title.prefix(80))”"
    }

    /// Notes shows `name` as the title. A body without a title line (empty, or starting with an
    /// image) gets `# <name>` on top, escaped like body text (and `#`, so it carries no tags).
    static func titled(_ markdown: String, name: String) -> String {
        let title = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, NoteParser.metadata(for: markdown).title.isEmpty else { return markdown }
        let heading = "# " + Renderer.escape(title).replacingOccurrences(of: "#", with: "\\#")
        return markdown.isEmpty ? heading : heading + "\n" + markdown
    }

    private static func sha256(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The source text: Notes' HTML body and title.
    static func sourceHash(_ html: String, name: String) -> String {
        sha256(["body", name, html])
    }

    /// `f:<folder key>;m:<stamp>`. The folder key covers the account and folder names from the
    /// top (not the tag, so the account-level decision cannot change it); the stamp covers title
    /// and dates (Notes bumps `modified` whenever the body changes).
    static func recordHash(_ note: AppleNotesRecord, listing: AppleNotesListing) -> String {
        let folder = sha256(["folder", note.accountID] + listing.folderPath(note.folderID).map(\.name))
        let stamp = sha256(["stamp", note.name, String(note.created.timeIntervalSince1970),
                            String(note.modified.timeIntervalSince1970)])
        return "f:\(folder);m:\(stamp)"
    }

    static func folderPart(_ recordHash: String) -> Substring {
        recordHash.split(separator: ";", maxSplits: 1).first ?? ""
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as AppleNotesError: error.description
        case let error as ImportError: error.message
        default: BearImporter.describe(error)
        }
    }

    /// Builds folder tags: `#Folder/Sub`, closed (`#My Folder/Sub#`) when the path needs it.
    /// With `includeAccount` the account name leads the path; a note directly in an account's
    /// default folder gets no folder (only the account, if included).
    struct TagContext {
        let listing: AppleNotesListing
        let accountNames: [String: String]
        let defaultFolders: Set<String>
        let includeAccount: Bool

        init(_ listing: AppleNotesListing, includeAccount: Bool) {
            self.listing = listing
            accountNames = Dictionary(listing.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            defaultFolders = Set(listing.accounts.compactMap(\.defaultFolderID))
            self.includeAccount = includeAccount
        }

        private func components(for note: AppleNotesRecord) -> [String] {
            var folders = listing.folderPath(note.folderID)
            if folders.count == 1, isDefault(folders[0]) { folders = [] }
            var components = folders.map(\.name)
            if includeAccount, let account = accountNames[note.accountID] { components.insert(account, at: 0) }
            return components
        }

        /// The tag of the longest leading part of the folder path that can be a tag, and a warning
        /// naming the first name that cannot. The path is cut there (not just that name skipped),
        /// so notes land in an ancestor's tag, never in a tag that looks like another folder
        /// (`Bad/Sub` must not become `#Sub`).
        func tag(for note: AppleNotesRecord) -> (tag: String?, warning: String?) {
            let components = components(for: note)
            var usable: [String] = []
            for component in components {
                guard AppleNotesImporter.tag(usable + [component]) != nil else {
                    let outcome = AppleNotesImporter.tag(usable).map { "its notes keep the tag \($0)" }
                        ?? "its notes get no folder tag"
                    return (AppleNotesImporter.tag(usable),
                            "folder “\(components.joined(separator: " / "))”: “\(component)” cannot become a tag; \(outcome)")
                }
                usable.append(component)
            }
            return (AppleNotesImporter.tag(usable), nil)
        }

        func displayPath(for note: AppleNotesRecord) -> String {
            components(for: note).joined(separator: " / ")
        }

        private func isDefault(_ folder: AppleNotesFolder) -> Bool {
            if defaultFolders.contains(folder.id) { return true }
            let account = listing.accounts.first { $0.id == folder.accountID }
            return account?.defaultFolderID == nil && AppleNotesImporter.defaultFolderNames.contains(folder.name.lowercased())
        }
    }

    /// `/` and `#` become `-`; whitespace collapses.
    static func cleanTagComponent(_ name: String) -> String {
        let replaced = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "#", with: "-")
        return replaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `#a/b` when that parses back as tag `a/b`, else the closed form `#a b/c#`. `nil` when
    /// a name is blank after cleaning or neither form parses back.
    static func tag(_ components: [String]) -> String? {
        let cleaned = components.map(cleanTagComponent)
        guard !cleaned.isEmpty, !cleaned.contains(where: \.isEmpty) else { return nil }
        let path = cleaned.joined(separator: "/")
        let open = "#" + path
        if TagScanner.tags(inLine: open) == [path] { return open }
        let closed = "#" + path + "#"
        return TagScanner.tags(inLine: closed) == [path] ? closed : nil
    }
}
