// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import GRDB
import Synchronization

/// What a share extension asks the app to do. Written as `request.json` next to the
/// shared files; the app treats it as hostile input.
public struct CaptureRequest: Codable, Equatable, Sendable {
    public var version = 1
    public let itemId: String
    public let mode: Mode
    public let targetNoteId: String?
    public let text: String
    public let files: [String]

    public enum Mode: String, Codable, Sendable { case save, append }

    public init(
        version: Int = 1, itemId: String, mode: Mode, targetNoteId: String? = nil, text: String, files: [String] = []
    ) {
        self.version = version
        self.itemId = itemId
        self.mode = mode
        self.targetNoteId = targetNoteId
        self.text = text
        self.files = files
    }
}

public enum CaptureInboxError: Error, Equatable, Sendable {
    /// The request or its files break a rule of the inbox format.
    case invalidRequest(String)
}

/// The App Group folder (`CaptureInbox`) that share extensions drop items into and the app drains
///. One item is a folder `<itemId>.capture/` holding `request.json` plus the files.
public struct CaptureInbox: Sendable {
    public let directory: URL

    // Limits.
    static let maxTextBytes = 2 * 1024 * 1024
    static let maxRequestBytes = 8 * 1024 * 1024
    static let maxFiles = 10
    static let maxFileBytes = 25 * 1024 * 1024
    static let maxTotalBytes = 50 * 1024 * 1024
    /// A `.tmp` folder untouched for this long was abandoned.
    static let staleTmpAge: TimeInterval = 3600
    static let receiptAge: TimeInterval = 30 * 86400
    /// Rejected items are kept this long after the rejection, and at most `maxRejected` of them.
    static let rejectedAge: TimeInterval = 7 * 86400
    static let maxRejected = 20

    static let requestFileName = "request.json"
    static let rejectedName = "rejected"

    public init(directory: URL) { self.directory = directory }

    // MARK: - Extension side

