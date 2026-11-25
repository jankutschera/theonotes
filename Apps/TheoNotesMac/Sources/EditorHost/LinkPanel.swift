// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Observation
import SwiftUI
import WebKit

/// The ⌘K link panel's fields and its one answer (inventory §2.2.1: insert or edit a link).
@MainActor
@Observable
final class LinkPanelModel {
    enum Result: Equatable {
        case apply(title: String, url: String)
        /// Keeps the title as plain text.
        case remove
        case cancel
    }

    var title: String
    var url: String
    /// The panel edits an existing `[title](url)` link: offers Remove Link.
    let isEditing: Bool
    /// Closes the popover; set by `LinkPanel`.
    @ObservationIgnored var dismiss: (() -> Void)?
    @ObservationIgnored private var onFinish: ((Result) -> Void)?

    init(title: String, url: String, editing: Bool, onFinish: @escaping (Result) -> Void) {
        self.title = title
        self.url = url
        isEditing = editing
        self.onFinish = onFinish
    }

    func submit() { finish(.apply(title: title, url: url)) }
    func remove() { finish(.remove) }
    func cancel() { finish(.cancel) }

    /// The first answer counts; later ones (the popover closing after Return) are ignored.
    private func finish(_ result: Result) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(result)
        dismiss?()
    }
}

struct LinkPanelView: View {
    @Bindable var model: LinkPanelModel
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Form {
                TextField("Title", text: $model.title)
                TextField("URL", text: $model.url, prompt: Text("https://"))
                    .focused($urlFocused)
            }
            .onSubmit { model.submit() }
            HStack {
                if model.isEditing {
                    Button("Remove Link", role: .destructive) { model.remove() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isEditing ? "Update" : "Add Link") { model.submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { urlFocused = true }
    }
}

/// Shows the link panel as a popover anchored at the editor's caret.
@MainActor
final class LinkPanel: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var model: LinkPanelModel?

    func present(_ model: LinkPanelModel, at caret: CaretRect, in webView: WKWebView) {
        self.model?.cancel()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: LinkPanelView(model: model))
        track(model, popover: popover)
        let zoom = webView.pageZoom * webView.magnification
        let rect = Self.anchorRect(caret, bounds: webView.bounds, isFlipped: webView.isFlipped, zoom: zoom)
        popover.show(relativeTo: rect, of: webView, preferredEdge: .maxY)
    }

    /// The panel shown in `popover` is the current one.
    func track(_ model: LinkPanelModel, popover: NSPopover) {
        popover.delegate = self
        model.dismiss = { [weak popover] in popover?.performClose(nil) }
        self.popover = popover
        self.model = model
    }

    func popoverDidClose(_ notification: Notification) {
        // Only the current popover (an older one closing after a new ⌘K must not cancel it).
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        // Clicking outside (transient) is a cancel; after an answer this does nothing.
        model?.cancel()
        model = nil
        popover = nil
    }

    /// The caret (web view viewport CSS px) in the web view's coordinates, clamped into its bounds.
    nonisolated static func anchorRect(_ caret: CaretRect, bounds: NSRect, isFlipped: Bool, zoom: CGFloat) -> NSRect {
        let width = max(1, caret.width * zoom)
        let height = max(1, caret.height * zoom)
        let x = min(max(bounds.minX, caret.x * zoom), bounds.maxX - width)
        var y = caret.y * zoom
        if !isFlipped { y = bounds.height - y - height }
        y = min(max(bounds.minY, y), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
