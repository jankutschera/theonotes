// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import PDFKit
import UIKit

@MainActor
final class Thumbnails {
    enum Variant { case icon, preview }
    init(paths: AppPaths) {}

    func png(for file: URL, noteId: String, variant: Variant) async -> Data? {
        if variant == .icon { return UIImage(systemName: "doc.fill")?.pngData() }
        if file.pathExtension.lowercased() == "pdf", let page = PDFDocument(url: file)?.page(at: 0) {
            return page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox).pngData()
        }
        return UIImage(contentsOfFile: file.path)?.pngData()
    }
}
