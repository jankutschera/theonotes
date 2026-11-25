// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
import UIKit
@testable import BaerchenIOS

/// A9 on iPhone and iPad: the attachment choices.
@Suite(.serialized) @MainActor struct MobileExportChoicesTests {
    private func makeLibrary() throws -> MobileLibrary {
        try MobileLibrary(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("export-choices-" + UUID().uuidString)))
    }

    @Test func preferencesFromBeforeTheChoicesReadAsTheDefaults() throws {
        let old = try JSONDecoder().decode(MobilePreferences.self, from: Data(#"{"keepTagsOnExport":false}"#.utf8))
        #expect(old.exportIncludeAttachments && !old.exportEmbedImages && !old.keepTagsOnExport)
        var changed = MobilePreferences()
        changed.exportIncludeAttachments = false; changed.exportEmbedImages = true
        let again = try JSONDecoder().decode(MobilePreferences.self, from: JSONEncoder().encode(changed))
        #expect(!again.exportIncludeAttachments && again.exportEmbedImages)
    }

    @Test func textBundleFollowsTheAttachmentSwitch() async throws {
        let library = try makeLibrary()
        defer { try? library.close(); try? FileManager.default.removeItem(at: library.paths.root) }
        let note = try library.store.create(text: "# Trip\n![](photo.png)")
        let name = try library.addAttachment(data: Data("png".utf8), filename: "photo.png", noteID: note.id)
        var preferences = MobilePreferences()
        let access = try MobileExportAccess(library: library, ids: [note.id])
        let with = try await access.document(format: .textBundle, preferences: preferences, dark: false)
        #expect(with.fileWrappers?["assets"]?.fileWrappers?[name] != nil)
        preferences.exportIncludeAttachments = false
        let without = try await access.document(format: .textBundle, preferences: preferences, dark: false)
        #expect(without.fileWrappers?["assets"] == nil)
        #expect(String(decoding: try #require(without.fileWrappers?["text.md"]?.regularFileContents), as: UTF8.self).contains("![](\(name))"))
    }
}
