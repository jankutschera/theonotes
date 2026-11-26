// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M4 Task 4: Quick Open (⌘O) — the panel's model, keys, routing from main and note windows,
/// placement, focus return and the menu item. The panel's look is a GUI checklist item.
@MainActor
@Suite struct QuickOpenPanelTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesQuickOpen-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        let app: AppModel
        var requests: [WindowRequest] = []

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesQuickOpen-\(UUID().uuidString)", isDirectory: true)
            defaults = UserDefaults(suiteName: suiteName)!
            environment = try AppEnvironment(paths: AppPaths(root: root))
            app = AppModel(environment: environment, defaults: defaults)
            app.clipboardText = { nil }
            app.openWindowRequest = { [unowned self] in self.requests.append($0) }
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        var store: NoteStore { environment.store }

        func editor() -> (EditorBridgeController, FakeEditorPage) {
            let page = FakeEditorPage()
            let controller = EditorBridgeController(
                environment: environment, page: page, openExternally: { _ in }, checksumInterval: nil
            )
            _ = controller.handle(.ready(version: EditorBridge.version))
            return (controller, page)
        }

        func mainWindow() -> MainWindowState {
            app.makeMainWindow(editor: editor().0)
        }

        func model(_ query: String = "") throws -> QuickOpenModel {
            let model = try QuickOpenModel.load(environment: environment)
            model.query = query
            return model
        }
    }

    private func result(_ model: QuickOpenModel, _ title: String) throws -> QuickOpenResult {
        try #require(model.results.first { $0.title == title }, "no result \(title) in \(model.results.map(\.title))")
    }

    // MARK: - Model

    @Test func typingFiltersAndResetsTheSelection() throws {
        let env = try Env()
        _ = try env.store.create(text: "Meeting notes")
        _ = try env.store.create(text: "Groceries")
        let model = try env.model()
        #expect(model.results.count == 2)
        model.handle(.down)
        #expect(model.selectedIndex == 1)
        model.query = "meet"
        #expect(model.results.map(\.title) == ["Meeting notes"])
        #expect(model.selectedIndex == 0)
        model.query = "zzz"
        #expect(model.results.isEmpty)
        #expect(model.selected == nil)
    }

    @Test func arrowsMoveWithinTheResults() throws {
        let env = try Env()
        for title in ["One", "Two", "Three"] { _ = try env.store.create(text: title) }
        let model = try env.model()
        model.handle(.up)
        #expect(model.selectedIndex == 0)
        model.handle(.down); model.handle(.down); model.handle(.down)
        #expect(model.selectedIndex == 2)
        model.handle(.up)
        #expect(model.selectedIndex == 1)
    }

    @Test func returnChoosesTheSelectionAndCommandReturnInANewWindow() throws {
        let env = try Env()
        let note = try env.store.create(text: "Only")
        let model = try env.model()
        var chosen: [(QuickOpenTarget, Bool)] = []
        var cancelled = 0
        model.onChoose = { chosen.append(($0.target, $1)) }
        model.onCancel = { cancelled += 1 }
        model.handle(.open)
        model.handle(.openInNewWindow)
        model.handle(.cancel)
        #expect(chosen.map(\.0) == [.note(id: note.id), .note(id: note.id)])
        #expect(chosen.map(\.1) == [false, true])
        #expect(cancelled == 1)
        // Nothing to open: Return does nothing.
        model.query = "nothing like it"
        model.handle(.open)
        #expect(chosen.count == 2)
    }

    @Test func loadingCommitsOpenEditsFirst() throws {
        let env = try Env()
        let id = try env.store.create(text: "Old title").id
        let session = try env.environment.session(for: id)
        _ = session.apply(
            txId: "t1", baseRevision: 0, changeSet: ChangeSet(sections: [.replace(deleteLength: 9, insert: "New title")]),
            origin: nil)
        #expect(try env.model("new").results.map(\.title) == ["New title"])
    }

    @Test func keysFromEvents() throws {
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> QuickOpenModel.Key? {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return QuickOpenModel.key(for: event)
        }
        #expect(key(125, "\u{F701}") == .down)
        #expect(key(126, "\u{F700}") == .up)
        #expect(key(36, "\r") == .open)
        #expect(key(76, "\u{3}") == .open)
        #expect(key(36, "\r", .command) == .openInNewWindow)
        #expect(key(53, "\u{1B}") == .cancel)
        #expect(key(0, "a") == nil)
        #expect(key(36, "\r", .shift) == nil)
    }

    @Test func voiceOverLabels() {
        func label(_ kind: QuickOpenResult.Kind, _ title: String, detail: String? = nil) -> String {
            QuickOpenModel.accessibilityLabel(
                for: QuickOpenResult(target: .note(id: "x"), kind: kind, title: title, detail: detail, score: 0))
        }
        #expect(label(.note, "Meeting notes") == "Meeting notes, note")
        #expect(label(.note, "") == "Untitled, note")
        #expect(label(.note, "Budget", detail: "Archive") == "Budget, note in Archive")
        #expect(label(.tag, "work/projects") == "work/projects, tag")
        #expect(label(.section, "Today") == "Today, sidebar section")
        #expect(label(.search, "Images", detail: "Search “@images”") == "Images, Search “@images”")
        #expect(label(.template, "Weekly review") == "Weekly review, template")
    }

    // MARK: - Routing from a main window

    @Test func aNoteOpensInTheMainWindow() throws {
        let env = try Env()
        let target = try env.store.create(text: "Target")
        _ = try env.store.create(text: "Other")
        let main = env.mainWindow()
        let model = try env.model("target")
        env.app.performQuickOpen(try result(model, "Target"), newWindow: false, from: .main(main))
        #expect(main.model.focusedNoteID == target.id)
        #expect(main.editor.session?.noteId == target.id)
        #expect(env.requests.isEmpty)
    }

    @Test func anArchivedNoteRevealsTheArchive() throws {
        let env = try Env()
        let archived = try env.store.create(text: "Filed away")
        try env.store.archive([archived.id])
        let main = env.mainWindow()
        let model = try env.model("filed")
        env.app.performQuickOpen(try result(model, "Filed away"), newWindow: false, from: .main(main))
        #expect(main.model.scope == .archive)
        #expect(main.model.focusedNoteID == archived.id)
    }

    @Test func commandReturnOpensANoteWindow() throws {
        let env = try Env()
        let target = try env.store.create(text: "Target")
        let main = env.mainWindow()
        let shown = main.model.focusedNoteID
        env.app.performQuickOpen(try result(try env.model("target"), "Target"), newWindow: true, from: .main(main))
        #expect(env.requests == [.note(id: target.id)])
        #expect(main.model.focusedNoteID == shown)
    }

    @Test func tagsAndSectionsSelectTheSidebarScope() throws {
        let env = try Env()
        _ = try env.store.create(text: "Plan\n\n#work/projects")
        let main = env.mainWindow()
        env.app.performQuickOpen(try result(try env.model("#proj"), "work/projects"), newWindow: false, from: .main(main))
        #expect(main.model.scope == .tag("work/projects"))
        env.app.performQuickOpen(try result(try env.model("@today"), "Today"), newWindow: false, from: .main(main))
        #expect(main.model.scope == .today)
    }

    @Test func aSpecialSearchRunsInNotes() throws {
        let env = try Env()
        _ = try env.store.create(text: "Plan\n\n#work")
        let main = env.mainWindow()
        main.model.selectScope(.tag("work"))
        let before = main.searchFocusRequest
        env.app.performQuickOpen(try result(try env.model("@imag"), "Images"), newWindow: false, from: .main(main))
        #expect(main.model.scope == .notes)
        #expect(main.model.search.query == "@images")
        #expect(main.searchFocusRequest == before + 1)
    }

    @Test func aTemplateCreatesANoteAndOpensItAtTheCursor() throws {
        let env = try Env()
        let template = "Meeting\n\nAgenda: {{cursor}}\n\n#template #work"
        _ = try env.store.create(text: template)
        let expected = Templates.instantiate(templateText: template, context: TemplateContext())
        let (editor, page) = env.editor()
        let main = env.app.makeMainWindow(editor: editor)
        let model = try env.model("+meet")
        env.app.performQuickOpen(try result(model, "Meeting"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        let note = try #require(try env.store.note(id: id))
        #expect(note.text == expected.text)
        #expect(note.text.hasPrefix("Meeting\n\nAgenda: ") && !note.text.contains("#template"))
        #expect(main.editor.session?.noteId == id)
        let caret = try #require(expected.caretOffset)
        guard case .loadNote(id, _, _, _, let selection, _, _)? = page.loadNotes.last else {
            Issue.record("expected the new note loaded: \(page.loadNotes)")
            return
        }
        #expect(selection == SelectionRange(anchor: caret, head: caret))
        #expect(env.requests.isEmpty)
        // The template itself is unchanged and still a template.
        #expect(try env.model("+").results.map(\.title) == ["Meeting"])
    }

    // MARK: - Routing from a note window

    @Test func fromANoteWindowANoteOpensInThatWindow() throws {
        let env = try Env()
        let first = try env.store.create(text: "First")
        let second = try env.store.create(text: "Second")
        let window = env.app.makeNoteWindow(noteId: first.id, editor: env.editor().0)
        env.app.performQuickOpen(try result(try env.model("second"), "Second"), newWindow: false, from: .note(window))
        #expect(window.noteId == second.id)
        #expect(window.canGoBack)
        #expect(env.requests.isEmpty)
        window.close()
    }

    @Test func fromANoteWindowCommandReturnOpensAnotherNoteWindow() throws {
        let env = try Env()
        let first = try env.store.create(text: "First")
        let second = try env.store.create(text: "Second")
        let window = env.app.makeNoteWindow(noteId: first.id, editor: env.editor().0)
        env.app.performQuickOpen(try result(try env.model("second"), "Second"), newWindow: true, from: .note(window))
        #expect(env.requests == [.note(id: second.id)])
        #expect(window.noteId == first.id)
        window.close()
    }

    @Test func fromANoteWindowATagSelectsItInTheMainWindow() throws {
        let env = try Env()
        let note = try env.store.create(text: "Plan\n\n#work")
        let main = env.mainWindow()
        let window = env.app.makeNoteWindow(noteId: note.id, editor: env.editor().0)
        env.app.performQuickOpen(try result(try env.model("#work"), "work"), newWindow: false, from: .note(window))
        #expect(main.model.scope == .tag("work"))
        window.close()
    }

    @Test func aTemplateInANewWindowKeepsItsCaret() throws {
        let env = try Env()
        let template = "Daily\n\n- {{cursor}}\n\n#template"
        _ = try env.store.create(text: template)
        let expected = Templates.instantiate(templateText: template, context: TemplateContext())
        let caret = try #require(expected.caretOffset)
        let main = env.mainWindow()
        env.app.performQuickOpen(try result(try env.model("/template"), "Daily"), newWindow: true, from: .main(main))
        guard case .note(let id) = env.requests.last else {
            Issue.record("expected a note window request: \(env.requests)")
            return
        }
        let (editor, page) = env.editor()
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        #expect(page.loadNotes.last == .loadNote(
            noteId: id, text: expected.text, revision: 0, readOnly: false,
            selection: SelectionRange(anchor: caret, head: caret)))
        window.close()
    }

    // MARK: - Panel

    @Test func thePanelSitsCenteredInTheTopThirdOfTheWindow() {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let parent = NSRect(x: 200, y: 100, width: 1000, height: 600)
        let frame = QuickOpenPanel.frame(size: NSSize(width: 560, height: 360), over: parent, screen: screen)
        #expect(frame.midX == parent.midX)
        #expect(frame.maxY == parent.maxY - parent.height / 6)
        #expect(frame.maxY > parent.maxY - parent.height / 3)
        // Kept on screen.
        let low = QuickOpenPanel.frame(
            size: NSSize(width: 560, height: 360), over: NSRect(x: -400, y: 0, width: 500, height: 300), screen: screen)
        #expect(screen.contains(low))
        // Without a window: the screen's top third.
        let alone = QuickOpenPanel.frame(size: NSSize(width: 560, height: 360), over: nil, screen: screen)
        #expect(alone.midX == screen.midX)
        #expect(alone.maxY == screen.maxY - screen.height / 6)
    }

    @Test func closingThePanelReturnsKeyboardFocus() throws {
        let env = try Env()
        _ = try env.store.create(text: "Anything")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        let controller = QuickOpenController()
        controller.show(try env.model(), over: window)
        #expect(controller.isShown)
        #expect(controller.panel?.isVisible == true)
        // Whatever happened to the window's focus meanwhile, Esc gives it back to the field.
        window.makeFirstResponder(nil)
        _ = controller.panel?.handle(.cancel)
        #expect(!controller.isShown)
        #expect(controller.panel?.isVisible != true)
        #expect((window.firstResponder as? NSTextView)?.delegate === field)
        // A click elsewhere (the panel resigns key) leaves focus where the click put it.
        controller.show(try env.model(), over: window)
        window.makeFirstResponder(nil)
        controller.panel?.resignKey()
        #expect(!controller.isShown)
        #expect(window.firstResponder === window)
        window.close()
    }

    @Test func choosingClosesThePanelBeforeTheActionRuns() throws {
        let env = try Env()
        _ = try env.store.create(text: "Anything")
        let controller = QuickOpenController()
        let model = try env.model()
        var shownWhenChosen: Bool?
        model.onChoose = { _, _ in shownWhenChosen = controller.isShown }
        controller.show(model, over: nil)
        _ = controller.panel?.handle(.open)
        #expect(shownWhenChosen == false)
        #expect(!controller.isShown)
    }

    // MARK: - Fix round 1

    /// I2: a row click (the tap gesture calls `choose`) must not tear the hosting view down inside
    /// its own call stack; it goes on the next run-loop turn.
    @Test func aRowClickKeepsTheHostingViewUntilTheNextTurn() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Anything")
        let controller = QuickOpenController()
        let model = try env.model()
        var chosen: QuickOpenTarget?
        model.onChoose = { result, _ in chosen = result.target }
        controller.show(model, over: nil)
        let panel = try #require(controller.panel)
        let hosting = try #require(panel.contentView)
        model.choose(try #require(model.results.first), newWindow: false)
        #expect(chosen != nil)
        #expect(!controller.isShown)
        #expect(panel.contentView === hosting)
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.contentView == nil)
    }

    @Test func aPanelShownAgainKeepsItsNewContent() async throws {
        let env = try Env()
        let controller = QuickOpenController()
        controller.show(try env.model(), over: nil)
        _ = controller.panel?.handle(.cancel)
        controller.show(try env.model(), over: nil)
        let hosting = controller.panel?.contentView
        try await Task.sleep(for: .milliseconds(50))
        #expect(hosting != nil)
        #expect(controller.panel?.contentView === hosting)
        controller.dismiss(restoringFocus: false)
    }

    /// I1: the field has keyboard focus once SwiftUI has laid it out.
    @Test func theFieldTakesFocus() async throws {
        let env = try Env()
        let controller = QuickOpenController()
        controller.show(try env.model(), over: nil)
        let panel = try #require(controller.panel)
        // A bounded poll (up to 2 s), not a fixed turn: under load SwiftUI lays the field out later.
        let deadline = ContinuousClock.now + .seconds(2)
        while !QuickOpenController.fieldHasFocus(in: panel), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(QuickOpenController.fieldHasFocus(in: panel))
        controller.dismiss(restoringFocus: false)
    }

    @Test func isShownFollowsThePanelsVisibility() throws {
        let env = try Env()
        let controller = QuickOpenController()
        controller.show(try env.model(), over: nil)
        #expect(controller.isShown)
        // Hidden with the app (hidesOnDeactivate): not shown; ⌘O shows it afresh.
        controller.panel?.orderOut(nil)
        #expect(!controller.isShown)
        controller.show(try env.model(), over: nil)
        #expect(controller.isShown)
        controller.dismiss(restoringFocus: false)
    }

    @Test func theSnapshotLoadsOffTheMainThreadAndKeepsWhatWasTyped() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Target")
        _ = try env.store.create(text: "Other")
        let model = QuickOpenModel(index: nil)
        #expect(model.isLoading)
        model.query = "targ"
        #expect(model.results.isEmpty)
        model.handle(.open) // nothing to open yet
        model.install(try await QuickOpenModel.loadIndex(environment: env.environment))
        #expect(!model.isLoading)
        #expect(model.results.map(\.title) == ["Target"])
    }

    @Test func typingAnnouncesTheCountAndTopHit() throws {
        let env = try Env()
        _ = try env.store.create(text: "Meeting notes")
        _ = try env.store.create(text: "Groceries")
        let model = try env.model()
        var announced: [[QuickOpenResult]] = []
        model.onResultsChange = { announced.append($0) }
        model.query = "meet"
        model.query = "zzz"
        #expect(announced.map(QuickOpenModel.resultsAnnouncement) == ["1 result, Meeting notes, note", "No results"])
        model.query = ""
        #expect(QuickOpenModel.resultsAnnouncement(announced.last!) == "2 results, Groceries, note"
            || QuickOpenModel.resultsAnnouncement(announced.last!) == "2 results, Meeting notes, note")
    }

    @Test func arrowsWithoutResultsGoToTheField() throws {
        let env = try Env()
        let model = try env.model("nothing matches this")
        #expect(model.results.isEmpty)
        #expect(!model.handle(.down))
        #expect(!model.handle(.up))
        #expect(model.handle(.cancel))
    }

    /// A text view standing in for the field while an input method composes (or not).
    final class StubFieldEditor: NSTextView {
        var composing = true
        var keyDowns = 0
        override func hasMarkedText() -> Bool { composing }
        override func keyDown(with event: NSEvent) { keyDowns += 1 }
    }

    private func keyEvent(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeat isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: code)!
    }

    private func panelWithStub(composing: Bool) -> (QuickOpenPanel, StubFieldEditor, () -> [QuickOpenModel.Key]) {
        let panel = QuickOpenPanel()
        let stub = StubFieldEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        stub.composing = composing
        let content = NSView(frame: NSRect(origin: .zero, size: QuickOpenPanel.size))
        content.addSubview(stub)
        panel.contentView = content
        panel.makeFirstResponder(stub)
        var keys: [QuickOpenModel.Key] = []
        panel.onKey = { keys.append($0); return true }
        return (panel, stub, { keys })
    }

    @Test func whileComposingTheKeysBelongToTheInputMethod() {
        let (panel, stub, keys) = panelWithStub(composing: true)
        #expect(panel.isComposing)
        panel.sendEvent(keyEvent(36, "\r"))
        panel.sendEvent(keyEvent(125, "\u{F701}"))
        panel.sendEvent(keyEvent(53, "\u{1B}"))
        _ = panel.performKeyEquivalent(with: keyEvent(36, "\r", .command))
        panel.cancelOperation(nil)
        #expect(keys().isEmpty)
        #expect(stub.keyDowns == 3)
        panel.close()
    }

    @Test func withoutCompositionThePanelTakesTheKeys() {
        let (panel, stub, keys) = panelWithStub(composing: false)
        #expect(!panel.isComposing)
        panel.sendEvent(keyEvent(36, "\r"))
        panel.sendEvent(keyEvent(125, "\u{F701}"))
        panel.cancelOperation(nil)
        #expect(keys() == [.open, .down, .cancel])
        #expect(stub.keyDowns == 0)
        panel.close()
    }

    @Test func aHeldReturnIsSwallowed() {
        let (panel, stub, keys) = panelWithStub(composing: false)
        #expect(QuickOpenModel.key(for: keyEvent(36, "\r", repeat: true)) == nil)
        panel.sendEvent(keyEvent(36, "\r", repeat: true))
        panel.sendEvent(keyEvent(76, "\u{3}", repeat: true))
        #expect(keys().isEmpty)
        #expect(stub.keyDowns == 0)
        panel.close()
    }

    @Test func unhandledArrowsReachTheField() {
        let (panel, stub, _) = panelWithStub(composing: false)
        panel.onKey = { _ in false }
        panel.sendEvent(keyEvent(125, "\u{F701}"))
        #expect(stub.keyDowns == 1)
        panel.close()
    }

    @Test func anUnlistedSearchRunsInTheMainWindow() throws {
        let env = try Env()
        let main = env.mainWindow()
        let model = try env.model("@last7days")
        let row = try #require(model.results.first)
        #expect(row.title == "Search for “@last7days”")
        env.app.performQuickOpen(row, newWindow: false, from: .main(main))
        #expect(main.model.scope == .notes)
        #expect(main.model.search.query == "@last7days")
    }

    // MARK: - Workspaces (M4 Task 8)

    @Test func quickOpenListsTheSourceWindowsWorkspace() async throws {
        let env = try Env()
        let inside = try env.store.create(text: "Inside\n\n#work")
        _ = try env.store.create(text: "Outside\n\n#home")
        let template = try env.store.create(text: "Meeting\n\n#template")
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        #expect(env.app.quickOpenWorkspace(for: .main(main)) == Workspace(path: "work"))
        let index = try await QuickOpenModel.loadIndex(
            environment: env.environment, workspace: env.app.quickOpenWorkspace(for: .main(main)))
        #expect(index.results(query: "").map(\.target) == [.note(id: inside.id)])
        #expect(index.results(query: "#").map(\.title) == ["work"])
        #expect(index.results(query: "+").map(\.target) == [.template(id: template.id)])

        // A note window: the frontmost main window's workspace (none without one).
        let window = env.app.makeNoteWindow(noteId: inside.id, editor: env.editor().0)
        #expect(env.app.quickOpenWorkspace(for: .note(window)) == Workspace(path: "work"))
        main.model.dismissWorkspace()
        #expect(env.app.quickOpenWorkspace(for: .note(window)) == nil)
        #expect(env.app.quickOpenWorkspace(for: nil) == nil)
        window.close()
    }

    // MARK: - Menu

    @Test func quickOpenIsInTheViewMenuWithCommandO() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let view = try #require(mainMenu.items.first { $0.title == "View" }?.submenu)
        let item = try #require(view.items.first { $0.title == "Quick Open…" })
        #expect(item.keyEquivalent == "o")
        #expect(item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == .command)
        let sharing = mainMenu.items.compactMap(\.submenu).flatMap(items).filter {
            $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == .command
        }
        #expect(sharing.map(\.title) == ["Quick Open…"])
    }

    /// The selected row draws `OnAccentColor` (white) on `AccentColor` (a fill-safe red), which meets AA in
    /// light and dark. The high-contrast variants cannot be resolved here (`NSAppearance(named:)` returns plain
    /// Aqua for them); all four variants are pinned by `ThemeTests.testAccentColorCarriesWhiteTextOnItsFill`.
    /// This checks `QuickOpenColors`, not the SwiftUI row: every text run and icon of the selected `QuickOpenRow`
    /// must use `QuickOpenColors.selectedText` on `QuickOpenColors.selectedFill`.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func selectedRowTextMeetsAAOnTheAccentFill(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        var pair: (NSColor, NSColor)?
        appearance.performAsCurrentDrawingAppearance {
            if let fill = QuickOpenColors.selectedFill.usingColorSpace(.sRGB),
                let text = QuickOpenColors.selectedText.usingColorSpace(.sRGB)
            {
                pair = (fill, text)
            }
        }
        let (fill, text) = try #require(pair, "\(name.rawValue)")
        func luminance(_ c: NSColor) -> Double {
            func lin(_ v: CGFloat) -> Double {
                let s = Double(v)
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (a, b) = (luminance(fill), luminance(text))
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        #expect(ratio >= 4.5, "\(name.rawValue): \(ratio)")
        // White text on a dark red fill in both appearances (not dark text on a light salmon one).
        #expect(luminance(text) > luminance(fill), "\(name.rawValue)")
    }
}
