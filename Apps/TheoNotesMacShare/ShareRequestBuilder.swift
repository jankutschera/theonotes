// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// The parts of the share extension that need no window: ids, file names, the request and the list of
/// notes to append to. Compiled into the extension and, for its tests, into `TheoNotesMacTests` (FOC-R334).
enum ShareRequestBuilder {
    /// The App Group shared with the app: the team id, a dot and the group name (how macOS writes it).
    /// The identity (production or dev) comes from the bundle id of the extension (FOC-R360).
    static var groupIdentifier: String { AppIdentity.current.appGroupIdentifier }
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
    static func stage(_ source: URL, suggestedName: String?, into directory: URL, taken: inout Set<String>) throws -> URL {
        let name = safeFileName(suggestedName ?? source.lastPathComponent, taken: &taken)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        return target
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
        guard let data = try? handle.read(upToCount: recentNotesMaxBytes + 1), data.count <= recentNotesMaxBytes,
              let file = try? JSONDecoder().decode(RecentNotesFile.self, from: data)
        else { return [] }
        let valid = file.notes.filter { entry in
            !entry.title.isEmpty && entry.id == entry.id.lowercased() && UUID(uuidString: entry.id) != nil
        }
        return Array(valid.prefix(pickerLimit))
    }
}
