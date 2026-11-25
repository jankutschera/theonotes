// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UIKit
@testable import BaerchenIOS

/// A14 on iPhone and iPad: the import options reach the importer.
@Suite(.serialized) @MainActor struct MobileImportOptionsTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("export-choices-" + UUID().uuidString)))
    }

    @Test func importOptionsReachTheImporter() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let input = library.paths.root.appendingPathComponent("plain.md")
        try FileManager.default.createDirectory(at: library.paths.root, withIntermediateDirectories: true)
        try Data("Shopping list\nfor #3rd and #work\n".utf8).write(to: input)
        _ = try await library.importNotes([input], options: FileImportOptions(titleFromFirstLine: true, keepHashNumbersAsText: true))
        var imported = try #require(try library.store.allNotes().first)
        #expect(imported.text.hasPrefix("# Shopping list"))
        #expect(imported.text.contains("\\#3rd") && imported.text.contains("#work") && !imported.text.contains("\\#work"))
        try library.store.trash([imported.id])
        try Data("Other title\n".utf8).write(to: input)
        _ = try await library.importNotes([input])
        imported = try #require(try library.store.allNotes().first { $0.text.hasPrefix("Other title") })
        #expect(imported.text == "Other title\n")
    }
}
