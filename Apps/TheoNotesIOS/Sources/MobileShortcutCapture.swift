// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import UniformTypeIdentifiers

/// One capture commits its text and attachments through the store's staged import writer.
@MainActor
final class MobileShortcutCapture {
    enum Input {
        case text(String)
        case url(URL)
        case file(data: Data, filename: String, contentType: UTType? = nil)
    }

    struct Result {
        let note: Note
        let link: URL
    }

    enum Failure: LocalizedError, Equatable {
        case emptyInput, tooLarge, invalidText, invalidURL
        var errorDescription: String? {
            switch self {
            case .emptyInput: "Share some text, a link, an image or a file to save in Theo Notes."
            case .tooLarge: "Save at most 100 items and 100 MB in one Theo Notes action."
            case .invalidText: "The shared text could not be read in its declared encoding."
            case .invalidURL: "The shared link is not a valid absolute URL."
            }
        }
    }

    static let maximumBytes = 100 * 1024 * 1024
    private let library: MobileLibrary
    init(library: MobileLibrary) { self.library = library }

    func capture(inputs: [Input], title: String? = nil) throws -> Result {
        guard !library.appLocked, !library.isClosed, !library.isClosing, !library.libraryOperationBusy else {
            throw MobileShortcutService.Failure.accessDenied
        }
        guard !inputs.isEmpty else { throw Failure.emptyInput }
        guard inputs.count <= 100 else { throw Failure.tooLarge }
        // Check the entire batch before decoding or writing any part of it.
        var remaining = Self.maximumBytes
        for input in inputs {
            let count: Int
            switch input {
            case .text(let text): count = text.utf8.count
            case .url(let url): count = url.absoluteString.utf8.count
            case .file(let data, _, _): count = data.count
            }
            guard count <= remaining else { throw Failure.tooLarge }
            remaining -= count
        }
        var sections: [String] = []
        var attachments: [ImportedAttachment] = []
        var names = Set<String>()
        var suggestedTitle: String?
        for input in inputs {
            switch input {
            case .text(let text):
                if suggestedTitle == nil { suggestedTitle = Self.firstLine(text) }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(text) }
            case .url(let url):
                guard url.scheme != nil, !url.isFileURL else { throw Failure.invalidURL }
                if suggestedTitle == nil { suggestedTitle = url.absoluteString }
                sections.append(url.absoluteString)
            case .file(let data, let filename, let contentType):
                let inferredExtension = contentType == nil ? (filename as NSString).pathExtension.lowercased() : ""
                let isURL = contentType?.conforms(to: .url) == true || inferredExtension == "url"
                let isText = contentType == .text || contentType?.conforms(to: .plainText) == true
                    || ["txt", "md", "markdown"].contains(inferredExtension)
                if isText || isURL {
                    let text = try Self.decodeText(data, contentType: contentType)
                    if isURL {
                        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                              url.scheme != nil, !url.isFileURL else { throw Failure.invalidURL }
                        if suggestedTitle == nil { suggestedTitle = url.absoluteString }
                        sections.append(url.absoluteString)
                    } else {
                        if suggestedTitle == nil { suggestedTitle = Self.firstLine(text) }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(text) }
                    }
                } else {
                    let base = AttachmentStore.usableName(filename)
                    var name = base
                    var suffix = 2
                    while names.contains(name.precomposedStringWithCanonicalMapping.lowercased()) {
                        let ext = (base as NSString).pathExtension
                        name = (base as NSString).deletingPathExtension + " \(suffix)" + (ext.isEmpty ? "" : "." + ext)
                        suffix += 1
                    }
                    names.insert(name.precomposedStringWithCanonicalMapping.lowercased())
                    attachments.append(ImportedAttachment(filename: name, data: data))
                    sections.append(AttachmentMarkdown.link(for: name))
                    if suggestedTitle == nil { suggestedTitle = (base as NSString).deletingPathExtension }
                }
            }
        }
        guard !sections.isEmpty else { throw Failure.emptyInput }
        let heading = Self.firstLine(title ?? "") ?? suggestedTitle ?? "Untitled"
        let text = "# " + heading + "\n\n" + sections.joined(separator: "\n\n")
        try library.flush()
        let now = Date.now
        let note = try library.store.importNote(ImportedNoteDraft(text: text, createdAt: now, modifiedAt: now, attachments: attachments))
        let link = Self.noteLink(id: note.id)
        try library.refreshSessions()
        try library.reveal(note.id)
        return Result(note: note, link: link)
    }

    static func noteLink(id: String) -> URL {
        var components = URLComponents()
        components.scheme = AppIdentity.current.urlSchemes[0]
        components.host = "x-callback-url"
        components.path = "/open-note"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }

    /// Only recognized text inputs reach this decoder; arbitrary binary files remain attachments.
    private static func decodeText(_ data: Data, contentType: UTType?) throws -> String {
        let bytes = Array(data.prefix(3))
        let encoding: String.Encoding
        let payload: Data
        if bytes.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            payload = Data(data.dropFirst(2))
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            payload = Data(data.dropFirst(2))
        } else if contentType?.identifier == "public.utf16-plain-text" {
            // This UTI means native byte order, unlike external UTF-16 which uses a BOM.
            encoding = UInt16(1).littleEndian == 1 ? .utf16LittleEndian : .utf16BigEndian
            payload = data
        } else if contentType?.identifier == "public.utf16-external-plain-text" {
            guard data.isEmpty else { throw Failure.invalidText }
            encoding = .utf16
            payload = data
        } else {
            encoding = .utf8
            payload = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        }
        guard let text = String(data: payload, encoding: encoding) else { throw Failure.invalidText }
        return text
    }

    private static func firstLine(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let clean = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        return String(clean.prefix(256))
    }
}
