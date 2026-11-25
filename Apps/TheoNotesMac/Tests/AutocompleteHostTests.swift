// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M3 Task 7, host side: `requestCompletions` → `completionResults`, TagCons (`tagIcons` and the
/// `baerchen-asset://tagcon/v2/` images) and the `autocomplete` setting (`setSettings`).
@MainActor
@Suite(.serialized) struct AutocompleteHostTests {
    let root: URL
    let environment: AppEnvironment
    let page = FakeEditorPage()
    let controller: EditorBridgeController
    let noteId: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesMacTests-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
        noteId = try environment.store.create(text: "Source\n## Stored").id
        controller = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
    }

    private func request(_ id: String, _ kind: CompletionKind, _ query: String, title: String? = nil, note: String? = nil) {
        _ = controller.handle(.requestCompletions(CompletionRequest(
            noteId: note ?? noteId, requestId: id, kind: kind, query: query, noteTitle: title
        )))
    }

    private var results: [(id: String, items: [CompletionItem])] {
        page.delivered.compactMap { if case let .completionResults(id, items) = $0 { (id, items) } else { nil } }
    }

    private var settings: [EditorSettings] {
        page.delivered.compactMap { if case .setSettings(let s) = $0 { s } else { nil } }
    }

    private var tagIcons: [[String: String]] {
        page.delivered.compactMap { if case .tagIcons(let map) = $0 { map } else { nil } }
    }

    private func ready() throws {
        try controller.open(noteId: noteId)
        _ = controller.handle(.ready(version: EditorBridge.version))
    }

    @Test func tagCompletionsAreAnswered() async throws {
        _ = try environment.store.create(text: "Work\n#work #wonder")
        try ready()
        request("r1", .tag, "wor")
        await controller.completionAnswer?.value
        #expect(results.map(\.id) == ["r1"])
        #expect(results.last?.items.first == CompletionItem(label: "work", insert: "#work ", detail: "1", icon: "briefcase"))
    }

    @Test func cachedNoteTitlesFollowChangeNotifications() async throws {
        let plan = try environment.store.create(text: "Plan")
        try ready()
        request("r1", .note, "pl")
        await controller.completionAnswer?.value
        #expect(results.last?.items == [CompletionItem(label: "Plan", insert: "Plan")])
        try environment.store.archive([plan.id])
        environment.databaseDidChange()
        request("r2", .note, "pl")
        await controller.completionAnswer?.value
        #expect(results.last?.items == [CompletionItem(label: "Plan", insert: "Plan", detail: "Archive")])
    }

    @Test func onlyTheLatestRequestIsAnswered() async throws {
        _ = try environment.store.create(text: "Work\n#work")
        try ready()
        request("r1", .tag, "w")
        request("r2", .tag, "wo")
        await controller.completionAnswer?.value
        #expect(results.map(\.id) == ["r2"])
    }

    @Test func headingsOfTheShownNoteComeFromItsSession() async throws {
        try ready()
        let changeSet = ChangeSet(sections: [.retain(16), .replace(deleteLength: 0, insert: "\n## Typed")])
        #expect(controller.handle(.changes(noteId: noteId, txId: "t1", baseRevision: 0, revision: 1, changeSet: changeSet))
            == .acked(revision: 1))
        request("r1", .heading, "", title: "")
        await controller.completionAnswer?.value
        #expect(results.last?.items.map(\.label) == ["Stored", "Typed"])
    }

    @Test func requestsForAnotherNoteGetAnEmptyAnswer() async throws {
        _ = try environment.store.create(text: "Work\n#work")
        try ready()
        request("r1", .tag, "wo", note: "elsewhere")
        await controller.completionAnswer?.value
        #expect(results.map(\.id) == ["r1"])
        #expect(results.last?.items == [])
    }

    @Test func theAutocompleteSettingReachesTheEditorAndGatesAnswers() async throws {
        _ = try environment.store.create(text: "Work\n#work")
        let stored = TheoNotesCore.Settings(db: environment.database)
        stored.autocomplete = false
        let off = EditorBridgeController(environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try off.open(noteId: noteId)
        _ = off.handle(.ready(version: EditorBridge.version))
        #expect(settings == [EditorSettings(autocomplete: false)])
        // Sent before the note, so the first render already knows.
        #expect(page.delivered.firstIndex(of: .setSettings(EditorSettings(autocomplete: false)))!
            < page.delivered.firstIndex { if case .loadNote = $0 { true } else { false } }!)
        _ = off.handle(.requestCompletions(CompletionRequest(noteId: noteId, requestId: "r1", kind: .tag, query: "wo", noteTitle: nil)))
        await off.completionAnswer?.value
        #expect(results.last?.items == [])

        stored.autocomplete = true
        try await waitUntil("setSettings on", timeout: .seconds(5)) { settings.count == 2 }
        #expect(settings.last == EditorSettings(autocomplete: true))
    }

    @Test func theDefaultSettingIsNotSent() throws {
        try ready()
        #expect(settings.isEmpty)
        #expect(tagIcons.isEmpty) // no tags yet: the editor's empty map is right
    }

    @Test func tagIconsAreSentOnReadyAndWhenTheyChange() throws {
        _ = try environment.store.create(text: "x #work #Reisen")
        try ready()
        #expect(tagIcons == [["work": "briefcase", "reisen": "airplane"]])
        environment.databaseDidChange()
        #expect(tagIcons.count == 1) // unchanged: not sent again

        try environment.store.setTagIcon("work", symbol: "star.fill")
        environment.databaseDidChange()
        #expect(tagIcons.last == ["work": "star.fill", "reisen": "airplane"])

        // A new page (web content restarted) starts empty: sent again.
        controller.simulateWebContentTermination()
        _ = controller.handle(.ready(version: EditorBridge.version))
        #expect(tagIcons.count == 3)
    }
}

