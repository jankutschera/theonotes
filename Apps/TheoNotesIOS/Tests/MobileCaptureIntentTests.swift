// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import TheoNotesCore
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import BaerchenIOS

@Suite(.serialized) @MainActor
struct MobileCaptureIntentTests {
    @Test func singleActionReturnsAndCopiesAnOpenableLinkWithAutomaticTitle() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("capture-intent-" + UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        MobileShortcutRuntime.connect(library)
        defer {
            MobileShortcutRuntime.connect(nil)
            try? library.close()
            try? FileManager.default.removeItem(at: paths.root)
        }
        let intent = SaveToBaerchen()
        intent.content = [IntentFile(data: Data("A shared thought\nExact body 🐻".utf8), filename: "Text.txt", type: .utf8PlainText)]
        #expect(intent.copyNoteLink)
        let result = try await intent.perform()
        let url = try #require(result.value)
        #expect(url.scheme == AppIdentity.current.urlSchemes[0])
        #expect(UIPasteboard.general.string == url.absoluteString)
        let id = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value)
        let note = try #require(try library.store.note(id: id))
        #expect(note.title == "A shared thought")
        #expect(note.text.contains("Exact body 🐻"))
        #expect(library.selectedID == id)
    }

    @Test func optOutAndFailureLeaveClipboardUntouched() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("capture-intent-" + UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        MobileShortcutRuntime.connect(library)
        defer {
            MobileShortcutRuntime.connect(nil)
            try? library.close()
            try? FileManager.default.removeItem(at: paths.root)
        }
        UIPasteboard.general.string = "Keep this fixture clipboard"
        let intent = SaveToBaerchen()
        intent.content = [IntentFile(data: Data("Body".utf8), filename: "Text.txt", type: .plainText)]
        intent.noteTitle = "Explicit title"
        intent.copyNoteLink = false
        _ = try await intent.perform()
        #expect(UIPasteboard.general.string == "Keep this fixture clipboard")
        #expect(try library.store.allNotes().first?.title == "Explicit title")
        intent.copyNoteLink = true
        intent.content = []
        await #expect(throws: MobileShortcutCapture.Failure.emptyInput) { _ = try await intent.perform() }
        #expect(UIPasteboard.general.string == "Keep this fixture clipboard")
        #expect(try library.store.allNotes().count == 1)
        MobileShortcutRuntime.connect(nil)
        await #expect(throws: (any Error).self) { _ = try await intent.perform() }
        #expect(UIPasteboard.general.string == "Keep this fixture clipboard")
    }
}
