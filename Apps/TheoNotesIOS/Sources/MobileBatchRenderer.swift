// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import WebKit

/// A batch renderer has no editor session, attachment database, clipboard or bridge handler.
@MainActor final class MobileBatchRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var failure: (any Error)?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: AssetSchemeHandler.indexURL))
    }
    func cancel() { webView.stopLoading(); webView.loadHTMLString("", baseURL: nil) }
    func render(source: String, attachments: [String: String], keepTags: Bool, wikiLinks: [String: String], foreground: String = "#000000") async throws -> MobileRenderedNote {
        return try await withTaskCancellationHandler {
            try await renderPrepared(source: source, attachments: attachments, keepTags: keepTags, wikiLinks: wikiLinks, foreground: foreground)
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    private func renderPrepared(source: String, attachments: [String: String], keepTags: Bool, wikiLinks: [String: String], foreground: String) async throws -> MobileRenderedNote {
        for _ in 0..<200 {
            try Task.checkCancellation()
            if let failure { throw failure }
            let ready = try? await webView.evaluateJavaScript("typeof window.__baerchen?.renderNote === 'function'") as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        let result = try await webView.callAsyncJavaScript("return window.__baerchen.renderNote(source, {attachments, keepTags, wikiLinks, foreground})",
            arguments: ["source": source, "attachments": attachments, "keepTags": keepTags, "wikiLinks": wikiLinks, "foreground": foreground], in: nil, contentWorld: .page)
        guard let value = result as? [String: String], let html = value["html"], let text = value["text"] else { throw CocoaError(.fileReadCorruptFile) }
        return MobileRenderedNote(html: html, text: text)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failure = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failure = error }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = CocoaError(.fileReadUnknown) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler((url?.scheme == AssetSchemeHandler.scheme && url?.host == "editor") || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}
