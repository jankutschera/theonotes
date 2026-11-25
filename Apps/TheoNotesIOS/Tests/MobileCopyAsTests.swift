// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UIKit
@testable import BaerchenIOS

/// A10 on iPhone and iPad: Copy As.
@Suite(.serialized) @MainActor struct MobileCopyAsTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("export-choices-" + UUID().uuidString)))
    }

    @Test func copyAsMarkdownFollowsKeepTagsButAnExportKeepsTagsAsWritten() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Trip\nBold **word**\n#travel/2026")
        var preferences = MobilePreferences()
        preferences.keepTagsOnExport = false
        let access = try MobileExportAccess(library: library, ids: [note.id])
        _ = try await access.document(format: .markdown, preferences: preferences, dark: false, copy: true)
        #expect(!access.plainText.contains("#travel") && access.plainText.contains("**word**"))
        let exported = try await access.document(format: .markdown, preferences: preferences, dark: false)
        #expect(String(decoding: try #require(exported.regularFileContents), as: UTF8.self).contains("#travel/2026"))
        preferences.keepTagsOnExport = true
        _ = try await access.document(format: .markdown, preferences: preferences, dark: false, copy: true)
        #expect(access.plainText.contains("#travel/2026"))
    }

    @Test func aSelectionIsTheSourceOfTheCopy() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Trip\nfirst **line**\nsecond line")
        let access = try MobileExportAccess(library: library, ids: [note.id])
        _ = try await access.document(format: .markdown, preferences: MobilePreferences(), dark: false, selection: "first **line**", copy: true)
        #expect(access.plainText == "first **line**")
        _ = try await access.document(format: .plainText, preferences: MobilePreferences(), dark: false, selection: "first **line**", copy: true)
        #expect(access.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == "first line")
    }

    @Test func pasteboardCarriesTextOnlyForMarkdownAndPlainTextAndTheFormatTypeForTheRest() throws {
        MobileCopyAs.write(.markdown, bytes: Data("a **b**".utf8), plainText: "a **b**")
        #expect(UIPasteboard.general.string == "a **b**")
        #expect(UIPasteboard.general.types.contains("public.rtf") == false && UIPasteboard.general.types.contains("public.html") == false)
        MobileCopyAs.write(.rtf, bytes: Data("{\\rtf1 b}".utf8), plainText: "b")
        #expect(UIPasteboard.general.string == "b")
        #expect(UIPasteboard.general.types.contains("public.rtf"))
        #expect(MobileCopyAs.allCases.map(\.title) == ["Markdown", "Plain Text", "HTML", "Rich Text"])
    }
}
