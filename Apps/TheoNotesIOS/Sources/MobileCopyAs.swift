// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Note Actions ▸ Copy As (A10): the selected text, else the whole note.
enum MobileCopyAs: CaseIterable {
    case markdown, plainText, html, richText

    var title: String {
        switch self { case .markdown: "Markdown"; case .plainText: "Plain Text"; case .html: "HTML"; case .richText: "Rich Text" }
    }
    var format: MobileExportFormat {
        switch self { case .markdown: .markdown; case .plainText: .plainText; case .html: .html; case .richText: .rtf }
    }

    /// Markdown and Plain Text put text only on the pasteboard; HTML and Rich Text add their own type before the plain text.
    @MainActor static func write(_ format: MobileExportFormat, bytes: Data, plainText: String) {
        var item: [String: Any] = [UTType.utf8PlainText.identifier: Data(plainText.utf8)]
        if format != .markdown, format != .plainText { item[format.contentType.identifier] = bytes }
        UIPasteboard.general.setItems([item], options: [.localOnly: true])
    }
}
