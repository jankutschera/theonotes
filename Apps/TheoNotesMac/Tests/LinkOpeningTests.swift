// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// Opening links from the editor (`openLink`) and the ⌘K link panel (`editLinkRequest` → `setLink`),
/// with a fake editor page.
@MainActor
@Suite struct LinkOpeningTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesLinkTests-\(UUID().uuidString)"
        let environment: AppEnvironment
        let page = FakeEditorPage()
        let editor: EditorBridgeController
        let state: MainWindowState
        let sourceId: String

        init(source: String = "see [[Other]]", setUp: (NoteStore) throws -> Void = { _ in }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesLinks-\(UUID().uuidString)", isDirectory: true)
            environment = try AppEnvironment(paths: AppPaths(root: root))
            try setUp(environment.store)
            sourceId = try environment.store.create(text: source).id
            var urls: [URL] = []
            editor = EditorBridgeController(
                environment: environment, page: page, openExternally: { urls.append($0) }, checksumInterval: nil
            )
            _ = editor.handle(.ready(version: EditorBridge.version))
            state = MainWindowState(environment: environment, defaults: UserDefaults(suiteName: suiteName)!, editor: editor)
            state.model.selectNotes([sourceId])
            state.showFocusedNote()
            openedURLs = { urls }
        }

        private var openedURLs: () -> [URL] = { [] }
        var externallyOpened: [URL] { openedURLs() }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }
        var model: LibraryModel { state.model }

        func open(_ kind: LinkKind, _ target: String, heading: String? = nil, newWindow: Bool = false, noteId: String? = nil) {
            _ = editor.handle(.openLink(OpenLinkRequest(
                noteId: noteId ?? editor.session?.noteId ?? "", kind: kind, target: target, heading: heading, newWindow: newWindow
            )))
        }

        var loadedNoteIds: [String] {
            page.delivered.compactMap { if case let .loadNote(id, _, _, _, _, _, _) = $0 { id } else { nil } }
        }

        var scrolls: [HostToEditorMessage] {
            page.delivered.filter { if case .scrollToHeading = $0 { true } else { false } }
        }
    }

    // MARK: - Wiki links

    @Test func aWikiLinkShowsItsNoteInTheEditorAndTheList() throws {
        var other = ""
        let env = try Env { other = try $0.create(text: "Other\nbody").id }
        env.open(.wiki, "other")
        #expect(env.model.focusedNoteID == other)
        #expect(env.model.selectedNoteIDs == [other])
        #expect(env.editor.session?.noteId == other)
        #expect(env.loadedNoteIds.last == other)
        #expect(env.scrolls.isEmpty)
    }

    @Test func aHeadingTargetScrollsAfterTheNoteIsLoaded() throws {
        var other = ""
        let env = try Env { other = try $0.create(text: "# Other\n## Intro\n## Next Steps").id }
        env.open(.wiki, "Other", heading: "next steps")
        // Then the editor is focused (the caret goes into the destination note).
        #expect(env.page.delivered.last == .focus)
        let last = Array(env.page.delivered.dropLast().suffix(2))
        guard last.count == 2, case .loadNote(other, _, _, _, _, _, _) = last[0] else {
            Issue.record("expected loadNote then scrollToHeading, got \(last)")
            return
        }
        #expect(last[1] == .scrollToHeading(noteId: other, index: 2))
    }

    @Test func aSameNoteHeadingScrollsWithoutReloading() throws {
        let env = try Env(source: "# Top\n## Part\n[[/Part]]")
        let loads = env.loadedNoteIds.count
        env.open(.wiki, "", heading: "Part")
        #expect(env.loadedNoteIds.count == loads)
        #expect(env.scrolls == [.scrollToHeading(noteId: env.sourceId, index: 1)])
    }

    @Test func aMissingTargetIsCreatedAndShownWithTheCaretAtItsEnd() throws {
        let env = try Env()
        env.open(.wiki, "Brand New")
        let id = try #require(env.model.focusedNoteID)
        #expect(id != env.sourceId)
        #expect(try env.store.note(id: id)?.text == "# Brand New")
        guard case let .loadNote(loaded, _, _, _, selection, _, _) = try #require(env.page.loadNotes.last) else { return }
        #expect(loaded == id)
        #expect(selection == SelectionRange(anchor: 11, head: 11))
    }

    /// Final review I2 (R31): a note a click creates in a workspace gets the workspace's tag, so
    /// the window stays in the workspace and lists it; the caret ends the title line.
    @Test func aMissingTargetInAWorkspaceGetsItsTagAndKeepsTheWorkspace() throws {
        let env = try Env(source: "see [[Launch plan]] #adhd-founder") { _ = try $0.create(text: "Other #home") }
        env.model.enterWorkspace("adhd-founder")
        #expect(env.editor.session?.noteId == env.sourceId)
        env.open(.wiki, "Launch plan")
        let id = try #require(env.model.focusedNoteID)
        #expect(id != env.sourceId)
        #expect(try env.store.note(id: id)?.text == "# Launch plan\n#adhd-founder")
        #expect(env.model.workspace == Workspace(path: "adhd-founder"))
        #expect(env.model.items.contains { $0.id == id })
        guard case let .loadNote(loaded, _, _, _, selection, _, _) = try #require(env.page.loadNotes.last) else { return }
        #expect(loaded == id)
        #expect(selection == SelectionRange(anchor: 13, head: 13))
    }

    @Test func aTargetOutsideTheScopeSwitchesToTheSectionListingIt() throws {
        var archived = ""
        let env = try Env(source: "#work see [[Old]]") {
            archived = try $0.create(text: "Old").id
            try $0.archive([archived])
        }
        env.model.selectScope(.tag("work"))
        env.open(.wiki, "Old")
        #expect(env.model.scope == .archive)
        #expect(env.model.focusedNoteID == archived)
    }

    @Test func newWindowGoesThroughTheSeamOrFallsBackToThisWindow() throws {
        var other = ""
        let env = try Env { other = try $0.create(text: "# Other\n## H").id }
        var requested: [(String, Int?)] = []
        env.state.links.openNoteInNewWindow = { requested.append(($0, $1)) }
        env.open(.wiki, "Other", heading: "H", newWindow: true)
        #expect(requested.map(\.0) == [other])
        #expect(requested.map(\.1) == [1])
        #expect(env.model.focusedNoteID == env.sourceId)

        env.state.links.openNoteInNewWindow = nil
        env.open(.wiki, "Other", newWindow: true)
        #expect(env.model.focusedNoteID == other)
    }

    @Test func linksFromANoteNotShownAreIgnored() throws {
        let env = try Env { _ = try $0.create(text: "Other").id }
        env.open(.wiki, "Other", noteId: "someone-else")
        env.open(.url, "https://example.com", noteId: "someone-else")
        #expect(env.model.focusedNoteID == env.sourceId)
        #expect(env.externallyOpened.isEmpty)
    }

    // MARK: - URLs

    @Test func onlyWebAndMailURLsOpenExternally() throws {
        let env = try Env()
        env.open(.url, "https://example.com/faq")
        env.open(.url, "mailto:hi@example.com")
        env.open(.url, "file:///etc/passwd")
        env.open(.url, "javascript:alert(1)")
        env.open(.url, "x-apple.systempreferences:com.apple.preference")
        env.open(.attachment, "doc.pdf")
        #expect(env.externallyOpened == [URL(string: "https://example.com/faq")!, URL(string: "mailto:hi@example.com")!])
        #expect(env.model.focusedNoteID == env.sourceId)
    }

    @Test func bearNoteURLsOpenTheImportedNoteElseBear() throws {
        var imported = ""
        let env = try Env {
            let now = Date()
            imported = try $0.importNote(
                ImportedNoteDraft(text: "Imported", createdAt: now, modifiedAt: now),
                externalRef: ExternalRefWrite(
                    source: "bear", externalId: "B-1", lastSeenModified: now, lastSeenHash: "h", lastSeenTextHash: "t",
                    lastSeenMeta: SourceMetadata(location: .notes, isPinnedGlobal: false, tagPins: [], isReadOnly: false)
                )
            ).id
        }
        env.open(.bearURL, "bear://x-callback-url/open-note?id=B-1")
        #expect(env.model.focusedNoteID == imported)
        #expect(env.externallyOpened.isEmpty)
        env.open(.bearURL, "bear://x-callback-url/open-note?id=UNKNOWN")
        env.open(.bearURL, "bear://x-callback-url/create?text=x")
        // Security: callbacks never reach Bear, neither for known nor for unknown ids.
        env.open(.bearURL, "bear://x-callback-url/open-note?id=UNKNOWN&x-success=evil://run")
        env.open(.url, "bear://x-callback-url/open-note?id=B-1&x-error=evil://run")
        #expect(env.externallyOpened == [URL(string: "bear://x-callback-url/open-note?id=UNKNOWN")!])
    }

    @Test func aKnownBearNoteOpensAtItsHeaderAndATrashedOneInTheTrash() throws {
        var imported = ""
        let env = try Env {
            let now = Date()
            imported = try $0.importNote(
                ImportedNoteDraft(text: "# Imported\n## Part One\n## Part Two", createdAt: now, modifiedAt: now),
                externalRef: ExternalRefWrite(
                    source: "bear", externalId: "B-2", lastSeenModified: now, lastSeenHash: "h", lastSeenTextHash: "t",
                    lastSeenMeta: SourceMetadata(location: .notes, isPinnedGlobal: false, tagPins: [], isReadOnly: false)
                )
            ).id
        }
        env.open(.bearURL, "bear://x-callback-url/open-note?id=B-2&header=part%20two")
        #expect(env.model.focusedNoteID == imported)
        #expect(env.scrolls == [.scrollToHeading(noteId: imported, index: 2)])

        // Minor 5: a trashed note is revealed in the Trash.
        env.model.selectNotes([env.sourceId])
        env.state.showFocusedNote()
        try env.store.trash([imported])
        env.open(.bearURL, "bear://x-callback-url/open-note?id=B-2")
        #expect(env.model.scope == .trash)
        #expect(env.model.focusedNoteID == imported)
    }

    // MARK: - Tags

    @Test func aTagSelectsItInTheSidebarWithItsSpelling() throws {
        let env = try Env(source: "notes #Work/Projects")
        env.open(.tag, "work/projects")
        #expect(env.model.scope == .tag("Work/Projects"))
        #expect(env.model.focusedNoteID == env.sourceId)
        env.open(.tag, "nope")
        #expect(env.model.scope == .tag("Work/Projects"))
    }

    // MARK: - Link panel

    @Test func theLinkPanelAnswersWithSetLinkForTheSameNote() throws {
        let env = try Env(source: "visit bear")
        var shown: [(LinkPanelModel, CaretRect)] = []
        env.state.links.presentLinkPanel = { shown.append(($0, $1)) }
        let rect = CaretRect(x: 10, y: 20, width: 1, height: 15)
        _ = env.editor.handle(.editLinkRequest(EditLinkRequest(
            noteId: env.sourceId, requestId: "r1", from: 6, to: 10, title: "bear", url: "", editing: false, caretRect: rect
        )))
        let (panel, at) = try #require(shown.first)
        #expect(at == rect)
        #expect(panel.title == "bear")
        #expect(!panel.isEditing)
        panel.url = "https://example.com"
        panel.submit()
        panel.submit() // once only
        let commands = env.page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
        #expect(commands == [.applyCommand(name: .setLink, args: [
            "requestId": .string("r1"), "title": .string("bear"), "url": .string("https://example.com"),
        ])])
    }

    /// Minor 3: the editor decides the mode; a selected plain URL fills the URL but is a new link.
    @Test func aSelectedURLOpensThePanelInInsertMode() throws {
        let env = try Env(source: "go https://example.com")
        var shown: [LinkPanelModel] = []
        env.state.links.presentLinkPanel = { panel, _ in shown.append(panel) }
        _ = env.editor.handle(.editLinkRequest(EditLinkRequest(
            noteId: env.sourceId, requestId: "r5", from: 3, to: 22, title: "https://example.com", url: "https://example.com",
            editing: false, caretRect: CaretRect(x: 0, y: 0, width: 1, height: 15)
        )))
        #expect(shown.first?.isEditing == false)
        #expect(shown.first?.url == "https://example.com")
    }

    @Test func removingAndCancellingTheLinkPanel() throws {
        let env = try Env(source: "a [Bear](https://example.com)")
        var shown: [LinkPanelModel] = []
        env.state.links.presentLinkPanel = { panel, _ in shown.append(panel) }
        let request = EditLinkRequest(
            noteId: env.sourceId, requestId: "r2", from: 2, to: 29, title: "Bear", url: "https://example.com", editing: true, caretRect: CaretRect(x: 0, y: 0, width: 1, height: 15)
        )
        _ = env.editor.handle(.editLinkRequest(request))
        _ = env.editor.handle(.editLinkRequest(request))
        #expect(shown.count == 2)
        #expect(shown[0].isEditing)
        shown[0].cancel()
        shown[1].remove()
        let commands = env.page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
        #expect(commands == [.applyCommand(name: .setLink, args: [
            "requestId": .string("r2"), "title": .string("Bear"), "url": .string(""),
        ])])
    }

    @Test func aPanelAnswerAfterANoteSwitchIsDropped() throws {
        var other = ""
        let env = try Env { other = try $0.create(text: "Other").id }
        var shown: [LinkPanelModel] = []
        env.state.links.presentLinkPanel = { panel, _ in shown.append(panel) }
        _ = env.editor.handle(.editLinkRequest(EditLinkRequest(
            noteId: env.sourceId, requestId: "r3", from: 0, to: 3, title: "see", url: "", editing: false, caretRect: CaretRect(x: 0, y: 0, width: 1, height: 15)
        )))
        env.model.selectNotes([other])
        env.state.showFocusedNote()
        let panel = try #require(shown.first)
        panel.url = "https://x.y"
        panel.submit()
        #expect(!env.page.delivered.contains { if case .applyCommand = $0 { true } else { false } })
    }

    @Test func readOnlyNotesGetNoLinkPanel() throws {
        let env = try Env()
        try env.store.trash([env.sourceId])
        _ = env.editor.handle(.ready(version: EditorBridge.version)) // reloads the note, now read-only
        #expect(!env.editor.status.isEditable)
        var shown = 0
        env.state.links.presentLinkPanel = { _, _ in shown += 1 }
        _ = env.editor.handle(.editLinkRequest(EditLinkRequest(
            noteId: env.sourceId, requestId: "r4", from: 0, to: 0, title: "", url: "", editing: false, caretRect: CaretRect(x: 0, y: 0, width: 1, height: 15)
        )))
        #expect(shown == 0)
    }

    /// Minor 8: a heading scroll asked for while the page boots arrives right after its loadNote.
    @Test func aHeadingScrollWaitsForTheEditorToBeReady() throws {
        let env = try Env()
        let id = try env.store.create(text: "# A\n## B").id
        let page = FakeEditorPage()
        let editor = EditorBridgeController(environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try editor.open(noteId: id)
        editor.scrollToHeading(1)
        #expect(page.delivered.isEmpty)
        _ = editor.handle(.ready(version: EditorBridge.version))
        guard page.delivered.count >= 2, case .loadNote(id, _, _, _, _, _, _) = page.delivered[0] else {
            Issue.record("expected loadNote first: \(page.delivered)")
            return
        }
        #expect(page.delivered[1] == .scrollToHeading(noteId: id, index: 1))

        // A scroll queued for a note the editor left is dropped.
        let latePage = FakeEditorPage()
        let late = EditorBridgeController(environment: env.environment, page: latePage, openExternally: { _ in }, checksumInterval: nil)
        try late.open(noteId: id)
        late.scrollToHeading(1)
        try late.open(noteId: env.sourceId)
        _ = late.handle(.ready(version: EditorBridge.version))
        #expect(!latePage.delivered.contains { if case .scrollToHeading = $0 { true } else { false } })
    }

    /// Minor 1: an older popover closing (after a newer ⌘K) does not cancel the current panel.
    @Test func onlyTheCurrentPopoverClosingCancelsThePanel() {
        let panel = LinkPanel()
        var results: [LinkPanelModel.Result] = []
        let model = LinkPanelModel(title: "t", url: "", editing: false) { results.append($0) }
        let current = NSPopover()
        panel.track(model, popover: current)
        panel.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: NSPopover()))
        #expect(results.isEmpty)
        panel.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: current))
        #expect(results == [.cancel])
    }

    @Test func thePanelIsAnchoredAtTheCaretInViewCoordinates() {
        let caret = CaretRect(x: 100, y: 40, width: 1, height: 18)
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(LinkPanel.anchorRect(caret, bounds: bounds, isFlipped: true, zoom: 1) == NSRect(x: 100, y: 40, width: 1, height: 18))
        #expect(LinkPanel.anchorRect(caret, bounds: bounds, isFlipped: false, zoom: 1) == NSRect(x: 100, y: 542, width: 1, height: 18))
        #expect(LinkPanel.anchorRect(caret, bounds: bounds, isFlipped: true, zoom: 2) == NSRect(x: 200, y: 80, width: 2, height: 36))
        // Off-screen carets are clamped into the view.
        let far = CaretRect(x: 5000, y: -50, width: 0, height: 18)
        let clamped = LinkPanel.anchorRect(far, bounds: bounds, isFlipped: true, zoom: 1)
        #expect(bounds.contains(NSPoint(x: clamped.minX, y: clamped.minY)))
        #expect(clamped.width >= 1)
    }

    // MARK: - Note windows and new windows (M4 Task 9)

    private func fakeEditor(_ env: Env, ready: Bool = true) -> (EditorBridgeController, FakeEditorPage) {
        let page = FakeEditorPage()
        let editor = EditorBridgeController(environment: env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        if ready { _ = editor.handle(.ready(version: EditorBridge.version)) }
        return (editor, page)
    }

    private func applyCommands(_ page: FakeEditorPage) -> [HostToEditorMessage] {
        page.delivered.filter { if case .applyCommand = $0 { true } else { false } }
    }

    /// M1: ⌘-click and ⌘K work in a note window: a wiki link navigates in that window (its history),
    /// the panel's answer reaches that window's editor.
    @Test func noteWindowsOpenLinksAndShowTheLinkPanel() throws {
        var other = ""
        let env = try Env { other = try $0.create(text: "# Other\n## Part").id }
        let (editor, page) = fakeEditor(env)
        let window = NoteWindowState(environment: env.environment, noteId: env.sourceId, editor: editor)
        _ = editor.handle(.openLink(OpenLinkRequest(noteId: env.sourceId, kind: .wiki, target: "other", heading: "part", newWindow: false)))
        #expect(window.noteId == other)
        #expect(window.canGoBack)
        #expect(page.delivered.contains(.scrollToHeading(noteId: other, index: 1)))
        // The main window is untouched.
        #expect(env.model.focusedNoteID == env.sourceId)

        var shown: [LinkPanelModel] = []
        window.links.presentLinkPanel = { panel, _ in shown.append(panel) }
        _ = editor.handle(.editLinkRequest(EditLinkRequest(
            noteId: other, requestId: "w1", from: 2, to: 7, title: "Other", url: "", editing: false,
            caretRect: CaretRect(x: 0, y: 0, width: 1, height: 15)
        )))
        let panel = try #require(shown.first)
        panel.url = "https://example.com"
        panel.submit()
        #expect(applyCommands(page) == [.applyCommand(name: .setLink, args: [
            "requestId": .string("w1"), "title": .string("Other"), "url": .string("https://example.com"),
        ])])
        #expect(applyCommands(env.page).isEmpty)
        window.close()
    }

    /// M2: ⌥⌘-click / ⌥⇧⌘K open a real note window at the heading (scrolled once its editor is
    /// ready); a tag link in a note window selects the tag in the main window.
    /// Final fix wave (T11 gap): a tag link in a note window with no main window open opens one,
    /// which selects the tag; a note window never tags a note its link creates.
    @Test func aTagLinkWithoutAMainWindowOpensOneOnTheTag() throws {
        let env = try Env(source: "see [[Missing]] #Work")
        let app = AppModel(environment: env.environment, defaults: UserDefaults(suiteName: env.suiteName)!)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        env.state.close()
        let (noteEditor, _) = fakeEditor(env)
        let window = app.makeNoteWindow(noteId: env.sourceId, editor: noteEditor)
        defer { window.close() }
        _ = noteEditor.handle(.openLink(OpenLinkRequest(noteId: env.sourceId, kind: .tag, target: "work", heading: nil, newWindow: false)))
        #expect(requests == [.main])
        let main = app.makeMainWindow(editor: fakeEditor(env).0)
        defer { main.close() }
        #expect(main.model.scope == .tag("Work"))
        // Only once: the next main window starts as it would.
        let second = app.makeMainWindow(editor: fakeEditor(env).0)
        #expect(second.model.scope == .notes)
        second.close()

        _ = noteEditor.handle(.openLink(OpenLinkRequest(noteId: env.sourceId, kind: .wiki, target: "Missing", heading: nil, newWindow: false)))
        #expect(try env.store.note(id: window.noteId)?.text == "# Missing")
    }

    @Test func newWindowLinksOpenANoteWindowAtTheHeading() throws {
        var other = "", third = ""
        let env = try Env(source: "see [[Other]] #work") {
            other = try $0.create(text: "# Other\n## A\n## B").id
            third = try $0.create(text: "Third").id
        }
        let app = AppModel(environment: env.environment, defaults: UserDefaults(suiteName: env.suiteName)!)
        var requests: [WindowRequest] = []
        app.openWindowRequest = { requests.append($0) }
        let (mainEditor, _) = fakeEditor(env)
        let main = app.makeMainWindow(editor: mainEditor)
        main.model.selectNotes([env.sourceId])
        main.showFocusedNote()

        _ = mainEditor.handle(.openLink(OpenLinkRequest(noteId: env.sourceId, kind: .wiki, target: "Other", heading: "B", newWindow: true)))
        #expect(requests == [.note(id: other)])
        #expect(main.model.focusedNoteID == env.sourceId)

        // The window SwiftUI opens for it: its editor boots, then gets the note and the heading.
        let (noteEditor, notePage) = fakeEditor(env, ready: false)
        let window = app.makeNoteWindow(noteId: other, editor: noteEditor)
        #expect(notePage.delivered.isEmpty)
        _ = noteEditor.handle(.ready(version: EditorBridge.version))
        // The source note's tag makes the page get its TagCons first (before any note).
        guard case .tagIcons? = notePage.delivered.first else {
            Issue.record("expected tagIcons first: \(notePage.delivered)")
            return
        }
        let delivered = Array(notePage.delivered.dropFirst())
        guard delivered.count >= 2, case .loadNote(other, _, _, _, _, _, _) = delivered[0] else {
            Issue.record("expected loadNote next: \(notePage.delivered)")
            return
        }
        #expect(delivered[1] == .scrollToHeading(noteId: other, index: 2))

        // From the note window: another new window, and a tag selected in the main window.
        _ = noteEditor.handle(.openLink(OpenLinkRequest(noteId: other, kind: .wiki, target: "Third", heading: nil, newWindow: true)))
        #expect(requests.last == .note(id: third))
        _ = noteEditor.handle(.openLink(OpenLinkRequest(noteId: other, kind: .tag, target: "WORK", heading: nil, newWindow: false)))
        #expect(main.model.scope == .tag("work"))
        window.close()
    }
}
