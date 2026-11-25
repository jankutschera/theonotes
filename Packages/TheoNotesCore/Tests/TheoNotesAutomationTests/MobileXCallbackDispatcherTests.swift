// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotesAutomation

@Suite @MainActor struct MobileXCallbackDispatcherTests {
    @MainActor private struct Fixture {
        let paths: AppPaths, db: AppDatabase, store: NoteStore, dispatcher: MobileXCallbackDispatcher
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            try paths.createDirectories(); db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
            dispatcher = MobileXCallbackDispatcher(database: db, paths: paths, store: store)
        }
        func close() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
    }
    private func request(_ action: String, _ values: [String: String] = [:]) throws -> MobileXCallbackRequest {
        var url = URLComponents(string: "baerchen://x-callback-url/" + action)!
        url.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try MobileXCallbackRequest(url.url!)
    }
    @Test func invalidTokenPrecedesCreationAndExistingDataNeedsAuthorization() async throws {
        let f = try Fixture(); defer { f.close() }
        do { _ = try await f.dispatcher.execute(request("create", ["text": "Secret", "token": "wrong"]), token: "correct"); Issue.record("Invalid token accepted") }
        catch MobileXCallbackFailure.unauthorized {}
        #expect(try f.store.allNotes().isEmpty)
        let created = try await f.dispatcher.execute(request("create", ["title": "Caller", "text": "Exact **text**", "tags": "work/mobile", "open_note": "no"]), token: nil)
        let id = try #require(created.values["identifier"])
        #expect(created.noteID == nil)
        #expect(created.values["title"] == "Caller")
        let hidden = try await f.dispatcher.execute(request("open-note", ["id": id]), token: nil)
        #expect(hidden.noteID == id && hidden.values.isEmpty)
        let readable = try await f.dispatcher.execute(request("open-note", ["id": id, "token": "correct"]), token: "correct")
        #expect(readable.values["note"]?.contains("Exact **text**") == true)
    }
    @Test func selectedAndLockedNotesCannotBypassTokenOrPrivacyGates() async throws {
        let f = try Fixture(); defer { f.close() }
        let note = try f.store.create(text: "Visible")
        do { _ = try await f.dispatcher.execute(request("add-text", ["selected": "yes", "text": "bad"]), token: "correct", selectedID: note.id); Issue.record("Selected note read without token") }
        catch MobileXCallbackFailure.unauthorized {}
        #expect(try f.store.note(id: note.id)?.text == "Visible")
        let locked = MobileXCallbackDispatcher(database: f.db, paths: f.paths, store: f.store, canAccess: { false })
        do { _ = try await locked.execute(request("create", ["text": "bad"]), token: nil); Issue.record("Locked application mutated") }
        catch MobileXCallbackFailure.locked {}
        #expect(try f.store.allNotes().count == 1)
    }
    @Test func editsPreserveHeadersAndAttachmentNamesAndRefreshRevisions() async throws {
        let f = try Fixture(); defer { f.close() }
        let note = try f.store.create(text: "# Title\n## Area\nold\n## Next\nkeep")
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "header": "Area", "mode": "replace", "text": "new"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text == "# Title\n## Area\nnew\n## Next\nkeep")
        let bytes = Data("fixture".utf8)
        _ = try await f.dispatcher.execute(request("add-file", ["id": note.id, "filename": "file.txt", "file": bytes.base64EncodedString()]), token: nil)
        #expect(try Data(contentsOf: f.paths.attachments.appendingPathComponent(note.id).appendingPathComponent("file.txt")) == bytes)
        do { _ = try await f.dispatcher.execute(request("add-file", ["id": note.id, "filename": "../outside", "file": bytes.base64EncodedString()]), token: nil); Issue.record("Unsafe filename accepted") }
        catch MobileXCallbackFailure.invalidRequest {}
    }
    @Test func navigationAndTokenListsCoverTagSearchSectionsWorkspaceAndMoves() async throws {
        let f = try Fixture(); defer { f.close() }
        let note = try f.store.create(text: "# Hello\n- [ ] todo\n#work/mobile")
        for action in ["open-tag", "search", "untagged", "todo", "today", "locked"] {
            var values = ["token": "token"]
            if action == "open-tag" { values["name"] = "work" }
            let result = try await f.dispatcher.execute(request(action, values), token: "token")
            #expect(result.scope != nil)
            #expect(action == "locked" ? result.values.isEmpty : result.values["notes"] != nil)
        }
        let tags = try await f.dispatcher.execute(request("tags", ["token": "token"]), token: "token")
        let returnedTags = try JSONDecoder().decode([[String: String]].self, from: Data(try #require(tags.values["tags"]).utf8))
        #expect(returnedTags.contains { $0["name"] == "work/mobile" })
        _ = try await f.dispatcher.execute(request("rename-tag", ["name": "work", "new_name": "life"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text.contains("#life/mobile") == true)
        let workspace = try await f.dispatcher.execute(request("open-workspace", ["name": "life"]), token: nil)
        #expect(workspace.changesWorkspace && workspace.workspace == "life")
        #expect(try await f.dispatcher.execute(request("close-workspace"), token: nil).changesWorkspace)
        _ = try await f.dispatcher.execute(request("archive", ["id": note.id]), token: nil)
        #expect(try f.store.note(id: note.id)?.location == .archive)
        _ = try await f.dispatcher.execute(request("trash", ["id": note.id]), token: nil)
        #expect(try f.store.note(id: note.id)?.location == .trash)
        _ = try await f.dispatcher.execute(request("delete-tag", ["name": "life"]), token: nil)
    }
    private struct Fetcher: URLFetcher {
        var beforeReturn: (@Sendable () async -> Void)?
        func fetch(_ url: URL) async throws -> (data: Data, suggestedName: String?) {
            await beforeReturn?()
            return (Data("<h1>Fetched</h1><p>Safe content</p>".utf8), "page.html")
        }
    }
    @MainActor private final class Gate { var allowed = true }
    @Test func grabURLUsesInjectedFetcherAndRechecksPrivacyAfterAwait() async throws {
        let f = try Fixture(); defer { f.close() }
        let good = MobileXCallbackDispatcher(database: f.db, paths: f.paths, store: f.store, fetcher: Fetcher())
        let created = try await good.execute(request("grab-url", ["url": "https://example.com/page"]), token: nil)
        #expect(created.values["title"] == "Fetched")
        // The app settles an answered request; unsettled, the repeat below would get the first note back (REL-R92).
        XCallbackReceipts(database: f.db).settle(try #require(created.receipt))
        let count = try f.store.allNotes().count, gate = Gate()
        let fetcher = Fetcher(beforeReturn: { await MainActor.run { gate.allowed = false } })
        let blocked = MobileXCallbackDispatcher(database: f.db, paths: f.paths, store: f.store, fetcher: fetcher, canAccess: { gate.allowed })
        do { _ = try await blocked.execute(request("grab-url", ["url": "https://example.com/page"]), token: nil); Issue.record("Capture mutated a locked application") }
        catch MobileXCallbackFailure.locked {}
        #expect(try f.store.allNotes().count == count)
    }
    @Test func htmlBaseURLAndClipboardAreCallerSuppliedAndDoNotRequireReadToken() async throws {
        let f = try Fixture(); defer { f.close() }
        let result = try await f.dispatcher.execute(request("create", ["clipboard": "yes", "type": "html", "url": "https://example.com/base/"]), token: nil, clipboard: "<h1>Clip</h1><p><a href='../guide'>Guide</a></p>")
        let id = try #require(result.values["identifier"])
        #expect(try f.store.note(id: id)?.text.contains("https://example.com/guide") == true)
    }

    @Test func titlesResolveAcrossLocationsAndExcludeTrashedBeforeSelecting() async throws {
        let f = try Fixture(); defer { f.close() }
        let archived = try f.store.create(text: "# A    Title\nBody")
        try f.store.archive([archived.id])
        let result = try await f.dispatcher.execute(request("open-note", ["title": "a title"]), token: nil)
        #expect(result.noteID == archived.id)
        let trashed = try f.store.create(text: "# A Title\nTrash")
        try f.store.trash([trashed.id])
        let excluded = try await f.dispatcher.execute(request("open-note", ["title": "A Title", "exclude_trashed": "yes"]), token: nil)
        #expect(excluded.noteID == archived.id)
    }

    @Test func archivedAndTrashedIDsRemainEditableUnlessExplicitlyExcluded() async throws {
        let f = try Fixture(); defer { f.close() }
        let note = try f.store.create(text: "# Kept\nBody")
        try f.store.archive([note.id])
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "text": " A"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text.hasSuffix(" A") == true)
        try f.store.trash([note.id])
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "text": " B"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text.hasSuffix(" B") == true)
        do { _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "text": " forbidden", "exclude_trashed": "yes"]), token: nil); Issue.record("Trashed note edited despite exclusion") }
        catch MobileXCallbackFailure.missingNote {}
    }

    @Test func replacePreservesFrontmatterAndExactParsedTitleWhileReplacingOnlyTheBody() async throws {
        let f = try Fixture(); defer { f.close() }
        let prefix = "---\ntitle: YAML metadata\nowner: Jan\n---\n# Actual **title** 🐻"
        let note = try f.store.create(text: prefix + "\nOld body\n\n#old-tag")
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "mode": "replace", "text": "New **body**\nSecond line"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text == prefix + "\nNew **body**\nSecond line")
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "mode": "replace", "text": ""]), token: nil)
        #expect(try f.store.note(id: note.id)?.text == prefix)
    }
    @Test func replaceKeepsLegacyFirstLineAndReplaceAllStillReplacesEverything() async throws {
        let f = try Fixture(); defer { f.close() }
        let note = try f.store.create(text: "Plain legacy title\nOld body")
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "mode": "replace", "text": "New body"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text == "Plain legacy title\nNew body")
        _ = try await f.dispatcher.execute(request("add-text", ["id": note.id, "mode": "replace_all", "text": "Replacement title\nReplacement body"]), token: nil)
        #expect(try f.store.note(id: note.id)?.text == "Replacement title\nReplacement body")
    }

    @Test func appSchemesAreAcceptedAndNoneIsACallbackTarget() throws {
        for scheme in AppIdentity.production.urlSchemes + AppIdentity.dev.urlSchemes {
            let value = try MobileXCallbackRequest(URL(string: "\(scheme)://x-callback-url/open-note?id=1&x-success=shortcuts://done")!)
            #expect(value.action == "open-note" && value.parameters["id"] == "1", "\(scheme)")
            #expect(throws: MobileXCallbackFailure.self) {
                try MobileXCallbackRequest(URL(string: "\(scheme)://x-callback-url/open-note?id=1&x-success=\(scheme)://x")!)
            }
        }
        #expect(throws: MobileXCallbackFailure.self) { try MobileXCallbackRequest(URL(string: "theonotes://elsewhere/open-note?id=1")!) }
    }

    @Test func callbackEncodingAndDuplicateAndUnsafeURLsAreRejected() throws {
        let value = try request("open-note", ["id": "id", "x-success": "shortcuts://done?existing=1"])
        let callback = try #require(value.callback(value.success, values: ["note": "a&b + 👩‍💻"]))
        #expect(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "note" })?.value == "a&b + 👩‍💻")
        #expect(throws: MobileXCallbackFailure.self) { try MobileXCallbackRequest(URL(string: "baerchen://x-callback-url/create?text=a&text=b")!) }
        #expect(throws: MobileXCallbackFailure.self) { try request("create", ["x-success": "javascript:alert(1)"]) }
        #expect(throws: MobileXCallbackFailure.self) { try MobileXCallbackRequest(URL(string: "bear://x-callback-url/create?text=a")!) }
    }
}
