// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct MobileRenderedNote: Sendable {
    let html: String
    let text: String
}

/// The case order is the order of every export menu (design r3).
enum MobileExportFormat: String, CaseIterable {
    case markdown, textBundle, html, pdf, rtf, plainText
    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .textBundle: "TextBundle"
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .pdf: "PDF"
        case .rtf: "Rich Text (RTF)"
        }
    }
    var fileExtension: String {
        switch self { case .markdown: "md"; case .textBundle: "textbundle"; case .plainText: "txt"; case .html: "html"; case .pdf: "pdf"; case .rtf: "rtf" }
    }
    var contentType: UTType {
        switch self { case .markdown, .plainText: .plainText; case .textBundle: .textBundle; case .html: .html; case .pdf: .pdf; case .rtf: .rtf }
    }
}

@MainActor
final class MobileRenderedExport: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 523, height: 770), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ html: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.loadHTMLString(html, baseURL: nil)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The export preview took too long to load. Try again."]))
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { @MainActor [weak self] in self?.finish(CancellationError()) } }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(CocoaError(.fileReadUnknown)) }
    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        if let error { webView.stopLoading(); continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func pdf(title: String) throws -> Data {
        let renderer = ExportPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        guard renderer.numberOfPages > 0 else { throw CocoaError(.fileWriteUnknown) }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Theo Notes"]
        return UIGraphicsPDFRenderer(bounds: renderer.paperRect, format: format).pdfData { context in
            for page in 0..<renderer.numberOfPages {
                context.beginPage(); renderer.drawPage(at: page, in: renderer.paperRect)
            }
        }
    }

    func printNote(title: String, from anchor: UIView, completion: @escaping (Error?) -> Void) throws {
        // Give the system a complete PDF, as the export flow does. Sharing the print
        // preview must not depend on a second asynchronous WebKit formatter render.
        let document = try pdf(title: title)
        try Self.printPDF(document, title: title, from: anchor, completion: completion)
    }

    static func printPDF(_ document: Data, title: String, from anchor: UIView, completion: @escaping (Error?) -> Void) throws {
        guard UIPrintInteractionController.canPrint(document) else { throw CocoaError(.fileWriteUnknown) }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil); info.jobName = title; info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = nil
        controller.printPageRenderer = nil
        controller.printingItems = nil
        controller.printingItem = document
        let callback: UIPrintInteractionController.CompletionHandler = { controller, _, error in
            controller.printingItem = nil
            completion(error)
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            controller.present(from: CGRect(x: anchor.bounds.midX, y: 0, width: 1, height: 1), in: anchor, animated: true, completionHandler: callback)
        } else { controller.present(animated: true, completionHandler: callback) }
    }

    /// Cocoa's plain-RTF writer discards image attachments. Keep its text/formatting writer,
    /// replacing image placeholders with standard self-contained PNG pict groups afterwards.
    /// Cocoa's own RTF reader also ignores pict; RTFD is its separate attachment format.
    static func rtf(_ html: String) async throws -> Data {
        try Task.checkCancellation()
        let imageTags = try NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
        let sourceAttribute = try NSRegularExpression(pattern: #"\bsrc\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive])
        let source = html as NSString
        let matches = imageTags.matches(in: html, range: NSRange(location: 0, length: source.length))
        let prepared = NSMutableString(string: html)
        var pictures: [(token: String, source: String)] = []
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        for (index, match) in matches.enumerated() {
            let tag = source.substring(with: match.range) as NSString
            guard let attribute = sourceAttribute.firstMatch(in: tag as String, range: NSRange(location: 0, length: tag.length)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let url = tag.substring(with: attribute.range(at: 1))
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard url.hasPrefix("data:image/") else { throw CocoaError(.fileReadUnsupportedScheme) }
            pictures.append(("BCIMAGE" + nonce + String(index) + "END", url))
        }
        for (index, match) in matches.enumerated().reversed() {
            prepared.replaceCharacters(in: match.range, with: pictures[index].token)
        }
        let attributed = try NSAttributedString(data: Data((prepared as String).utf8), options: [.documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        let original = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        guard var output = String(data: original, encoding: .isoLatin1) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        var rasterizer: MobileRenderedExport?
        for picture in pictures {
            try Task.checkCancellation()
            let raster: RTFPicture
            if let comma = picture.source.firstIndex(of: ","), picture.source[..<comma].contains(";base64"),
               let data = Data(base64Encoded: String(picture.source[picture.source.index(after: comma)...])),
               let image = UIImage(data: data), let png = image.pngData() {
                // Keep PNG bytes exactly, rather than discarding color profiles and metadata.
                let bytes = picture.source.hasPrefix("data:image/png;") ? data : png
                raster = RTFPicture(png: bytes, pixelWidth: image.cgImage?.width ?? Int(image.size.width),
                    pixelHeight: image.cgImage?.height ?? Int(image.size.height), size: image.size)
            } else {
                if rasterizer == nil {
                    let page = MobileRenderedExport()
                    try await page.load("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:\"><body></body>")
                    rasterizer = page
                }
                guard let page = rasterizer else { throw CocoaError(.fileReadUnknown) }
                // An SVG remains an inert image. Canvas rasterizes its decoded pixels; no note
                // controlled SVG, script, URL or foreignObject enters a live document.
                let result = try await page.webView.callAsyncJavaScript("""
                    const image = new Image(); image.src = source; await image.decode();
                    const width = Math.max(1, image.naturalWidth), height = Math.max(1, image.naturalHeight);
                    const scale = Math.min(3, 4096 / width, 4096 / height);
                    const canvas = document.createElement('canvas');
                    canvas.width = Math.max(1, Math.ceil(width * scale)); canvas.height = Math.max(1, Math.ceil(height * scale));
                    const context = canvas.getContext('2d'); if (!context) throw new Error('Image rasterization unavailable');
                    context.drawImage(image, 0, 0, canvas.width, canvas.height);
                    return { png: canvas.toDataURL('image/png'), width, height, pixelWidth: canvas.width, pixelHeight: canvas.height };
                    """, arguments: ["source": picture.source], in: nil, contentWorld: .page)
                guard let value = result as? [String: Any], let encoded = value["png"] as? String,
                      let comma = encoded.firstIndex(of: ","), let png = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                      let width = value["width"] as? Double, let height = value["height"] as? Double,
                      let pixelWidth = value["pixelWidth"] as? Int, let pixelHeight = value["pixelHeight"] as? Int,
                      UIImage(data: png) != nil else { throw CocoaError(.fileReadCorruptFile) }
                raster = RTFPicture(png: png, pixelWidth: pixelWidth, pixelHeight: pixelHeight, size: CGSize(width: width, height: height))
            }
            guard output.contains(picture.token) else { throw CocoaError(.fileWriteUnknown) }
            output = output.replacingOccurrences(of: picture.token, with: raster.group)
        }
        guard let data = output.data(using: .isoLatin1) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return data
    }

    private struct RTFPicture {
        let png: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let size: CGSize
        var group: String {
            let scale = min(1, 500 / max(1, size.width))
            let width = max(1, Int((size.width * scale * 20).rounded()))
            let height = max(1, Int((size.height * scale * 20).rounded()))
            let digits = Array("0123456789abcdef".utf8)
            var hex: [UInt8] = []; hex.reserveCapacity(png.count * 2 + png.count / 64)
            for (index, byte) in png.enumerated() {
                hex.append(digits[Int(byte >> 4)]); hex.append(digits[Int(byte & 15)])
                if index % 64 == 63 { hex.append(10) }
            }
            return "{\\pict\\pngblip\\picw\(pixelWidth)\\pich\(pixelHeight)\\picwgoal\(width)\\pichgoal\(height)\n" + String(decoding: hex, as: UTF8.self) + "}"
        }
    }

    /// Portable RTF has no dependable page background across readers, so export it with
    /// the light palette even when the app is dark. PDF and HTML keep the requested palette.
    static func appearance(format: MobileExportFormat, preferences: MobilePreferences, dark: Bool) -> (dark: Bool, foreground: String) {
        let exportDark = format != .rtf && dark
        return (exportDark, preferences.theme(dark: exportDark).editor["color-text"] ?? "#000000")
    }

    static func document(body: String, title: String, preferences: MobilePreferences, dark: Bool) -> String {
        let theme = preferences.theme(dark: dark)
        func css(_ token: ShellToken) -> String {
            let color = theme.color(token)
            return "rgb(\(Int(color.red * 255)),\(Int(color.green * 255)),\(Int(color.blue * 255)))"
        }
        func font(_ value: String?, fallback: String) -> String {
            guard let value else { return fallback }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "<", with: "\\3c ") + "\", " + fallback
        }
        let fallbackBackground = css(.background)
        let calloutCSS: String = ["note", "tip", "important", "warning", "caution"].map { kind -> String in
            func value(_ suffix: String) -> String {
                let candidate = theme.editor["color-callout-" + kind + "-" + suffix] ?? ""
                return ThemeColor(hex: candidate) == nil ? fallbackBackground : candidate
            }
            return ".callout-\(kind){background:\(value("bg"));border-color:\(value("border"))}.callout-\(kind)>strong{color:\(value("title"))}"
        }.joined()
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(safeTitle)</title><style>
        :root{color-scheme:\(dark ? "dark" : "light")}*{box-sizing:border-box}body{margin:0;padding:24px;background:\(css(.background));color:\(css(.text));font-family:\(font(preferences.textFontFamily, fallback: "-apple-system,system-ui,sans-serif"));font-size:\(preferences.fontSize)px;line-height:\(preferences.lineHeight);overflow-wrap:anywhere}
        main{max-width:\(preferences.lineWidth)px;margin:auto}p{margin:0 0 \(preferences.paragraphSpacing + 0.5)em;text-indent:\(preferences.paragraphIndent)em}h1,h2,h3,h4,h5,h6{font-family:\(font(preferences.headingFontFamily, fallback: "-apple-system,system-ui,sans-serif"));line-height:1.25;break-after:avoid}a{color:\(css(.accent))}pre,code{font-family:\(font(preferences.codeFontFamily, fallback: "ui-monospace,Menlo,monospace"))}pre{white-space:pre-wrap;padding:12px;border:1px solid \(css(.separator));border-radius:6px}blockquote{border-left:3px solid \(css(.accent));margin:1em 0;padding-left:1em}table{width:100%;border-collapse:collapse;margin:1em 0}td,th{border:1px solid \(css(.separator));padding:6px;text-align:left}tr,img{break-inside:avoid}img{max-width:100%;height:auto}mark{color:#111;background:#ffe98a}.highlight-green{background:#a7e5b8}.highlight-red{background:#ffb7b7}.highlight-blue{background:#b7d7ff}.highlight-purple{background:#dfc3ff}.tag{color:\(css(.accent))}.missing-image{font-style:italic}.inline-math{height:1.3em;vertical-align:middle;max-width:100%}.formula{text-align:center;margin:1em 0}.display-math{max-width:100%;max-height:30em}.diagram{margin:1em 0;text-align:center}.callout{border-radius:5px;padding:8px 12px}\(calloutCSS).task{margin:.3em 0}@media print{body{padding:0;-webkit-print-color-adjust:exact}main{max-width:none}a{text-decoration:none}}
        </style></head><body><main>\(body)</main></body></html>
        """
    }
}

@MainActor private final class ExportPageRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.28, height: 841.89) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 36, dy: 36) }
}
