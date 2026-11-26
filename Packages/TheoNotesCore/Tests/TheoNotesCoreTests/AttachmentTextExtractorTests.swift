// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import PDFKit
import Synchronization
import Testing
import Vision
@testable import TheoNotesCore

final class RenderLog: Sendable {
    let pages = Mutex<[Int]>([])
}

/// Fixtures are generated here; no binary files are committed.
@Suite struct AttachmentTextExtractorTests {
    let dir: URL
    let extractor = AttachmentTextExtractor()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-extractor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Whether Apple's text recognition reads a rendered line on this machine at all. On GitHub's macOS virtual
    /// machines Vision answers `.failed` after about 100 s for every image, so the tests that need it are skipped there
    /// with this reason; on a Mac where Vision works they run unchanged. Bounded so a silent Vision cannot hang the suite.
    static let visionReadsText: Bool = {
        let image = renderedImage("Probe 42")
        let found = Mutex(false)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "test.vision-probe").async {
            let request = VNRecognizeTextRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let read = (request.results ?? []).contains { $0.topCandidates(1).first?.string.contains("42") == true }
            found.withLock { $0 = read }
            done.signal()
        }
        return done.wait(timeout: .now() + 60) == .success && found.withLock { $0 }
    }()

    // MARK: Fixtures

    /// `text` in black on white, `size` pixels.
    static func renderedImage(_ text: String, size: CGSize = CGSize(width: 1200, height: 300), fontSize: CGFloat = 110) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.black,
        ]).draw(at: CGPoint(x: 30, y: size.height / 2 - fontSize / 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    func writePNG(_ image: CGImage, as name: String = "shot.png") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    /// One PDF page per closure; the closure draws into the current graphics context.
    func writePDF(
        _ pages: [(CGContext) -> Void], as name: String = "doc.pdf", size: CGSize = CGSize(width: 612, height: 792)
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for draw in pages {
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func textPage(_ text: String) -> (CGContext) -> Void {
        { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20)])
                .draw(in: CGRect(x: 40, y: 40, width: 530, height: 700))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Tests

    @Test(.enabled(if: visionReadsText, "Vision text recognition does not work on this machine (for example GitHub's macOS virtual machines)")) func testRecognizesTextInARenderedPNG() async throws {
        let url = try writePNG(Self.renderedImage("Baerchen OCR 2026"))
        let result = await extractor.extract(from: url)
        guard case let .text(text, sha256, byteSize, modifiedAt) = result else {
            Issue.record("expected text, got \(result)")
            return
        }
        #expect(text.contains("OCR"))
        #expect(sha256.count == 64 && sha256.allSatisfy(\.isHexDigit))
        #expect(byteSize == (try Data(contentsOf: url)).count)
        #expect(abs(modifiedAt.timeIntervalSinceNow) < 900)
    }

    @Test func testTextPDFUsesPDFKit() async throws {
        let url = try writePDF([Self.textPage("Invoice number 4711 for the Quartz suite")])
        let result = await extractor.extract(from: url)
        guard case let .text(text, sha256, _, _) = result else {
            Issue.record("expected text, got \(result)")
            return
        }
        #expect(text.contains("Invoice number 4711"))
        #expect(sha256.count == 64)
    }

    @Test(.enabled(if: visionReadsText, "Vision text recognition does not work on this machine (for example GitHub's macOS virtual machines)")) func testScannedPDFPageFallsBackToVision() async throws {
        let image = Self.renderedImage("Baerchen OCR 2026")
        let scan: (CGContext) -> Void = { context in
            context.draw(image, in: CGRect(x: 0, y: 300, width: 612, height: 153))
        }
        let url = try writePDF([scan])
        let layer = (PDFDocument(url: url)?.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(layer.isEmpty)
        guard case let .text(text, _, _, _) = await extractor.extract(from: url) else {
            Issue.record("expected text from the scanned page")
            return
        }
        #expect(text.contains("OCR"))
    }

    @Test func testOnlyPagesWithoutATextLayerAreRendered() async throws {
        let image = Self.renderedImage("Scanned Zebra", fontSize: 110)
        let scan: (CGContext) -> Void = { $0.draw(image, in: CGRect(x: 0, y: 300, width: 612, height: 153)) }
        let url = try writePDF([Self.textPage("A page with a real text layer"), scan, Self.textPage("Another page with real text")])
        let rendered = RenderLog()
        var counting = AttachmentTextExtractor()
        counting.pageRendered = { index in rendered.pages.withLock { $0.append(index) } }
        guard case .text = await counting.extract(from: url) else {
            Issue.record("expected text")
            return
        }
        #expect(rendered.pages.withLock { $0 } == [1])
    }

    @Test func testPagesAreRenderedAtTwiceTheirSizeUpToTheLongEdgeCap() throws {
        func pixels(_ url: URL, rotation: Int = 0) throws -> (Int, Int) {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            page.rotation = rotation
            let image = try #require(extractor.renderedImage(of: page))
            return (image.width, image.height)
        }
        // 2x, whatever the screen's backing scale is.
        let letter = try writePDF([{ _ in }])
        #expect(try pixels(letter) == (1224, 1584))
        // A turned page swaps the sides.
        #expect(try pixels(letter, rotation: 90) == (1584, 1224))
        // Long edge capped at 2,500 px.
        let poster = try writePDF([{ _ in }], as: "poster.pdf", size: CGSize(width: 5000, height: 3000))
        #expect(try pixels(poster) == (2500, 1500))
    }

    @Test(.enabled(if: visionReadsText, "Vision text recognition does not work on this machine (for example GitHub's macOS virtual machines)")) func testAPageWithEnoughTextIsNotRenderedForVision() async throws {
        // The text page has a PDF text layer, the scanned one only pixels; both end up in the result.
        let image = Self.renderedImage("Scanned Zebra", fontSize: 110)
        let scan: (CGContext) -> Void = { $0.draw(image, in: CGRect(x: 0, y: 300, width: 612, height: 153)) }
        let url = try writePDF([Self.textPage("A page with a real text layer"), scan])
        guard case let .text(text, _, _, _) = await extractor.extract(from: url) else {
            Issue.record("expected text")
            return
        }
        #expect(text.contains("real text layer"))
        #expect(text.localizedCaseInsensitiveContains("Zebra"))
    }

    @Test func testUnknownTypeIsNone() async throws {
        let url = dir.appendingPathComponent("archive.zip")
        try Data([0x50, 0x4B, 3, 4, 0, 0]).write(to: url)
        guard case let .none(sha256) = await extractor.extract(from: url) else {
            Issue.record("expected none")
            return
        }
        #expect(sha256 == nil)
        let noExtension = dir.appendingPathComponent("README")
        try Data("hello".utf8).write(to: noExtension)
        guard case .none = await extractor.extract(from: noExtension) else {
            Issue.record("expected none for a file without extension")
            return
        }
    }

    @Test(.enabled(if: visionReadsText, "Vision text recognition does not work on this machine (for example GitHub's macOS virtual machines)")) func testOversizedImageIsSkipped() async throws {
        let url = try writePNG(Self.renderedImage("Big"))
        // 1200 x 300 = 360,000 pixels.
        let strict = AttachmentTextExtractor(maxImagePixels: 359_999)
        guard case .skipped = await strict.extract(from: url) else {
            Issue.record("expected skipped")
            return
        }
        guard case .text = await AttachmentTextExtractor(maxImagePixels: 360_000).extract(from: url) else {
            Issue.record("an image exactly at the cap is recognized")
            return
        }
        #expect(AttachmentTextExtractor().maxImagePixels == 50_000_000)
    }

    @Test func testOversizedFileIsSkipped() async throws {
        let url = try writePNG(Self.renderedImage("Big"))
        let size = try Data(contentsOf: url).count
        guard case .skipped = await AttachmentTextExtractor(maxFileBytes: size - 1).extract(from: url) else {
            Issue.record("expected skipped")
            return
        }
        #expect(AttachmentTextExtractor().maxFileBytes == 200 * 1024 * 1024)
    }

    @Test func testMissingFileIsMissing() async {
        guard case .missing = await extractor.extract(from: dir.appendingPathComponent("gone.png")) else {
            Issue.record("expected missing")
            return
        }
    }

    private func encrypted(
        _ options: [PDFDocumentWriteOption: Any], as name: String, text: String = "Top secret invoice text here"
    ) throws -> URL {
        let plain = try writePDF([Self.textPage(text)], as: "plain-\(name)")
        let url = dir.appendingPathComponent(name)
        let document = try #require(PDFDocument(url: plain))
        #expect(document.write(to: url, withOptions: options))
        return url
    }

    @Test func testAPDFThatNeedsAPasswordIsNone() async throws {
        let url = try encrypted([.userPasswordOption: "user", .ownerPasswordOption: "owner"], as: "locked.pdf")
        let document = try #require(PDFDocument(url: url))
        #expect(document.isEncrypted && document.isLocked)
        guard case .none = await extractor.extract(from: url) else {
            Issue.record("expected none for a locked PDF")
            return
        }
    }

    @Test func testAPDFThatForbidsCopyingIsNoneAndOneThatAllowsItIsIndexed() async throws {
        // Owner password only: opens without a password; the permissions decide.
        let forbidden = try encrypted(
            [.ownerPasswordOption: "owner", .accessPermissionsOption: 3 /* printing only */], as: "nocopy.pdf")
        let forbiddenDocument = try #require(PDFDocument(url: forbidden))
        #expect(forbiddenDocument.isEncrypted && !forbiddenDocument.isLocked && !forbiddenDocument.allowsCopying)
        guard case .none = await extractor.extract(from: forbidden) else {
            Issue.record("expected none when copying is forbidden")
            return
        }

        let allowed = try encrypted(
            [.ownerPasswordOption: "owner",
             .accessPermissionsOption: 3 | 16 /* printing and copying */], as: "copy.pdf")
        let allowedDocument = try #require(PDFDocument(url: allowed))
        #expect(allowedDocument.isEncrypted && !allowedDocument.isLocked && allowedDocument.allowsCopying)
        guard case let .text(text, _, _, _) = await extractor.extract(from: allowed) else {
            Issue.record("expected text when copying is allowed")
            return
        }
        #expect(text.contains("Top secret invoice"))
    }

    @Test(.enabled(if: visionReadsText, "Vision text recognition does not work on this machine (for example GitHub's macOS virtual machines)")) func testAKnownHashIsUsedInsteadOfHashingAgain() async throws {
        let url = try writePNG(Self.renderedImage("Baerchen OCR 2026"))
        guard case let .text(_, sha256, _, _) = await extractor.extract(from: url, knownSHA256: "from-the-caller") else {
            Issue.record("expected text")
            return
        }
        #expect(sha256 == "from-the-caller")
    }

    @Test func testPageAndCharacterCapsApply() async throws {
        let pages = (1...4).map { Self.textPage("Page \($0) alpha beta gamma delta epsilon") }
        let url = try writePDF(pages)
        guard case let .text(first, _, _, _) = await AttachmentTextExtractor(maxPages: 2).extract(from: url) else {
            Issue.record("expected text")
            return
        }
        #expect(first.contains("Page 2") && !first.contains("Page 3"))

        // Cut at a word boundary: "Page 1 alpha beta gam" must not end in a half word.
        guard case let .text(cut, _, _, _) = await AttachmentTextExtractor(maxCharacters: 21).extract(from: url) else {
            Issue.record("expected text")
            return
        }
        #expect(cut.count <= 21, "\(cut.debugDescription)")
        #expect(cut.hasSuffix("beta"))
        let defaults = AttachmentTextExtractor()
        #expect(defaults.maxPages == 50 && defaults.maxCharacters == 100_000 && defaults.minimumPageCharacters == 16)
    }
}
