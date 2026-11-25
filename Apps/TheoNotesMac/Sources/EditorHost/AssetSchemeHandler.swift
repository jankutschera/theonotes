// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TheoNotesCore
import Foundation
import UniformTypeIdentifiers
import WebKit

/// The attachments of locked notes, held in memory (Mac, M9): the handler asks it for the bytes
/// and previews of a locked note's files instead of reading `Attachments/<noteId>/`. It answers
/// nil while the vault is locked.
@MainActor
protocol LockedAttachmentProviding: AnyObject {
    func isLockedNote(_ noteId: String) -> Bool
    /// Decrypted off the main actor, within the provider's memory limits; nil when refused.
    func data(noteId: String, filename: String) async -> Data?
    func thumbnailPNG(noteId: String, filename: String, icon: Bool) async -> Data?
}

/// Serves the bundled editor (`baerchen-asset://editor/<path>`) from `Resources/Editor/`, note
/// attachments (`baerchen-asset://attachment/<noteId>/<percent-encoded filename>`) from
/// `Attachments/<noteId>/`, and their previews (`baerchen-asset://thumbnail/<noteId>/<name>`, with
/// `?icon` the file icon). Anything else, including traversal (`..`, `%2E%2E`, `%2F`, absolute
/// paths, symlinks out of the note's directory) and missing files, is a 404. TagCons
/// (`baerchen-asset://tagcon/v2/<symbol>.png`; only `v2` paths are answered): a WebView cannot draw SF Symbols, so each is rendered
/// here once as a black-on-transparent PNG, which the editor uses as a CSS mask and tints with the
/// tag color.
@MainActor
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "baerchen-asset"
    static let host = "editor"
    static let attachmentHost = "attachment"
    static let thumbnailHost = "thumbnail"
    static let tagconHost = "tagcon"
    /// Width and height of a TagCon image: shown at about 13 pt, so sharp at 2x screens up to
    /// editor zoom 2.0 (`EditorZoom`). The path carries a version (`v2`), so a cached image of an
    /// older size is never reused (M3 triage #45).
    static let tagconPixels = 96
    static let tagconVersion = "v2"
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!
    static let contentSecurityPolicy =
        "default-src 'self' baerchen-asset:; style-src 'self' 'unsafe-inline' baerchen-asset:; img-src 'self' baerchen-asset: data: blob:"
    /// Attachment bytes are data, never a document that runs: should one be loaded as a page or
    /// frame, it is sandboxed without scripts.
    static let attachmentSecurityPolicy = "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox"

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "txt": "text/plain; charset=utf-8",
    ]

    private let root: URL
    private let attachments: AttachmentStore?
    private let thumbnails: Thumbnails?
    private let privateAttachment: ((String, String) -> URL?)?
    private let lockedAttachments: (any LockedAttachmentProviding)?
    /// Thumbnail tasks still running (generation is asynchronous; WebKit may stop them first).
    private var running: Set<ObjectIdentifier> = []
    /// Rendered TagCons by symbol name.
    private static let tagcons = NSCache<NSString, NSData>()

    init(
        root: URL = Bundle.main.resourceURL!.appendingPathComponent("Editor", isDirectory: true),
        attachments: AttachmentStore? = nil, thumbnails: Thumbnails? = nil,
        privateAttachment: ((String, String) -> URL?)? = nil,
        lockedAttachments: (any LockedAttachmentProviding)? = nil
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.attachments = attachments
        self.thumbnails = thumbnails
        self.privateAttachment = privateAttachment
        self.lockedAttachments = lockedAttachments
    }

    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    /// The file under `root` for `url`, or nil for other hosts/schemes, missing files and traversal.
    func fileURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return nil }
        let path = url.path(percentEncoded: false)
        let relative = path.isEmpty || path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    /// The note id and filename of an attachment or thumbnail URL: the path must be exactly
    /// `/<noteId>/<filename>` (each one percent-decoded component), and the file a regular file
    /// inside `Attachments/<noteId>/` (`AttachmentStore.url`).
    func attachment(for url: URL) -> (noteId: String, file: URL)? {
        guard let attachments, let (host, noteId, name) = Self.attachmentParts(of: url),
              let file = attachments.url(for: name, noteId: noteId)
                ?? (host == Self.attachmentHost ? privateAttachment?(noteId, name) : nil) else { return nil }
        return (noteId, file)
    }

    /// The host, note id and filename of an attachment or thumbnail URL (exactly `/<noteId>/<filename>`).
    private static func attachmentParts(of url: URL) -> (host: String, noteId: String, name: String)? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(),
              host == attachmentHost || host == thumbnailHost else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty,
              let noteId = parts[1].removingPercentEncoding, let name = parts[2].removingPercentEncoding else { return nil }
        return (host, noteId, name)
    }

    /// An attachment of a locked note, from memory: never cacheable, 404 while the vault is locked.
    /// nil for any other note.
    private func lockedResponse(for url: URL, method: String) async -> Response? {
        guard let lockedAttachments, let (_, noteId, name) = Self.attachmentParts(of: url),
              lockedAttachments.isLockedNote(noteId) else { return nil }
        var headers = Self.attachmentHeaders()
        headers["Cache-Control"] = "no-store"
        guard let data = await lockedAttachments.data(noteId: noteId, filename: name) else { return Self.notFound(headers) }
        return Self.lockedFile(data, name: name, headers: &headers, method: method)
    }

    private static func lockedFile(_ data: Data, name: String, headers: inout [String: String], method: String) -> Response {
        headers["Content-Type"] = mimeType(for: URL(fileURLWithPath: "/" + name))
        headers["Content-Length"] = String(data.count)
        return Response(statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : data)
    }

    /// `response(for:)` with the attachments of locked notes (decrypted off the main actor).
    func fullResponse(for url: URL, method: String = "GET") async -> Response {
        if url.host?.lowercased() == Self.attachmentHost, let locked = await lockedResponse(for: url, method: method) {
            return locked
        }
        return response(for: url, method: method)
    }

    private func isLockedAttachmentURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == Self.attachmentHost, let lockedAttachments,
              let (_, noteId, _) = Self.attachmentParts(of: url) else { return false }
        return lockedAttachments.isLockedNote(noteId)
    }

    func response(for url: URL, method: String = "GET") -> Response {
        if url.host?.lowercased() == Self.attachmentHost { return attachmentResponse(for: url, method: method) }
        var headers = [
            "Content-Security-Policy": Self.contentSecurityPolicy,
            // Vite emits `<script type="module" crossorigin>`, which loads in CORS mode.
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        if url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.tagconHost {
            guard let png = tagcon(for: url) else { return Self.notFound(headers) }
            headers["Content-Type"] = "image/png"
            // A symbol name always renders the same image (per OS version).
            headers["Cache-Control"] = "max-age=31536000, immutable"
            headers["Content-Length"] = String(png.count)
            return Response(statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : png)
        }
        guard let file = fileURL(for: url), let data = try? Data(contentsOf: file) else { return Self.notFound(headers) }
        headers["Content-Type"] = Self.mimeTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        headers["Content-Length"] = String(data.count)
        return Response(statusCode: 200, headers: headers, body: method == "HEAD" ? Data() : data)
    }

    private static func notFound(_ base: [String: String]) -> Response {
        var headers = base
        headers["Content-Type"] = "text/plain; charset=utf-8"
        headers["Content-Length"] = "0"
        return Response(statusCode: 404, headers: headers, body: Data())
    }

    private static func attachmentHeaders() -> [String: String] {
        [
            "Content-Security-Policy": attachmentSecurityPolicy,
            "X-Content-Type-Options": "nosniff",
            // The editor page (baerchen-asset://editor) reads size and date with a HEAD fetch.
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
    }

    /// The attachment's bytes (none for HEAD) with its MIME type, size and modification date.
    private func attachmentResponse(for url: URL, method: String) -> Response {
        var headers = Self.attachmentHeaders()
        // A locked note's file is never read from disk here; `fullResponse` serves it from memory.
        if isLockedAttachmentURL(url) {
            headers["Cache-Control"] = "no-store"
            return Self.notFound(headers)
        }
        guard let (_, file) = attachment(for: url),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return Self.notFound(headers)
        }
        let body: Data
        if method == "HEAD" {
            body = Data()
        } else {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return Self.notFound(headers) }
            body = data
        }
        headers["Content-Type"] = Self.mimeType(for: file)
        headers["Content-Length"] = String(method == "HEAD" ? values.fileSize ?? 0 : body.count)
        if let modified = values.contentModificationDate { headers["Last-Modified"] = Self.httpDate(modified) }
        return Response(statusCode: 200, headers: headers, body: body)
    }

    /// A thumbnail (asynchronous: PDF pages and video frames take a moment).
    func thumbnailResponse(for url: URL) async -> Response {
        var headers = Self.attachmentHeaders()
        if let lockedAttachments, let (host, noteId, name) = Self.attachmentParts(of: url),
           host == Self.thumbnailHost, lockedAttachments.isLockedNote(noteId) {
            headers["Cache-Control"] = "no-store"
            guard let png = await lockedAttachments.thumbnailPNG(noteId: noteId, filename: name, icon: url.query() == "icon") else {
                return Self.notFound(headers)
            }
            headers["Content-Type"] = "image/png"
            headers["Content-Length"] = String(png.count)
            return Response(statusCode: 200, headers: headers, body: png)
        }
        guard let thumbnails, let (noteId, file) = attachment(for: url) else { return Self.notFound(headers) }
        let variant: Thumbnails.Variant = url.query() == "icon" ? .icon : .preview
        guard let png = await thumbnails.png(for: file, noteId: noteId, variant: variant) else { return Self.notFound(headers) }
        headers["Content-Type"] = "image/png"
        headers["Content-Length"] = String(png.count)
        return Response(statusCode: 200, headers: headers, body: png)
    }

    /// Types a browser engine would run (markup and script): served as plain text, never as a
    /// document or image that executes. `.svg` is the one image type left out: the editor shows it
    /// only through `<img>`, where no script runs, and it is served as `image/svg+xml` under
    /// `attachmentSecurityPolicy` and `nosniff` (a page that loaded it directly would be sandboxed).
    private static let inertTypes: Set<String> = ["html", "htm", "xhtml", "xht", "shtml", "js", "mjs", "svgz", "xml", "xsl"]

    /// The MIME type for an attachment's extension; `application/octet-stream` when unknown,
    /// `text/plain` for markup and script, `image/svg+xml` for `.svg`.
    static func mimeType(for file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        if inertTypes.contains(ext) { return "text/plain; charset=utf-8" }
        if let known = mimeTypes[ext] { return known }
        guard let type = UTType(filenameExtension: ext) else { return "application/octet-stream" }
        if type.conforms(to: .html) || type.conforms(to: .svg) || type.conforms(to: .sourceCode) { return "text/plain; charset=utf-8" }
        return type.preferredMIMEType ?? "application/octet-stream"
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// `/v2/<symbol>.png` with a plain SF Symbol name (`folder.fill`); nil for anything else,
    /// unversioned paths included.
    private func tagcon(for url: URL) -> Data? {
        let path = url.path(percentEncoded: true)
        let prefix = "/\(Self.tagconVersion)/"
        guard path.hasPrefix(prefix), path.hasSuffix(".png") else { return nil }
        let symbol = String(path.dropFirst(prefix.count).dropLast(4))
        guard symbol.wholeMatch(of: /[a-z0-9]+(\.[a-z0-9]+)*/) != nil else { return nil }
        if let cached = Self.tagcons.object(forKey: symbol as NSString) { return cached as Data }
        guard let png = Self.renderTagcon(symbol) else { return nil }
        Self.tagcons.setObject(png as NSData, forKey: symbol as NSString)
        return png
    }

    /// The symbol in black, aspect-fit into a transparent `tagconPixels` square.
    static func renderTagcon(_ symbol: String) -> Data? {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(tagconPixels), weight: .regular)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: tagconPixels, pixelsHigh: tagconPixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let side = CGFloat(tagconPixels)
        bitmap.size = NSSize(width: side, height: side)
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: rect)
        // Template images keep their own colors on some systems: force solid black where drawn.
        NSColor.black.set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: CGFloat(tagconPixels), weight: .regular)
        guard let image = UIImage(systemName: symbol, withConfiguration: configuration) else { return nil }
        let side = CGFloat(tagconPixels)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in
            let scale = min(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in:
                CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }.pngData()
        #endif
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let method = urlSchemeTask.request.httpMethod ?? "GET"
        guard url.host?.lowercased() == Self.thumbnailHost || isLockedAttachmentURL(url) else {
            finish(urlSchemeTask, url: url, with: response(for: url, method: method))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        running.insert(id)
        Task { @MainActor in
            let result = url.host?.lowercased() == Self.thumbnailHost
                ? await thumbnailResponse(for: url) : await fullResponse(for: url, method: method)
            guard running.remove(id) != nil else { return } // stopped meanwhile
            finish(urlSchemeTask, url: url, with: result)
        }
    }

    private func finish(_ task: any WKURLSchemeTask, url: URL, with result: Response) {
        guard let http = HTTPURLResponse(
            url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1", headerFields: result.headers
        ) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(http)
        if !result.body.isEmpty { task.didReceive(result.body) }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Editor and attachment tasks complete synchronously in start; a stopped thumbnail task
        // must not be answered.
        running.remove(ObjectIdentifier(urlSchemeTask))
    }
}
