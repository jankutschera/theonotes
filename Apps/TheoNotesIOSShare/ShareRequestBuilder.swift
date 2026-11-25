// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Darwin

/// Inbox payload and picker validation, independent of the extension UI.
enum ShareRequestBuilder {
    /// iOS group is supplied by the same build setting as the app entitlement; never use the Mac group.
    static var groupIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "THEONOTES_AppGroupIdentifier") as? String,
              value.hasPrefix("group."), !value.contains("$(") else { return nil }
        return value
    }
    /// How many notes the picker offers; the app never writes more (FOC-R12).
    static let pickerLimit = 20
    /// `recent-notes.json` is at most a few kilobytes; anything bigger was not written by the app.
    static let recentNotesMaxBytes = 256 * 1024
    /// A file name stays well under the 255 bytes the inbox accepts, so a numbered copy still fits.
    static let fileNameMaxBytes = 200

    // MARK: - Ids

    /// A lowercase hyphenated UUIDv7, the shape of a note id, which sorts by time: the app drains items in
    /// name order, so what was shared first is saved first.
    static func itemId(now: Date = .now) -> String {
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        for index in 0..<6 { bytes[index] = UInt8((milliseconds >> UInt64(8 * (5 - index))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }

    // MARK: - Text

    /// The shared text parts as the sheet first shows them: each exactly as it came (no trimming, no
    /// merging of repeats), separated by a blank line. Only a part that is empty is left out.
    static func joinText(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Files

    /// A name the inbox accepts: no path separators or control characters, not the request file's name,
    /// not empty, not too long (the extension is kept), and different from every name in `taken` ignoring
    /// case. The returned name is added to `taken`.
    static func safeFileName(_ raw: String, taken: inout Set<String>) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", "\\", ":": scalars.append(" ")
            default: if scalar.value >= 0x20 && scalar.value != 0x7F { scalars.append(scalar) }
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "." || name == ".." { name = "file" }
        var base = (name as NSString).deletingPathExtension
        var ext = (name as NSString).pathExtension
        if ext.utf8.count > 20 { ext = String(ext.prefix(20)) }
        let suffix = ext.isEmpty ? "" : "." + ext
        while (base + suffix).utf8.count > fileNameMaxBytes, !base.isEmpty { base.removeLast() }
        if base.isEmpty { base = "file" }

        var number = 1
        var candidate = base + suffix
        while candidate.lowercased() == "request.json" || !taken.insert(candidate.lowercased()).inserted {
            number += 1
            candidate = "\(base) \(number)\(suffix)"
        }
        return candidate
    }

    /// Copies `source` into `directory` under a safe unique name and returns the copy. The original stays.
    static func stage(
        _ source: URL, suggestedName: String?, into directory: URL, taken: inout Set<String>,
        afterRead: ((Int) throws -> Void)? = nil
    ) throws -> URL {
        let name = safeFileName(suggestedName ?? source.lastPathComponent, taken: &taken)
        let target = directory.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        let limit = 25 * 1024 * 1024
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else {
            throw CaptureInboxError.invalidRequest("file too large or not regular")
        }
        let outputFD = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: target) }
        }
        var count = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: min(64 * 1024, limit - count + 1)), !chunk.isEmpty else { break }
            count += chunk.count
            guard count <= limit else { throw CaptureInboxError.invalidRequest("file too large") }
            try output.write(contentsOf: chunk)
            // The test seam changes a source deterministically while its descriptor stays open.
            try afterRead?(count)
        }
        var after = stat()
        var current = stat()
        guard count == before.st_size, fstat(fd, &after) == 0, lstat(source.path, &current) == 0,
              sameFile(before, after), sameFile(before, current) else {
            throw CaptureInboxError.invalidRequest("file changed while copying")
        }
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        complete = true
        return target
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    // MARK: - Request

    /// A save request, or an append when `target` names a note.
    static func request(itemId: String, target: String?, text: String, files: [URL]) -> CaptureRequest {
        CaptureRequest(
            itemId: itemId, mode: target == nil ? .save : .append, targetNoteId: target, text: text,
            files: files.map(\.lastPathComponent))
    }

    // MARK: - Picker

    /// The notes `recent-notes.json` offers. A missing, unreadable, oversized or malformed file gives
    /// none, and so does one the app removed (App Lock enabled): the sheet then offers Save only.
    /// Entries need a lowercase UUID and a title, and at most `pickerLimit` are kept.
    static func recentNotes(inContainer container: URL) -> [RecentNotesFile.Entry] {
        let url = container.appendingPathComponent(RecentNotesFile.fileName)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        guard let data = try? handle.read(upToCount: recentNotesMaxBytes + 1), data.count <= recentNotesMaxBytes,
              let file = try? JSONDecoder().decode(RecentNotesFile.self, from: data)
        else { return [] }
        let valid = file.notes.filter { entry in
            !entry.title.isEmpty && entry.id == entry.id.lowercased() && UUID(uuidString: entry.id) != nil
        }
        return Array(valid.prefix(pickerLimit))
    }
}
