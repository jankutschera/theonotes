// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation

/// Rich text for RTF export (M8-R6, M8-R65): the renderer's `richText` fragment (inline styles, no
/// classes, images as `[filename]`) becomes an attributed string and then RTF data.
///
/// AppKit's HTML importer is WebKit-backed and documented as main thread only
/// (`NSAttributedString.init(data:options:documentAttributes:)`), hence `@MainActor`. The fragment
/// has no `<img>`, so the importer has nothing to fetch.
enum RichText {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case notHTML
        case rtfFailed

        var description: String {
            switch self {
            case .notHTML: "the note could not be converted to rich text"
            case .rtfFailed: "the rich text could not be written as RTF"
            }
        }
    }

    @MainActor
    static func attributed(fromFragment html: String) throws -> NSAttributedString {
        let document = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(html)</body></html>"
        do {
            return try NSAttributedString(
                data: Data(document.utf8),
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil)
        } catch {
            throw Failure.notHTML
        }
    }

    @MainActor
    static func rtfData(fromFragment html: String) throws -> Data {
        let text = try attributed(fromFragment: html)
        do {
            return try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        } catch {
            throw Failure.rtfFailed
        }
    }

    /// Word (DOCX) from the same attributed string, through our own writer (A8, MAC11-R15).
    @MainActor
    static func docxData(fromFragment html: String) throws -> Data {
        DocxWriter.data(from: try attributed(fromFragment: html))
    }
}
