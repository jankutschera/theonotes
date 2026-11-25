// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import PDFKit
import Testing
import UIKit
@testable import BaerchenIOS

@Suite @MainActor struct MobileRenderedExportTests {
    @Test func headingFontMigratesMatchesTextAndPersistsIndependently() throws {
        let legacy = try JSONDecoder().decode(MobilePreferences.self, from: Data(#"{"textFont":"georgia"}"#.utf8))
        #expect(legacy.headingFont == "text" && legacy.headingFontFamily == "Georgia")
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("heading-font-" + UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        library.preferences = legacy
        library.preferences.headingFont = "palatino"
        library.preferences.codeFont = "menlo"
        try library.savePreferences()
        let restored = try library.settings.value(.mobilePreferences)
        #expect(restored.textFontFamily == "Georgia")
        #expect(restored.headingFontFamily == "Palatino")
        #expect(restored.codeFontFamily == "Menlo")
        var system = restored
        system.headingFont = "system"
        #expect(system.headingFontFamily == "-apple-system")
        system.headingFont = "text"
        #expect(system.headingFontFamily == "Georgia")
    }

    @Test func exportUsesIndependentHeadingFontAndRejectsUnsafeFamilies() {
        var preferences = MobilePreferences()
        preferences.textFont = "georgia"
        preferences.headingFont = "palatino"
        let html = MobileRenderedExport.document(body: "<h1>Heading</h1><p>Body</p>", title: "Font export", preferences: preferences, dark: false)
        #expect(html.contains("h1,h2,h3,h4,h5,h6{font-family:\"Palatino\""))
        #expect(html.contains("font-family:\"Georgia\""))
        preferences.headingFont = "bad;}</style><script>"
        #expect(preferences.headingFontFamily == "Georgia")
        let safe = MobileRenderedExport.document(body: "<h1>Heading</h1>", title: "Safe", preferences: preferences, dark: false)
        #expect(!safe.contains("bad;"))
        #expect(safe.contains("h1,h2,h3,h4,h5,h6{font-family:\"Georgia\""))
    }

    @Test func pdfIncludesAllPagesAndRTFPreservesUnicodeAndFormatting() async throws {
        let paragraphs = (0..<100).map { "<p>Paragraph \($0): a complete note with <strong>bold text</strong>.</p>" }.joined()
        let html = MobileRenderedExport.document(body: "<h1>Export</h1>" + paragraphs + "<p>FINAL café 日本語</p>",
            title: "Test export", preferences: MobilePreferences(), dark: false)
        let renderer = MobileRenderedExport()
        try await renderer.load(html)
        let data = try renderer.pdf(title: "Test export")
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Paragraph 99") == true)
        #expect(pdf.string?.contains("FINAL") == true)
        let rich = try await MobileRenderedExport.rtf(html)
        let restored = try NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(restored.string.contains("FINAL café 日本語"))
        let bold = (restored.string as NSString).range(of: "bold text")
        let font = try #require(restored.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test func exportDocumentEscapesTitleAndBlocksExternalResources() {
        let html = MobileRenderedExport.document(body: "<p>Body</p>", title: "</title><script>bad()</script>",
            preferences: MobilePreferences(), dark: false)
        #expect(!html.contains("<script>"))
        #expect(html.contains("default-src 'none'; img-src data:"))
        #expect(html.contains("&lt;/title&gt;"))
    }
}

@Suite(.serialized) @MainActor struct MobileRichImageExportTests {
    @Test func portableRTFMathRemainsVisibleWhenTheAppIsDark() async throws {
        let preferences = MobilePreferences()
        let appearance = MobileRenderedExport.appearance(format: .rtf, preferences: preferences, dark: true)
        #expect(!appearance.dark)
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        let rendered = try await renderer.render(source: "Dark app math $a+b$", attachments: [:], keepTags: true, wikiLinks: [:], foreground: appearance.foreground)
        let html = MobileRenderedExport.document(body: rendered.html, title: "Portable RTF", preferences: preferences, dark: appearance.dark)
        let rtf = try await MobileRenderedExport.rtf(html)
        let raw = try #require(String(data: rtf, encoding: .isoLatin1))
        let expression = try NSRegularExpression(pattern: #"\{\\pict\\pngblip\\picw\d+\\pich\d+\\picwgoal\d+\\pichgoal\d+\s+([0-9a-f\s]+)\}"#)
        let match = try #require(expression.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)))
        let range = try #require(Range(match.range(at: 1), in: raw))
        let hex = raw[range].filter { !$0.isWhitespace }
        var png = Data(); var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            png.append(try #require(UInt8(hex[cursor..<end], radix: 16))); cursor = end
        }
        let image = try #require(UIImage(data: png)?.cgImage)
        let count = image.width * image.height * 4
        var bytes = [UInt8](repeating: 0, count: count)
        let visibleOnWhite = bytes.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(data: pixels.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: count, by: 4).contains { pixels[$0] < 200 && pixels[$0 + 1] < 200 && pixels[$0 + 2] < 200 }
        }
        #expect(visibleOnWhite)
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let color = try #require(restored.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
        var red: CGFloat = 0; var green: CGFloat = 0; var blue: CGFloat = 0; var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) && max(red, green, blue) < 0.8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-dark-app-portable.rtf")
        try rtf.write(to: url); print("DARK_APP_PORTABLE_RTF", url.path)
    }

    @Test func rtfRefusesRemoteImagesAndHonorsCancellation() async throws {
        await #expect(throws: Error.self) {
            try await MobileRenderedExport.rtf("<p>Fixture</p><img src=\"https://invalid.example/image.png\">")
        }
        let task = Task { try await MobileRenderedExport.rtf("<p>Private fixture</p>") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func rtfEmbedsMathDiagramAndLocalImageAndPDFKeepsRichContent() async throws {
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.pngData())
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        let rendered = try await renderer.render(source: "# Rich export\n\n$a+b$\n\n```mermaid\nflowchart TD\nA-->B\n```\n\n![Local](photo.png)\n\nFinal café 日本語",
            attachments: ["photo.png": "data:image/png;base64," + png.base64EncodedString()], keepTags: true, wikiLinks: [:])
        let html = MobileRenderedExport.document(body: rendered.html, title: "Rich export", preferences: MobilePreferences(), dark: false)
        let rtf = try await MobileRenderedExport.rtf(html)
        let raw = try #require(String(data: rtf, encoding: .isoLatin1))
        let pattern = try NSRegularExpression(pattern: #"\{\\pict\\pngblip\\picw\d+\\pich\d+\\picwgoal\d+\\pichgoal\d+\s+([0-9a-f\s]+)\}"#)
        let blocks = pattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        #expect(blocks.count == 3)
        var embedded: [Data] = []
        for block in blocks {
            let range = try #require(Range(block.range(at: 1), in: raw))
            let hex = raw[range].filter { !$0.isWhitespace }
            var bytes = Data(); var cursor = hex.startIndex
            while cursor < hex.endIndex {
                let end = hex.index(cursor, offsetBy: 2)
                bytes.append(try #require(UInt8(hex[cursor..<end], radix: 16))); cursor = end
            }
            let image = try #require(UIImage(data: bytes))
            #expect(image.size.width > 0 && image.size.height > 0)
            #expect(bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            embedded.append(bytes)
        }
        #expect(embedded.contains(png))
        let rtfURL = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-rich-export.rtf")
        try rtf.write(to: rtfURL)
        print("RICH_EXPORT_RTF", rtfURL.path)
        // Cocoa does not import standard pict groups. Verify text here and test the embedded
        // PNG bytes above; an independent RTF reader validates pictures outside Cocoa.
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(restored.string.contains("Final café 日本語"))
        let preview = MobileRenderedExport()
        try await preview.load(html)
        let document = try #require(PDFDocument(data: preview.pdf(title: "Rich export")))
        #expect(document.string?.contains("Final") == true)
        let page = try #require(document.page(at: 0))
        let thumbnail = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        #expect(thumbnail.size.width > 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-rich-export-pdf.png")
        try thumbnail.pngData()?.write(to: url)
        print("RICH_EXPORT_PDF_SCREENSHOT", url.path)
    }
}
