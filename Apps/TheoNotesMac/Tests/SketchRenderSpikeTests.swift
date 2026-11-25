// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Testing
import TheoNotesCore
import WebKit
@testable import TheoNotes

/// Task5 only: actual pixels from the frozen real-PKDrawing PNG, not HTML tag assertions.
/// Like NoteRendererTests, WebKit snapshot/printing requires an unlocked WindowServer (R34).
/// These tests do not prove the full interactive Mac editor UI, Pencil input, or preservation
/// of editable drawing metadata after PDF rasterization. No production library is used.
@Suite(.serialized) @MainActor final class SketchRenderSpikeTests {
    private let root: URL
    private let environment: AppEnvironment
    private let png: Data
    private let note: Note

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesSketchRender-" + UUID().uuidString)
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        png = try Data(contentsOf: repository.appendingPathComponent("Fixtures/sketch/one-stroke.png"))
        environment = try AppEnvironment(paths: AppPaths(root: root))
        note = try environment.store.importNote(ImportedNoteDraft(
            text: "Sketch Render Spike\n\n![](one-stroke.png)\n", createdAt: .now, modifiedAt: .now,
            attachments: [ImportedAttachment(filename: "one-stroke.png", data: png)]))
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    private func expectFrozenFixture() {
        #expect(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() ==
            "b230e42019b40ffab7c458df722d7f01dc16da14ff8fd17afc84264ef83525bb")
    }
    private func request() throws -> RenderRequest {
        let look = environment.appearance.exportLook(themeId: nil)
        return try RenderRequestBuilder(store: environment.store, paths: environment.paths).request(
            for: note, mode: .document, theme: look.theme, appearance: look.appearance,
            typography: look.typography, attachments: .assetURLs, wikiLinks: .none, keepTags: true)
    }
    private func export(_ settings: ExportSettings) async throws -> URL {
        let directory = root.appendingPathComponent("export-" + UUID().uuidString)
        let plan = ExportPlan.selection(try environment.store.exportCandidates(ids: [note.id]))
        let report = await ExportJob(environment: environment, renderer: NoteRenderer(environment: environment))
            .run(plan, settings: settings, destination: directory, progress: { _, _ in }, isCancelled: { false })
        #expect(report.errors.isEmpty && report.missingAttachments.isEmpty)
        #expect(report.exported == 1)
        return directory
    }

    @Test func assetSchemeServesExactSketchAndWebKitDecodesAndPaintsIt() async throws {
        expectFrozenFixture()
        let renderRequest = try request()
        let source = try #require(renderRequest.attachmentSources["one-stroke.png"])
        let url = try #require(URL(string: source))
        let attachments = AttachmentStore(paths: environment.paths, database: environment.database)
        let response = AssetSchemeHandler(attachments: attachments).response(for: url)
        #expect(response.statusCode == 200 && response.headers["Content-Type"] == "image/png")
        #expect(response.body == png)
        let imageSource = try #require(CGImageSourceCreateWithData(response.body as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == 96 && image.height == 64)
        #expect(try bluePixels(image) > 10)

        let renderer = NoteRenderer(environment: environment)
        _ = try await renderer.render(renderRequest)
        try await expectDecodedImageAndPaintedBlueStroke(renderer.webView)
    }

    @Test(arguments: [false, true])
    func exportedHTMLReallyLoadsAndPaintsTheSketch(embedImages: Bool) async throws {
        expectFrozenFixture()
        let directory = try await export(ExportSettings(format: .html, keepTags: true, htmlEmbedImages: embedImages))
        let html = directory.appendingPathComponent("Sketch Render Spike.html")
        let text = try String(contentsOf: html, encoding: .utf8)
        if embedImages {
            #expect(text.contains("data:image/png;base64," + png.base64EncodedString()))
        } else {
            #expect(try Data(contentsOf: directory.appendingPathComponent("Sketch Render Spike/one-stroke.png")) == png)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadFileURL(html, allowingReadAccessTo: directory)
        try await expectDecodedImageAndPaintedBlueStroke(webView)
    }

    @Test func exportedPDFContainsRasterizedBlueSketchPixels() async throws {
        expectFrozenFixture()
        let directory = try await export(ExportSettings(format: .pdf, keepTags: true))
        let document = try #require(PDFDocument(url: directory.appendingPathComponent("Sketch Render Spike.pdf")))
        #expect(document.pageCount > 0)
        #expect((document.string ?? "").contains("Sketch Render Spike"))
        var found = false
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            let image = page.thumbnail(of: NSSize(width: 612, height: 842), for: .mediaBox)
            if let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil), try bluePixels(raster) > 10 { found = true }
        }
        #expect(found, "Actual PDF raster must contain the blue drawing, not only a title or image tag.")
    }

    private func expectDecodedImageAndPaintedBlueStroke(_ view: WKWebView) async throws {
        var decoded = false
        for _ in 0..<200 {
            if let dimensions = try? await view.callAsyncJavaScript("""
                const image = document.querySelector('img');
                if (!image) throw new Error('image not mounted');
                await image.decode();
                return [image.naturalWidth, image.naturalHeight];
                """, arguments: [:], in: nil, contentWorld: .page) as? [Int], dimensions == [96, 64] {
                decoded = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(decoded, "WebKit did not decode the real attachment at its 96x64 dimensions.")
        let snapshot = try await view.takeSnapshot(configuration: nil)
        let raster = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(try bluePixels(raster) > 10, "Decoded attachment must also paint into a real WebKit snapshot.")
    }
    private func bluePixels(_ image: CGImage) throws -> Int {
        let size = image.width * image.height * 4
        var pixels = [UInt8](repeating: 0, count: size)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index + 2] > 153 && pixels[index] < 115 && pixels[index + 1] < 153 && pixels[index + 3] > 127 { count += 1 }
        }
        return count
    }
}