@MainActor
@Suite struct TagConAssetTests {
    @Test func symbolsAreServedAsTemplatePNGs() throws {
        let handler = AssetSchemeHandler(root: FileManager.default.temporaryDirectory)
        let icon = handler.response(for: URL(string: "baerchen-asset://tagcon/v2/briefcase.png")!)
        #expect(icon.statusCode == 200)
        #expect(icon.headers["Content-Type"] == "image/png")
        #expect(icon.headers["Cache-Control"] == "max-age=31536000, immutable")
        // Rendered once for every handler (one per web view).
        #expect(AssetSchemeHandler(root: FileManager.default.temporaryDirectory)
            .response(for: URL(string: "baerchen-asset://tagcon/v2/briefcase.png")!).body == icon.body)
        #expect(icon.headers["Content-Security-Policy"] == AssetSchemeHandler.contentSecurityPolicy)
        #expect(icon.body.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let image = try #require(NSImage(data: icon.body))
        #expect(image.representations.first?.pixelsWide == AssetSchemeHandler.tagconPixels)
        // Opaque pixels only where the symbol is (a mask the editor tints).
        let bitmap = try #require(NSBitmapImageRep(data: icon.body))
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        let center = bitmap.colorAt(x: AssetSchemeHandler.tagconPixels / 2, y: AssetSchemeHandler.tagconPixels / 2)
        #expect(center != nil)

        #expect(handler.response(for: URL(string: "baerchen-asset://tagcon/v2/folder.fill.png")!).statusCode == 200)
        for bad in [
            "baerchen-asset://tagcon/v2/no.such.symbol.zzz.png",
            // Unversioned and other versions are refused (M3 triage #45).
            "baerchen-asset://tagcon/briefcase.png",
            "baerchen-asset://tagcon/v1/briefcase.png",
            "baerchen-asset://tagcon/v2/briefcase",
            "baerchen-asset://tagcon/v2/../editor/index.png",
            "baerchen-asset://tagcon/v2/Briefcase.png",
            "baerchen-asset://tagcon/v2/a%20b.png",
            "baerchen-asset://tagcon/v2/",
            "baerchen-asset://tagcon/",
        ] {
            #expect(handler.response(for: URL(string: bad)!).statusCode == 404, "\(bad)")
        }
    }
}
