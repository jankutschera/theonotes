// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BaerchenIOS

@Suite @MainActor
struct MobileShortcutCaptureTests {
    private func library() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("capture-" + UUID().uuidString)))
    }

    @Test func shortcutTextInfersTitleAndReturnsReopenableLink() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let source = "Café 👩‍💻\nKeep **Markdown** & spaces  "
        let result = try MobileShortcutCapture(library: library).capture(inputs: [
            .file(data: Data(source.utf8), filename: "Text.txt", contentType: .plainText)
        ])
        #expect(result.note.title == "Café 👩‍💻")
        #expect(result.note.text == "# Café 👩‍💻\n\n" + source)
        #expect(library.selectedID == result.note.id)
        let components = try #require(URLComponents(url: result.link, resolvingAgainstBaseURL: false))
        #expect(components.scheme == AppIdentity.current.urlSchemes[0] && components.host == "x-callback-url" && components.path == "/open-note")
        #expect(components.queryItems == [URLQueryItem(name: "id", value: result.note.id)])
        try library.close()
        let reopened = try MobileLibrary(paths: library.paths)
        defer { try? reopened.close() }
        #expect(try reopened.store.note(id: result.note.id)?.text == result.note.text)
    }

    @Test func mixedAttachmentsKeepBytesResolveCollisionsAndHonorExplicitTitle() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let first = Data([0, 1, 2, 255]), second = Data([9, 8, 7])
        let url = try #require(URL(string: "https://example.com/a?q=🐻&other=value#heading"))
        let result = try MobileShortcutCapture(library: library).capture(inputs: [
            .file(data: first, filename: "photo.png", contentType: .png),
            .file(data: second, filename: "photo.png", contentType: .png), .url(url)
        ], title: "My capture\nignore heading injection")
        #expect(result.note.title == "My capture")
        #expect(result.note.text.contains("![](photo.png)"))
        #expect(result.note.text.contains("![](photo%202.png)"))
        #expect(result.note.text.contains(url.absoluteString))
        let files = AttachmentStore(paths: library.paths, database: library.database)
        #expect(try Data(contentsOf: #require(files.url(for: "photo.png", noteId: result.note.id))) == first)
        #expect(try Data(contentsOf: #require(files.url(for: "photo 2.png", noteId: result.note.id))) == second)
    }

    @Test func malformedBatchNeverCreatesAnEarlierValidItem() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let capture = MobileShortcutCapture(library: library)
        #expect(throws: MobileShortcutCapture.Failure.invalidText) {
            try capture.capture(inputs: [.file(data: Data([1]), filename: "valid.pdf"),
                                         .file(data: Data([255]), filename: "Text.txt", contentType: .plainText)])
        }
        #expect(throws: MobileShortcutCapture.Failure.emptyInput) { try capture.capture(inputs: [.text(" \n\t")]) }
        #expect(throws: MobileShortcutCapture.Failure.tooLarge) { try capture.capture(inputs: Array(repeating: .text("x"), count: 101)) }
        #expect(throws: MobileShortcutCapture.Failure.invalidURL) { try capture.capture(inputs: [.url(URL(fileURLWithPath: "/tmp/no"))]) }
        #expect(try library.store.allNotes().isEmpty)
        #expect(library.selectedID == nil)
        try library.close()
        #expect(throws: MobileShortcutService.Failure.accessDenied) { try capture.capture(inputs: [.text("closed")]) }
    }

    @Test func fileOnlyCaptureUsesFilenameAndURLInputDoesNotFetch() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let capture = MobileShortcutCapture(library: library)
        let file = try capture.capture(inputs: [.file(data: Data(), filename: "Quarterly report.pdf", contentType: .pdf)])
        #expect(file.note.title == "Quarterly report")
        let url = "https://does-not-exist.invalid/private?token=one&two=three"
        let link = try capture.capture(inputs: [.file(data: Data(url.utf8), filename: "URL", contentType: .url)])
        #expect(link.note.text == "# " + url + "\n\n" + url)
    }
    @Test func genericAndFilenameTextInputsInferContentTitle() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let capture = MobileShortcutCapture(library: library)
        for (name, type) in [("Text", UTType.text as UTType?), ("Text.txt", nil), ("Note.md", nil), ("Note.markdown", nil)] {
            let note = try capture.capture(inputs: [.file(data: Data("Actual title 🐻\nBody".utf8), filename: name, contentType: type)]).note
            #expect(note.title == "Actual title 🐻")
            #expect(note.text == "# Actual title 🐻\n\nActual title 🐻\nBody")
        }
    }

    @Test func utf16HandlesDeclaredNativeOrderAndBothByteOrderMarks() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let source = "Unicode 🐻\nCafé"
        let native: String.Encoding = UInt16(1).littleEndian == 1 ? .utf16LittleEndian : .utf16BigEndian
        let declared = try #require(UTType("public.utf16-plain-text"))
        let external = try #require(UTType("public.utf16-external-plain-text"))
        let variants: [(Data, UTType?)] = [
            (try #require(source.data(using: native)), declared),
            (Data([0xFF, 0xFE]) + (try #require(source.data(using: .utf16LittleEndian))), external),
            (Data([0xFE, 0xFF]) + (try #require(source.data(using: .utf16BigEndian))), nil)
        ]
        for (bytes, type) in variants {
            let result = try MobileShortcutCapture(library: library).capture(inputs: [.file(data: bytes, filename: "Text.txt", contentType: type)])
            #expect(result.note.title == "Unicode 🐻")
            #expect(result.note.text == "# Unicode 🐻\n\n" + source)
        }
    }

    @Test func unspecifiedBinaryAndRichTextRemainUnchangedAttachments() throws {
        let library = try library()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let bytes = Data([0xFF, 0xFE, 0, 0xFF, 7])
        for (name, type) in [("payload.bin", nil), ("page.html", UTType.html as UTType?), ("Text.txt", UTType.data as UTType?)] {
            let result = try MobileShortcutCapture(library: library).capture(inputs: [.file(data: bytes, filename: name, contentType: type)])
            let url = try #require(AttachmentStore(paths: library.paths, database: library.database).url(for: name, noteId: result.note.id))
            #expect(try Data(contentsOf: url) == bytes)
            #expect(result.note.text.contains(AttachmentMarkdown.link(for: name)))
        }
    }

}
