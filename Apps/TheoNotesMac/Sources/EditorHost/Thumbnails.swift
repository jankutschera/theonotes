// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import AVFoundation
import TheoNotesCore
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Previews for attachment cards (`baerchen-asset://thumbnail/<noteId>/<name>`): a PDF's first
/// page, a video's poster frame, otherwise (and for `?icon`) the file's Finder icon. PNGs are
/// cached in `Thumbnails/<noteId>/` and made again when the attachment is newer.
struct Thumbnails: Sendable {
    enum Variant: String, Sendable {
        case preview, icon
    }

    /// Longest edge of a preview, in pixels (2× a 420 pt card).
    static let previewSize: CGFloat = 840
    static let iconSize: CGFloat = 64

    let root: URL

    init(paths: AppPaths) {
        root = paths.thumbnails
    }

    /// The cached or newly made PNG for `file` (an attachment of `noteId`), nil if none can be made.
    func png(for file: URL, noteId: String, variant: Variant) async -> Data? {
        let cache = cacheURL(noteId: noteId, name: file.lastPathComponent, variant: variant)
        if let cached = fresh(cache, for: file) { return cached }
        let data: Data?
        switch (variant, Self.kind(of: file)) {
        case (.preview, .pdf): data = Self.pdfPage(file)
        case (.preview, .video): data = await Self.videoPoster(file)
        default: data = await MainActor.run { Self.icon(file) }
        }
        if let data {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        return data
    }

    private func cacheURL(noteId: String, name: String, variant: Variant) -> URL {
        let key = SHA256.hash(data: Data("\(variant.rawValue)|\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(noteId, isDirectory: true).appendingPathComponent(key + ".png")
    }

    private func fresh(_ cache: URL, for file: URL) -> Data? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let cached = try? cache.resourceValues(forKeys: keys).contentModificationDate,
              let source = try? file.resourceValues(forKeys: keys).contentModificationDate,
              cached >= source else { return nil }
        return try? Data(contentsOf: cache)
    }

    enum Kind { case pdf, video, other }

    static func kind(of file: URL) -> Kind {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .other
    }

    static func pdfPage(_ file: URL) -> Data? {
        pdfPage(PDFDocument(url: file))
    }

    static func pdfPage(_ document: PDFDocument?) -> Data? {
        guard let page = document?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = previewSize / max(bounds.width, bounds.height)
        return png(page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox))
    }

    static func videoPoster(_ file: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewSize, height: previewSize)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @MainActor
    static func icon(_ file: URL) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: file.path)
        image.size = NSSize(width: iconSize, height: iconSize)
        return png(image)
    }

    /// A preview made from bytes held in memory (an attachment of a locked note): a PDF's first
    /// page, otherwise the icon of the file type. Nothing is cached or written; a video has no
    /// poster frame here, because AVFoundation reads from a URL.
    static func memoryPNG(data: Data, filename: String, variant: Variant) async -> Data? {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        if variant == .preview, let type, type.conforms(to: .pdf) { return pdfPage(PDFDocument(data: data)) }
        return await MainActor.run {
            let image = NSWorkspace.shared.icon(for: type ?? .data)
            image.size = NSSize(width: iconSize, height: iconSize)
            return png(image)
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
