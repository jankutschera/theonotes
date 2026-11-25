// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import WebKit

/// Hosts the controller's web view; the controller (and so the web view) outlives view updates.
/// The web view sits in a container of its own: when the controller has to replace it (a locked
/// note's page that would not clear), the new one takes its place in the same container.
struct EditorWebView: NSViewRepresentable {
    let controller: EditorBridgeController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = controller.webView
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
