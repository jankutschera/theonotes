// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import GRDB
import Foundation
import Testing
import WebKit
@testable import TheoNotes

/// Recognizes every file as the same text.
struct StubExtractor: TextExtracting {
    func extract(from url: URL) async -> OCRResult {
        .text("stub words", sha256: "stub-sha", byteSize: 1, modifiedAt: Date())
    }
}

/// Attachments through the real WKWebView, scheme handler and bridge (M3 Task 9): images and
/// previews load from `baerchen-asset://` under the page's CSP, the file card reads size and
/// date with a HEAD fetch, and a file dropped in the page is stored and linked.
@MainActor
@Suite(.serialized) struct EditorAttachmentIntegrationTests {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGO4GewPRwzEcQBw0hex4MqUMAAAAABJRU5ErkJggg==")!

    private static func onePagePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func imagesPreviewsAndCardsLoadThroughTheAssetScheme() async throws {
        let text = #"![](photo%202.png) [r.pdf](r.pdf)<!-- {"preview":"true","embed":"true"} --> [d.zip](d.zip)<!-- {"embed":"true"} -->"#
        let live = try LiveEditor(text: text)
        defer { live.close() }
        let store = AttachmentStore(paths: live.environment.paths, database: live.environment.database)
        _ = try store.add(data: Self.png, filename: "photo 2.png", to: live.noteId)
        _ = try store.add(data: Self.onePagePDF(), filename: "r.pdf", to: live.noteId)
        _ = try store.add(data: Data(repeating: 7, count: 2048), filename: "d.zip", to: live.noteId)
        try await live.waitUntilLoaded(text)

        try await waitUntil("image decoded") {
            (try? await live.js("return document.querySelector('.cm-bc-attachment-image img')?.naturalWidth ?? 0") as? NSNumber)?.intValue == 4
        }
        try await waitUntil("PDF first page decoded") {
            ((try? await live.js("return document.querySelector('.cm-bc-attachment-page')?.naturalHeight ?? 0") as? NSNumber)?.intValue ?? 0) > 0
        }
        try await waitUntil("file card size from HEAD") {
            (try? await live.js("return document.querySelector('.cm-bc-attachment-file .cm-bc-attachment-meta')?.textContent ?? ''") as? String)?
                .hasPrefix("2 KB") == true
        }
    }

    @Test func aFileDroppedInThePageIsStoredAndLinked() async throws {
        let live = try LiveEditor(text: "drop here")
        defer { live.close() }
        try await live.waitUntilLoaded("drop here")
        try await live.js("""
            const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            const data = new DataTransfer();
            data.items.add(new File([bytes], "image.png", { type: "image/png" }));
            const line = document.querySelector(".cm-line").getBoundingClientRect();
            const init = { bubbles: true, cancelable: true, dataTransfer: data, clientX: line.right - 1, clientY: line.top + line.height / 2 };
            const target = document.querySelector(".cm-content");
            target.dispatchEvent(new DragEvent("dragover", init));
            target.dispatchEvent(new DragEvent("drop", init));
            """, ["b64": Self.png.base64EncodedString()])
        try await live.waitUntilAcked("drop here![](image.png)")
        let stored = live.environment.paths.attachments.appendingPathComponent(live.noteId).appendingPathComponent("image.png")
        #expect(try Data(contentsOf: stored) == Self.png)
        try await waitUntil("dropped image decoded") {
            (try? await live.js("return document.querySelector('.cm-bc-attachment-image img')?.naturalWidth ?? 0") as? NSNumber)?.intValue == 4
        }
    }
    @Test func aDroppedImageIsRecognizedAfterItsLinkIsCommitted() async throws {
        let live = try LiveEditor(text: "drop here")
        defer { live.close() }
        live.environment.startOCR(extractor: StubExtractor())
        try await live.waitUntilLoaded("drop here")
        try await live.js("""
            const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            const data = new DataTransfer();
            data.items.add(new File([bytes], "image.png", { type: "image/png" }));
            const line = document.querySelector(".cm-line").getBoundingClientRect();
            const init = { bubbles: true, cancelable: true, dataTransfer: data, clientX: line.right - 1, clientY: line.top + line.height / 2 };
            const target = document.querySelector(".cm-content");
            target.dispatchEvent(new DragEvent("dragover", init));
            target.dispatchEvent(new DragEvent("drop", init));
            """, ["b64": Self.png.base64EncodedString()])
        try await live.waitUntilAcked("drop here![](image.png)")
        let database = live.environment.database
        let noteId = live.noteId
        try await waitUntil("recognized text stored") {
            let text = try? database.pool.read {
                try String.fetchOne($0, sql: "SELECT ocrText FROM attachment WHERE noteId = ?", arguments: [noteId])
            }
            return text == "stub words"
        }
    }
}
