// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Captures only persistently unprotected notes. Authentication never grants export access.
/// Keep the capture through all suspension points and revalidate immediately at publication.
@MainActor
final class MobileExportAccess {
    private let library: MobileLibrary
    let notes: [Note]
    private(set) var plainText = ""
    /// Observable only within the module: true across the actual renderer suspension.
    private(set) var isRendering = false

    init(library: MobileLibrary, ids: [String]) throws {
        self.library = library
        guard !library.appLocked else { throw CocoaError(.fileReadNoPermission) }
        notes = try Set(ids).sorted().compactMap { id in
            guard let note = try library.store.note(id: id), !note.isLocked else { return nil }
            return note
        }
    }

    func validate() throws {
        try Task.checkCancellation()
        guard !library.appLocked, !notes.isEmpty,
              try notes.allSatisfy({ try library.store.note(id: $0.id).map { !$0.isLocked } == true }) else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    @discardableResult
    func publish<T>(_ action: () throws -> T) throws -> T {
        try validate()
        return try action()
    }

    /// `selection` replaces the note's text as the source (Copy As of selected text). `copy` applies "Keep Tags" to Markdown too:
    /// exports keep Markdown tags as written, Copy As follows the setting (A10).
    func document(format: MobileExportFormat, preferences: MobilePreferences, dark: Bool,
                  selection: String? = nil, copy: Bool = false) async throws -> FileWrapper {
        try validate()
        guard notes.count == 1, let note = notes.first else { throw CocoaError(.fileReadUnknown) }
        let source = selection ?? note.text
        plainText = source
        let wrapper: FileWrapper
        switch format {
        case .markdown:
            plainText = copy && !preferences.keepTagsOnExport ? ExportText.removingTags(source) : source
            wrapper = FileWrapper(regularFileWithContents: Data(plainText.utf8))
        case .textBundle:
            wrapper = try NoteExport.textBundle(note: note, includeAttachments: preferences.exportIncludeAttachments,
                                                attachmentURL: { try library.attachmentURL($0, noteID: note.id) })
        default:
            let appearance = MobileRenderedExport.appearance(format: format, preferences: preferences, dark: dark)
            let renderer = MobileBatchRenderer()
            defer { renderer.cancel(); isRendering = false }
            isRendering = true
            let rendered = try await renderer.render(source: source,
                attachments: format == .plainText ? [:] : exportImages(note), keepTags: preferences.keepTagsOnExport,
                wikiLinks: [:], foreground: appearance.foreground)
            try validate()
            plainText = rendered.text
            let html = MobileRenderedExport.document(body: rendered.html, title: note.title, preferences: preferences, dark: appearance.dark)
            let data: Data
            switch format {
            case .plainText: data = Data(rendered.text.utf8)
            case .html: data = Data(html.utf8)
            case .rtf: data = try await MobileRenderedExport.rtf(html)
            case .pdf:
                let document = MobileRenderedExport()
                try await document.load(html)
                try validate()
                data = try document.pdf(title: note.title)
            default: throw CocoaError(.fileWriteUnsupportedScheme)
            }
            wrapper = FileWrapper(regularFileWithContents: data)
        }
        try validate()
        return wrapper
    }

    func exportImages(_ note: Note) throws -> [String: String] {
        try validate()
        guard notes.contains(where: { $0.id == note.id }), !note.isLocked else { throw CocoaError(.fileReadNoPermission) }
        var images: [String: String] = [:], total = 0
        for attachment in NoteParser.metadata(for: note.text).attachments where attachment.isImage && images[attachment.filename] == nil {
            guard let url = try library.attachmentURL(attachment.filename, noteID: note.id) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "An image is missing: " + attachment.filename])
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 * 1024 - total else {
                throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "These images are too large for a rendered export. Export a TextBundle to keep the original files."])
            }
            var bytes = try Data(contentsOf: url)
            var mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
            if !["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
                guard let converted = UIImage(data: bytes)?.pngData() else { throw CocoaError(.fileReadCorruptFile) }
                bytes = converted; mime = "image/png"
            }
            total += bytes.count
            guard total <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            images[attachment.filename] = "data:" + mime + ";base64," + bytes.base64EncodedString()
        }
        return images
    }

}
