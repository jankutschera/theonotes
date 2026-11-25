// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Turns an attachment file into searchable text.
public protocol TextExtracting: Sendable {
    func extract(from url: URL) async -> OCRResult
    /// `extract(from:)` for a caller that already hashed the file (`knownSHA256`), so the extractor
    /// need not read it again. The default ignores the hash.
    func extract(from url: URL, knownSHA256: String?) async -> OCRResult
}

extension TextExtracting {
    public func extract(from url: URL, knownSHA256: String?) async -> OCRResult {
        await extract(from: url)
    }
}

/// Vision text recognition for images and PDF pages without a text layer, PDFKit's text layer
/// for the rest of a PDF. Pure file → text: it touches no database, never logs and never throws
/// (a problem is a result: `.failed`, `.skipped`, `.missing`).
///
/// - Images (the type conforms to `public.image`, SVG excluded): `RecognizeTextRequest`,
///   `.accurate`, automatic language detection, language correction on. Larger than
///   `maxImagePixels` → `.skipped`. Decoded down to at most `maxDecodedEdge` pixels on the long
///   edge, with the EXIF orientation applied.
/// - PDFs: `PDFPage.string` per page; a page with fewer than `minimumPageCharacters` non-space
///   characters is rendered at 2x (long edge at most `maxRenderEdge` pixels) and recognized with
///   Vision. At most `maxPages` pages. An encrypted PDF that is locked or forbids copying → `.none`.
/// - Everything else → `.none`; files over `maxFileBytes` → `.skipped`.
/// - The text is cut to `maxCharacters` at a word boundary.
public struct AttachmentTextExtractor: TextExtracting {
    public static let defaultMaxFileBytes = 200 * 1024 * 1024

    public var maxImagePixels = 50_000_000
    public var maxFileBytes = defaultMaxFileBytes
    public var maxPages = 50
    public var maxCharacters = 100_000
    public var minimumPageCharacters = 16
    public var maxDecodedEdge = 5_000
    public var maxRenderEdge: CGFloat = 2_500
    /// Test seam: called with the index of every PDF page rendered for Vision.
    var pageRendered: (@Sendable (Int) -> Void)?

    public init(
        maxImagePixels: Int = 50_000_000, maxFileBytes: Int = defaultMaxFileBytes, maxPages: Int = 50,
        maxCharacters: Int = 100_000, minimumPageCharacters: Int = 16
    ) {
        self.maxImagePixels = maxImagePixels
        self.maxFileBytes = maxFileBytes
        self.maxPages = maxPages
        self.maxCharacters = maxCharacters
        self.minimumPageCharacters = minimumPageCharacters
    }

    /// Whether the extractor reads files like `url` at all (images and PDFs); anything else is
    /// `.none`, so hashing it would be wasted.
    public static func canExtract(_ url: URL) -> Bool {
        kind(of: url) != nil
    }

    public func extract(from url: URL) async -> OCRResult {
        await extract(from: url, knownSHA256: nil)
    }

    public func extract(from url: URL, knownSHA256: String?) async -> OCRResult {
        guard let kind = Self.kind(of: url) else { return .none(sha256: nil) }
        // `attributesOfItem`, not `resourceValues`: the latter caches per URL object and would
        // report the facts from before a replacement.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date
        else { return FileManager.default.fileExists(atPath: url.path) ? .failed : .missing }
        guard size <= maxFileBytes else { return .skipped }

        let recognized: Recognized
        switch kind {
        case .image: recognized = await recognizeImage(at: url)
        case .pdf: recognized = await recognizePDF(at: url)
        }
        func hash() -> String? { knownSHA256 ?? Self.sha256(of: url) }
        switch recognized {
        case .skipped: return .skipped
        case .failed: return .failed
        case let .text(text):
            guard let sha256 = hash() else { return .failed }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .none(sha256: sha256) }
            return .text(OCRText.capped(trimmed, to: maxCharacters), sha256: sha256, byteSize: size, modifiedAt: modified)
        case .nothing:
            return .none(sha256: hash())
        }
    }

    // MARK: Types

    private enum Kind { case image, pdf }

    private enum Recognized {
        case text(String)
        /// Nothing to recognize on purpose (encrypted PDF).
        case nothing
        case skipped
        case failed
    }

    private static func kind(of url: URL) -> Kind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        // ImageIO cannot decode vector images.
        if type.conforms(to: .image), !type.conforms(to: .svg) { return .image }
        return nil
    }

    // MARK: Images

    private func recognizeImage(at url: URL) async -> Recognized {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return .failed }
        guard width * height <= maxImagePixels else { return .skipped }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxDecodedEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failed }
        guard let text = await Self.recognize(image) else { return .failed }
        return .text(text)
    }

    /// The text Vision reads in `image`, line by line; nil when the request fails.
    private static func recognize(_ image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: image, orientation: nil)
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    // MARK: PDFs

    private func recognizePDF(at url: URL) async -> Recognized {
        guard let document = PDFDocument(url: url) else { return .failed }
        if document.isLocked || (document.isEncrypted && !document.allowsCopying) { return .nothing }
        var parts: [String] = []
        var characters = 0
        for index in 0..<min(document.pageCount, maxPages) {
            guard characters < maxCharacters else { break }
            guard let page = document.page(at: index) else { continue }
            var text = page.string ?? ""
            if Self.nonSpaceCount(text) < minimumPageCharacters, let image = renderedImage(of: page, index: index),
               let scanned = await Self.recognize(image), Self.nonSpaceCount(scanned) > Self.nonSpaceCount(text) {
                text = scanned
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append(trimmed)
            characters += trimmed.count + 1
        }
        return .text(parts.joined(separator: "\n"))
    }

    private static func nonSpaceCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + ($1.properties.isWhitespace ? 0 : 1) }
    }

    /// The page at 2x on opaque white, drawn into a bitmap of exactly that size (the long edge at
    /// most `maxRenderEdge` pixels, whatever the screen's backing scale), the page's own rotation
    /// applied.
    func renderedImage(of page: PDFPage, index: Int = 0) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        return autoreleasepool {
            let box = pageRef.getBoxRect(.mediaBox)
            let turned = pageRef.rotationAngle % 180 != 0
            let points = turned ? CGSize(width: box.height, height: box.width) : box.size
            let longest = max(points.width, points.height)
            guard longest > 0 else { return nil }
            let scale = min(2, maxRenderEdge / longest)
            let width = max(1, Int((points.width * scale).rounded()))
            let height = max(1, Int((points.height * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            let target = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(target)
            context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(pageRef)
            pageRendered?(index)
            return context.makeImage()
        }
    }

    // MARK: Hash

    /// Hex SHA-256 of the file, read in 1 MB chunks.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