    /// Writes one item: a `.tmp` folder, then one rename to `.capture`, so a drain never sees a
    /// half-written item. `files` must be the regular files named in `request.files`, in order.
    public func enqueue(_ request: CaptureRequest, files: [URL]) throws {
        if let problem = Self.problem(in: request) { throw CaptureInboxError.invalidRequest(problem) }
        guard files.map(\.lastPathComponent) == request.files else {
            throw CaptureInboxError.invalidRequest("files do not match the request")
        }
        var total = 0
        for url in files {
            guard let size = Self.regularFileSize(atPath: url.path), size <= Self.maxFileBytes else {
                throw CaptureInboxError.invalidRequest("file is not a regular file or too large")
            }
            total += size
        }
        guard total <= Self.maxTotalBytes else { throw CaptureInboxError.invalidRequest("files too large") }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent("\(request.itemId).tmp", isDirectory: true)
        let final = directory.appendingPathComponent("\(request.itemId).capture", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        do {
            for url in files { try fm.copyItem(at: url, to: tmp.appendingPathComponent(url.lastPathComponent)) }
            let json = try JSONEncoder().encode(request)
            let handle = try Self.createFile(at: tmp.appendingPathComponent(Self.requestFileName))
            try handle.write(contentsOf: json)
            try handle.synchronize()
            try handle.close()
            guard rename(tmp.path, final.path) == 0 else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: final.path])
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - App side

    /// Applies every complete item and returns the ids of the notes they ended in (created or
    /// appended to), in item order. Rejected items go to `rejected/`; items that failed for a
    /// transient reason stay for the next drain.
    /// `holdingAppendsTo` names notes that cannot take an append right now (the app has unsaved text of
    /// them open): an append item for one of them stays in the inbox for a later drain.
    public func drain(
        into store: NoteStore, attachments: AttachmentStore, now: Date = .now, holdingAppendsTo held: Set<String> = []
    ) throws -> [String] {
        try drain(into: store, attachments: attachments, now: now, held: held, afterNoteWrite: nil)
    }

    /// `afterNoteWrite` is a test seam: it runs right after the store write of a note, and
    /// an error it throws stops the drain, like a crash would.
    func drain(
        into store: NoteStore, attachments: AttachmentStore, now: Date, held: Set<String> = [],
        afterNoteWrite: (@Sendable (String) throws -> Void)?
    ) throws -> [String] {
        try Self.drainLock.withLock { _ in
            try store.db.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM capture_receipt WHERE processedAt < ?",
                    arguments: [now.addingTimeInterval(-Self.receiptAge)])
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: directory.path) else { return [] }
            defer { pruneRejected(now: now) }
            var done: [String] = []
            for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
                let url = directory.appendingPathComponent(name)
                if name.hasSuffix(".tmp") {
                    sweepIfStale(url, now: now)
                    continue
                }
                guard name.hasSuffix(".capture") else { continue }
                let itemId = String(name.dropLast(".capture".count))
                do {
                    let request = try Self.readRequest(in: url, itemId: itemId)
                    if request.mode == .append, let target = request.targetNoteId, held.contains(target) { continue }
                    let noteId = try apply(
                        request, from: url, store: store, attachments: attachments, now: now,
                        afterNoteWrite: afterNoteWrite)
                    do { try fm.removeItem(at: url) } catch {
                        storeLogger.error("capture item \(itemId, privacy: .public) applied but not removed: \(error)")
                    }
                    done.append(noteId)
                } catch let abort as DrainAbort {
                    throw abort.underlying
                } catch is CaptureInboxError {
                    reject(url, now: now)
                } catch {
                    storeLogger.error("capture item \(itemId, privacy: .public) not applied: \(error)")
                }
            }
            return done
        }
    }

    private static let drainLock = Mutex<Void>(())

    private struct DrainAbort: Error { let underlying: any Error }

    // MARK: - Applying one item

    private func apply(
        _ request: CaptureRequest, from item: URL, store: NoteStore, attachments: AttachmentStore, now: Date,
        afterNoteWrite: (@Sendable (String) throws -> Void)?
    ) throws -> String {
        if let existing = try Self.receipt(request.itemId, in: store) {
            // Applied before; only a created note can still miss its files.
            let noteId = existing ?? request.itemId
            if noteId == request.itemId {
                try placeMissingFiles(of: request, in: item, noteId: noteId, attachments: attachments)
            }
            return noteId
        }
        if request.mode == .append, let target = request.targetNoteId,
           let appended = try append(request, to: target, from: item, store: store, now: now, afterNoteWrite: afterNoteWrite) {
            return appended
        }
        let names = Self.plannedNames(request.files)
        let text = Self.join(request.text, names.map(AttachmentMarkdown.link(for:)))
        try store.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM capture_receipt WHERE itemId = ?)", arguments: [request.itemId]) == true {
                return
            }
            if try Note.fetchOne(db, key: request.itemId) == nil {
                _ = try NoteStore.insert(id: request.itemId, text: text, now: now, captureSource: .share, in: db)
            }
            try Self.writeReceipt(itemId: request.itemId, noteId: request.itemId, now: now, in: db)
        }
        do { try afterNoteWrite?(request.itemId) } catch { throw DrainAbort(underlying: error) }
        try placeMissingFiles(of: request, in: item, noteId: request.itemId, attachments: attachments)
        return request.itemId
    }

    /// Appends to `target`, or returns nil when it cannot take the text (missing, deleted, locked,
    /// trashed or read-only), so the caller saves a new note instead.
    private func append(
        _ request: CaptureRequest, to target: String, from item: URL, store: NoteStore,
        now: Date, afterNoteWrite: (@Sendable (String) throws -> Void)?
    ) throws -> String? {
        let files = AttachmentFiles(paths: store.paths, database: store.db)
        var staged: AttachmentFiles.Staged?
        let result: String?
        do {
            result = try store.write { db -> String? in
                if let existing = try Self.receipt(request.itemId, in: db) { return existing ?? target }
                guard let note = try Note.fetchOne(db, key: target), Self.canTakeText(note) else { return nil }
                // An unfinished batch owns its names until recovery installs it.
                if !request.files.isEmpty, try Bool.fetchOne(db,
                    sql: "SELECT EXISTS(SELECT 1 FROM staging_batch WHERE noteId=?)", arguments: [target]) == true {
                    throw AttachmentFiles.FileError.batchLocked
                }
                let directory = files.directory(for: target)
                let present = FileManager.default.fileExists(atPath: directory.path)
                    ? try FileManager.default.contentsOfDirectory(atPath: directory.path) : []
                var reserved = Set(present.map(AttachmentFiles.fileSystemKey))
                reserved.formUnion(try String.fetchAll(db,
                    sql: "SELECT filenameKey FROM attachment WHERE noteId=?", arguments: [target]))
                var imported: [ImportedAttachment] = []
                for name in request.files {
                    let data = try Self.readCaptureFile(item.appendingPathComponent(name), maxBytes: Self.maxFileBytes)
                    let planned = AttachmentFiles.uniqueCandidates(AttachmentStore.usableName(name)).first {
                        !reserved.contains(AttachmentFiles.fileSystemKey($0))
                    }!
                    reserved.insert(AttachmentFiles.fileSystemKey(planned))
                    imported.append(ImportedAttachment(filename: planned, data: data))
                }
                let batch = try files.stage(imported, noteId: target)
                staged = batch
                try AttachmentFiles.record(batch, in: db)
                let payload = Self.join(request.text, imported.map { AttachmentMarkdown.link(for: $0.filename) })
                if !payload.isEmpty {
                    _ = try NoteStore.writeText(
                        id: target, text: Self.appended(payload, to: note.text), expectedRevision: note.revision, now: now, in: db)
                }
                try Self.writeReceipt(itemId: request.itemId, noteId: target, now: now, in: db)
                return target
            }
        } catch {
            if let staged { files.discard(staged) }
            throw error
        }
        if let result {
            do { try afterNoteWrite?(result) } catch {
                staged?.lock?.release()
                throw DrainAbort(underlying: error)
            }
        }
        if let staged { files.install(staged) }
        return result
    }

    private func placeMissingFiles(
        of request: CaptureRequest, in item: URL, noteId: String, attachments: AttachmentStore
    ) throws {
        for (name, planned) in zip(request.files, Self.plannedNames(request.files)) {
            if attachments.url(for: planned, noteId: noteId) != nil { continue }
            let data = try Self.readCaptureFile(item.appendingPathComponent(name), maxBytes: Self.maxFileBytes)
            _ = try attachments.add(data: data, filename: planned, to: noteId)
        }
    }

    // MARK: - Reading and validating

    /// The request of the item folder, or nil if the item is hostile or malformed: not a real
    /// folder, no readable request, a rule broken, or a listed file that is missing, not a regular
    /// file, a symlink or too big.
    static func readRequest(in item: URL, itemId: String) throws -> CaptureRequest {
        let folder = try checkedStat(item.path)
        guard (folder.st_mode & S_IFMT) == S_IFDIR else { throw CaptureInboxError.invalidRequest("invalid item folder") }
        let data = try readCaptureFile(item.appendingPathComponent(requestFileName), maxBytes: maxRequestBytes)
        guard let request = try? JSONDecoder().decode(CaptureRequest.self, from: data),
              request.itemId == itemId, problem(in: request) == nil else {
            throw CaptureInboxError.invalidRequest("invalid request")
        }
        var total = 0
        for name in request.files {
            let file = try checkedStat(item.appendingPathComponent(name).path)
            guard (file.st_mode & S_IFMT) == S_IFREG, file.st_size >= 0, file.st_size <= Int64(maxFileBytes) else {
                throw CaptureInboxError.invalidRequest("invalid attachment")
            }
            let size = Int(file.st_size)
            total += size
        }
        guard total <= maxTotalBytes else { throw CaptureInboxError.invalidRequest("files too large") }
        return request
    }

    /// Why `request` breaks the format, or nil if it follows it.
    static func problem(in request: CaptureRequest) -> String? {
        if request.version != 1 { return "unsupported version" }
        if !isValidId(request.itemId) { return "bad item id" }
        if let target = request.targetNoteId, !isValidId(target) { return "bad target note id" }
        if request.mode == .append, request.targetNoteId == nil { return "append without a target" }
        if request.text.utf8.count > maxTextBytes { return "text too long" }
        if request.files.count > maxFiles { return "too many files" }
        if !request.files.allSatisfy(isValidFileName) { return "bad file name" }
        return nil
    }

    /// A lowercase hyphenated UUID, which is what note ids are.
    static func isValidId(_ id: String) -> Bool {
        id.utf8.count == 36 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2d }
            && UUID(uuidString: id) != nil
    }

    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name != requestFileName && name.utf8.count <= 255
            && !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: - Text and names

    /// The note names the files get: cleaned up and unique within the item (case-insensitively),
    /// the same on every drain, so the links in the text can be written before the files are placed.
    static func plannedNames(_ names: [String]) -> [String] {
        var taken = Set<String>()
        return names.map { raw in
            let base = AttachmentStore.usableName(raw)
            for candidate in AttachmentFiles.uniqueCandidates(base) where taken.insert(AttachmentFiles.fileSystemKey(candidate)).inserted {
                return candidate
            }
            return base
        }
    }

    static func join(_ text: String, _ links: [String]) -> String {
        ([text].filter { !$0.isEmpty } + links).joined(separator: "\n\n")
    }

    /// `existing` and `payload` with one blank line between them; `existing` is never changed.
    static func appended(_ payload: String, to existing: String) -> String {
        if existing.isEmpty { return payload }
        let trailing = existing.reversed().prefix { $0 == "\n" }.count
        return existing + String(repeating: "\n", count: max(0, 2 - trailing)) + payload
    }

    static func canTakeText(_ note: Note?) -> Bool {
        guard let note else { return false }
        return note.deletedAt == nil && !note.isLocked && !note.isReadOnly && note.location != .trash
    }

    // MARK: - Receipts

    /// `nil` outer: no receipt. `.some(nil)`: a receipt without a note id.
    private static func receipt(_ itemId: String, in store: NoteStore) throws -> String?? {
        try store.db.pool.read { try receipt(itemId, in: $0) }
    }

    private static func receipt(_ itemId: String, in db: Database) throws -> String?? {
        guard let row = try Row.fetchOne(db, sql: "SELECT noteId FROM capture_receipt WHERE itemId = ?", arguments: [itemId])
        else { return nil }
        return .some(row["noteId"] as String?)
    }

    private static func writeReceipt(itemId: String, noteId: String, now: Date, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO capture_receipt(itemId, noteId, processedAt) VALUES (?, ?, ?)",
            arguments: [itemId, noteId, now])
    }

    // MARK: - File system

    private func reject(_ item: URL, now: Date) {
        let fm = FileManager.default
        let rejected = directory.appendingPathComponent(Self.rejectedName, isDirectory: true)
        do {
            try fm.createDirectory(at: rejected, withIntermediateDirectories: true)
            var target = rejected.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) || (try? target.checkResourceIsReachable()) == true {
                target = rejected.appendingPathComponent("\(item.lastPathComponent)-\(UUID().uuidString)")
            }
            try fm.moveItem(at: item, to: target)
            // The clock of the retention rule starts now, not when the extension wrote the item.
            Self.setModificationDate(now, atPath: target.path)
            storeLogger.notice("capture item \(item.lastPathComponent, privacy: .public) rejected")
        } catch {
            // Never leave a hostile item to be looked at again on every drain.
            try? fm.removeItem(at: item)
            storeLogger.error("capture item \(item.lastPathComponent, privacy: .public) rejected and removed: \(error)")
        }
    }

    /// Deletes rejected items more than `rejectedAge` after their rejection (or dated more than a day
    /// ahead of `now`, which a clock jump or a planted date can cause), then the oldest beyond the
    /// newest `maxRejected`. Links are removed, never followed.
    private func pruneRejected(now: Date) {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(Self.rejectedName, isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        var kept: [(name: String, date: Date)] = []
        for name in names {
            let path = folder.appendingPathComponent(name).path
            if let date = Self.modificationDate(atPath: path),
               date >= now.addingTimeInterval(-Self.rejectedAge), date <= now.addingTimeInterval(86400) {
                kept.append((name, date))
            } else {
                remove(rejected: path)
            }
        }
        kept.sort { ($0.date, $0.name) > ($1.date, $1.name) }
        for entry in kept.dropFirst(Self.maxRejected) { remove(rejected: folder.appendingPathComponent(entry.name).path) }
    }

    private func remove(rejected path: String) {
        do { try FileManager.default.removeItem(atPath: path) } catch {
            storeLogger.error("rejected capture item not removed: \(error)")
        }
    }

    private static func modificationDate(atPath path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// Sets the modification time of the entry itself; a symlink is not followed.
    private static func setModificationDate(_ date: Date, atPath path: String) {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let spec = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
        let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), spec]
        if utimensat(AT_FDCWD, path, times, AT_SYMLINK_NOFOLLOW) != 0 {
            storeLogger.error("rejected capture item keeps its old date")
        }
    }

    private func sweepIfStale(_ tmp: URL, now: Date) {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > Self.staleTmpAge else { return }
        try? FileManager.default.removeItem(at: tmp)
    }

    private static func lstatMode(_ path: String) -> (mode: mode_t, size: Int)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT, Int(st.st_size))
    }

    /// The size of a regular file that is not a symlink, else nil.
    static func regularFileSize(atPath path: String) -> Int? {
        guard let info = lstatMode(path), info.mode == S_IFREG else { return nil }
        return info.size
    }

    private static func checkedStat(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0 else { throw readError(errno) }
        return value
    }

    private static func readError(_ code: Int32) -> any Error {
        if code == ENOENT || code == ENOTDIR || code == ELOOP {
            return CaptureInboxError.invalidRequest("file missing or invalid")
        }
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func readCaptureFile(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw readError(errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= Int64(maxBytes) else {
            throw CaptureInboxError.invalidRequest("file is not regular or too large")
        }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw CaptureInboxError.invalidRequest("file too large") }
        guard data.count == Int(st.st_size) else { throw POSIXError(.EIO) }
        return data
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

/// The notes the share extension offers for "Append to Note…". Holds ids and
/// titles of unlocked notes only, and does not exist while App Lock is enabled.
public struct RecentNotesFile: Codable, Equatable, Sendable {
    public let notes: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static let fileName = "recent-notes.json"
    static let limit = 20

    public init(notes: [Entry]) { self.notes = notes }

    /// The most recently edited notes that can take an append. Nil while App Lock is enabled.
    public static func make(store: NoteStore, appLockEnabled: Bool) throws -> RecentNotesFile? {
        guard !appLockEnabled else { return nil }
        let rows = try store.db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title FROM note
                WHERE location = 'notes' AND deletedAt IS NULL AND isLocked = 0 AND isReadOnly = 0
                ORDER BY modifiedAt DESC, id DESC LIMIT ?
                """, arguments: [limit])
        }
        return RecentNotesFile(notes: rows.map { row in
            let title: String = row["title"]
            return Entry(id: row["id"], title: title.isEmpty ? "Untitled" : title)
        })
    }
}

/// Files the app puts into the App Group container for the extensions.
public enum SharedContainerFiles {
    /// Writes `file` atomically as `recent-notes.json`; nil removes a stale one.
    public static func publish(_ file: RecentNotesFile?, in container: URL) throws {
        let target = container.appendingPathComponent(RecentNotesFile.fileName)
        guard let file else {
            do { try FileManager.default.removeItem(at: target) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(file).write(to: target, options: .atomic)
    }

    /// Whether the container really works: writes, reads back and deletes a probe file. An invalid
    /// App Group can still hand out a plausible URL.
    public static func validate(container: URL) -> Bool {
        let probe = container.appendingPathComponent(".probe-\(UUID().uuidString)")
        let payload = Data(UUID().uuidString.utf8)
        defer { try? FileManager.default.removeItem(at: probe) }
        do {
            try payload.write(to: probe)
            guard try Data(contentsOf: probe) == payload else { return false }
            try FileManager.default.removeItem(at: probe)
            return !FileManager.default.fileExists(atPath: probe.path)
        } catch {
            return false
        }
    }
}
