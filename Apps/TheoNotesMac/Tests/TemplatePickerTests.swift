// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M4 Task 10 (app part): File ▸ New Note from Template… (⇧⌘N), the `{{title}}` prompt in
/// `AppModel.createNoteFromTemplate`, "Start new notes with: Template…" and workspaces. The
/// picker's and the prompt's look are GUI checklist items.
@MainActor
@Suite struct TemplatePickerTests {
    @MainActor
    final class Env {
        let root: URL
        let suiteName = "TheoNotesTemplates-\(UUID().uuidString)"
        let defaults: UserDefaults
        let environment: AppEnvironment
        let app: AppModel
        var requests: [WindowRequest] = []
        /// The template titles the prompt was shown for; `answer` is what the user typed (nil: Cancel).
        var asked: [String] = []
        var answer: String? = "Standup"
        var beeps = 0

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesTemplates-\(UUID().uuidString)", isDirectory: true)
            defaults = UserDefaults(suiteName: suiteName)!
            environment = try AppEnvironment(paths: AppPaths(root: root))
            app = AppModel(environment: environment, defaults: defaults)
            app.clipboardText = { nil }
            app.openWindowRequest = { [unowned self] in self.requests.append($0) }
            app.beep = { [unowned self] in self.beeps += 1 }
            app.askForTemplateTitle = { [unowned self] title in
                self.asked.append(title)
                return self.answer
            }
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

        /// The Quick Open row of template `title` (the `+` mode).
        func quickOpenRow(_ title: String) throws -> QuickOpenResult {
            let model = try QuickOpenModel.load(environment: environment)
            model.query = "+"
            return try #require(model.results.first { $0.title == title }, "no template \(title)")
        }

        /// Every note's text, oldest first.
        func texts() throws -> [String] {
            try store.allNotes().map(\.text)
        }

        /// The template picker (⇧⌘N) shown from `source`, once its index has loaded.
        func showPicker(main: MainWindowState? = nil, noteWindow: NoteWindowState? = nil) async throws -> QuickOpenModel {
            app.showTemplatePicker(main: main, noteWindow: noteWindow)
            let model = try #require(app.templatePicker.model)
            let deadline = ContinuousClock.now + .seconds(5)
            while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
            return model
        }
    }

    private let start = Date(timeIntervalSince1970: 1_792_670_400)

    // MARK: - The title prompt (one place: createNoteFromTemplate)

    @Test func quickOpenAsksForTheTitleAndFillsItIn() throws {
        let env = try Env()
        _ = try env.store.create(text: "# {{title}}\n\n{{cursor}}\n\n#template\n", now: start)
        _ = try env.store.create(text: "Meeting\n\n# {{title}} {{date}}\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        env.app.performQuickOpen(try env.quickOpenRow("{{title}}"), newWindow: false, from: .main(main))
        #expect(env.asked == ["{{title}}"])
        let id = try #require(main.model.focusedNoteID)
        let text = try #require(try env.store.note(id: id)?.text)
        #expect(text.hasPrefix("# Standup\n"))
        #expect(!text.contains("{{title}}") && !text.contains("#template"))
    }

    @Test func cancellingThePromptCreatesNothing() throws {
        let env = try Env()
        _ = try env.store.create(text: "Meeting {{title}}\n#template", now: start)
        let main = env.mainWindow()
        let before = try env.texts()
        let focused = main.model.focusedNoteID
        env.answer = nil
        env.app.performQuickOpen(try env.quickOpenRow("Meeting {{title}}"), newWindow: false, from: .main(main))
        #expect(env.asked == ["Meeting {{title}}"])
        #expect(try env.texts() == before)
        #expect(main.model.focusedNoteID == focused)
        #expect(env.requests.isEmpty)
        // Also in a new window.
        env.app.performQuickOpen(try env.quickOpenRow("Meeting {{title}}"), newWindow: true, from: .main(main))
        #expect(try env.texts() == before)
        #expect(env.requests.isEmpty)
    }

    @Test func noPromptWithoutATitlePlaceholder() throws {
        let env = try Env()
        _ = try env.store.create(text: "Plain\n\n`{{title}}` in code is not a placeholder\n#template", now: start)
        let main = env.mainWindow()
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .main(main))
        #expect(env.asked.isEmpty)
        #expect(main.model.focusedNoteID != nil)
    }

    @Test func aTitleWithNewlinesStaysOnOneLine() throws {
        let env = try Env()
        _ = try env.store.create(text: "# {{title}}\n#template", now: start)
        env.answer = "One\nTwo"
        let created = env.app.createNoteFromTemplate(id: try env.store.allNotes().first!.id)
        guard case .created(let id, _) = created else { Issue.record("expected a note, got \(created)"); return }
        #expect(try env.store.note(id: id)?.text == "# One Two")
    }

    @Test func theOutcomeNamesWhatHappened() throws {
        let env = try Env()
        let template = try env.store.create(text: "T {{title}}\n#template", now: start)
        env.answer = nil
        #expect(env.app.createNoteFromTemplate(id: template.id) == .cancelled)
        #expect(env.app.createNoteFromTemplate(id: "missing") == .unavailable)
        try env.environment.database.pool.write {
            try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [template.id])
        }
        env.answer = "x"
        #expect(env.app.createNoteFromTemplate(id: template.id) == .unavailable)
        // Anything else going wrong is a failure, not a missing template.
        let plain = try env.store.create(text: "Plain\n#template", now: start)
        #expect(env.app.createNoteFromTemplate(id: plain.id, extraTags: [""]) == .failed)
    }

    // MARK: - Recent templates

    @Test func creatingFromATemplateRecordsItsUse() throws {
        let env = try Env()
        let template = try env.store.create(text: "Plain\n#template", now: start)
        #expect(env.app.templateRecents.all()[template.id] == nil)
        _ = env.app.createNoteFromTemplate(id: template.id, now: start.addingTimeInterval(500))
        #expect(env.app.templateRecents.all()[template.id] == start.addingTimeInterval(500))
        // A cancelled prompt is no use.
        let titled = try env.store.create(text: "{{title}}\n#template", now: start)
        env.answer = nil
        _ = env.app.createNoteFromTemplate(id: titled.id, now: start.addingTimeInterval(900))
        #expect(env.app.templateRecents.all()[titled.id] == nil)
    }

    @Test func recentsKeepTheNewestHundred() {
        let defaults = UserDefaults(suiteName: "TheoNotesRecents-\(UUID().uuidString)")!
        let recents = TemplateRecents(defaults: defaults)
        for i in 0..<130 { recents.markUsed("t\(i)", at: Date(timeIntervalSince1970: Double(i))) }
        let all = recents.all()
        #expect(all.count == TemplateRecents.limit)
        #expect(all["t129"] != nil && all["t30"] != nil && all["t29"] == nil)
    }

    // MARK: - The picker

    @Test func thePickerListsTemplatesRecentlyUsedFirst() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Alpha plan\n#template", now: start)
        _ = try env.store.create(text: "Beta plan\n#template/meeting", now: start.addingTimeInterval(10))
        _ = try env.store.create(text: "Gamma plan\n#template", now: start.addingTimeInterval(20))
        _ = try env.store.create(text: "Not a template", now: start.addingTimeInterval(30))
        let main = env.mainWindow()
        // Never used: the most recently modified first.
        var model = try await env.showPicker(main: main)
        #expect(model.results.map(\.title) == ["Gamma plan", "Beta plan", "Alpha plan"])
        model.handle(.cancel)

        let alpha = try #require(try env.store.allNotes().first { $0.title == "Alpha plan" })
        let beta = try #require(try env.store.allNotes().first { $0.title == "Beta plan" })
        _ = env.app.createNoteFromTemplate(id: alpha.id, now: start.addingTimeInterval(100))
        _ = env.app.createNoteFromTemplate(id: beta.id, now: start.addingTimeInterval(200))
        model = try await env.showPicker(main: main)
        #expect(model.results.map(\.title) == ["Beta plan", "Alpha plan", "Gamma plan"])
        model.handle(.cancel)
    }

    @Test func thePickerFiltersFuzzyLikeQuickOpen() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Weekly review\n#template", now: start)
        _ = try env.store.create(text: "Meeting notes\n#template", now: start.addingTimeInterval(1))
        _ = try env.store.create(text: "Weekly review of notes", now: start.addingTimeInterval(2))
        let model = try await env.showPicker(main: env.mainWindow())
        model.query = "wkrv"
        #expect(model.results.map(\.title) == ["Weekly review"])
        model.query = "notes"
        #expect(model.results.map(\.title) == ["Meeting notes"])
        model.query = ""
        #expect(model.results.count == 2)
        model.query = "zzz"
        #expect(model.results.isEmpty)
        model.handle(.cancel)
    }

    @Test func equalMatchesPreferTheRecentlyUsed() async throws {
        let env = try Env()
        let first = try env.store.create(text: "Daily one\n#template", now: start)
        _ = try env.store.create(text: "Daily two\n#template", now: start.addingTimeInterval(1))
        _ = env.app.createNoteFromTemplate(id: first.id, now: start.addingTimeInterval(50))
        let model = try await env.showPicker(main: env.mainWindow())
        model.query = "daily"
        #expect(model.results.map(\.title) == ["Daily one", "Daily two"])
        model.handle(.cancel)
    }

    @Test func returnInThePickerCreatesTheNoteThroughTheSameEntryPoint() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Meeting {{title}}\n\nNotes: {{cursor}}\n#template", now: start)
        let main = env.mainWindow()
        let model = try await env.showPicker(main: main)
        #expect(env.app.templatePicker.isShown)
        model.handle(.open)
        #expect(!env.app.templatePicker.isShown)
        #expect(env.asked == ["Meeting {{title}}"])
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Meeting Standup\n\nNotes: ")
        #expect(main.editor.session?.noteId == id)
    }

    @Test func cancellingThePromptFromThePickerCreatesNothing() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Meeting {{title}}\n#template", now: start)
        let main = env.mainWindow()
        let before = try env.texts()
        env.answer = nil
        let model = try await env.showPicker(main: main)
        model.handle(.open)
        #expect(env.asked.count == 1)
        #expect(try env.texts() == before)
    }

    @Test func escClosesThePickerWithoutCreating() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Plain\n#template", now: start)
        let main = env.mainWindow()
        let before = try env.texts()
        let model = try await env.showPicker(main: main)
        model.handle(.cancel)
        #expect(!env.app.templatePicker.isShown)
        #expect(try env.texts() == before)
    }

    @Test func fromANoteWindowTheNoteOpensInThatWindow() async throws {
        let env = try Env()
        let current = try env.store.create(text: "Current", now: start)
        _ = try env.store.create(text: "Plain\n\n{{cursor}}x\n#template", now: start.addingTimeInterval(1))
        let window = env.app.makeNoteWindow(noteId: current.id, editor: env.editor().0)
        let model = try await env.showPicker(noteWindow: window)
        model.handle(.open)
        #expect(window.noteId != current.id)
        #expect(try env.store.note(id: window.noteId)?.text == "Plain\n\nx")
        #expect(window.canGoBack)
        #expect(env.requests.isEmpty)
        window.close()
    }

    @Test func commandReturnOpensTheNoteInANewWindow() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Plain\n#template", now: start)
        let main = env.mainWindow()
        let focused = main.model.focusedNoteID
        let model = try await env.showPicker(main: main)
        model.handle(.openInNewWindow)
        guard case .note(let id)? = env.requests.last else { Issue.record("no window: \(env.requests)"); return }
        #expect(try env.store.note(id: id)?.text == "Plain")
        #expect(main.model.focusedNoteID == focused)
    }

    @Test func aTemplateTrashedWhilePickingCreatesNothing() async throws {
        let env = try Env()
        let template = try env.store.create(text: "Plain\n#template", now: start)
        let main = env.mainWindow()
        let model = try await env.showPicker(main: main)
        try env.store.deletePermanently([template.id])
        let before = try env.texts()
        model.handle(.open)
        #expect(try env.texts() == before)
    }

    @Test func anEmptyPickerSaysHowToMakeATemplate() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Just a note", now: start)
        let model = try await env.showPicker(main: env.mainWindow())
        #expect(model.results.isEmpty)
        #expect(model.emptyMessage.contains("#template"))
        model.handle(.cancel)
    }

    // MARK: - Workspaces

    @Test func aTemplateNoteInAWorkspaceGetsTheWorkspaceTag() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #work", now: start)
        _ = try env.store.create(text: "Plain\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        // Quick Open …
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .main(main))
        let viaQuickOpen = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: viaQuickOpen)?.text == "Plain\n#work")
        #expect(main.model.workspace == Workspace(path: "work"))
        // … and the picker.
        let model = try await env.showPicker(main: main)
        model.handle(.open)
        let viaPicker = try #require(main.model.focusedNoteID)
        #expect(viaPicker != viaQuickOpen)
        #expect(try env.store.note(id: viaPicker)?.text == "Plain\n#work")
        #expect(main.model.items.map(\.id).contains(viaPicker))
    }

    @Test func aTemplateTagInsideTheWorkspaceIsNotDoubled() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #work", now: start)
        _ = try env.store.create(text: "Plan\n#template #work/projects", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        env.app.performQuickOpen(try env.quickOpenRow("Plan"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Plan\n#work/projects")
    }

    @Test func theWorkspaceTagFollowsTheTagPosition() throws {
        let env = try Env()
        Settings(db: env.environment.database).tagPosition = .top
        _ = try env.store.create(text: "Seed #work", now: start)
        _ = try env.store.create(text: "Plan {{cursor}}\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        env.app.performQuickOpen(try env.quickOpenRow("Plan {{cursor}}"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Plan \n#work")
    }

    @Test func fromANoteWindowTheFrontmostMainWindowsWorkspaceApplies() throws {
        let env = try Env()
        let seed = try env.store.create(text: "Seed #work", now: start)
        _ = try env.store.create(text: "Plain\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        let window = env.app.makeNoteWindow(noteId: seed.id, editor: env.editor().0)
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .note(window))
        #expect(try env.store.note(id: window.noteId)?.text == "Plain\n#work")
        window.close()
    }

    @Test func outsideAWorkspaceNothingIsAdded() throws {
        let env = try Env()
        _ = try env.store.create(text: "Plain\n#template", now: start)
        let main = env.mainWindow()
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Plain")
    }

    // MARK: - Start new notes with: Template…

    private func startTemplate(_ env: Env, _ text: String = "Daily {{date}}\n\n- {{cursor}}\n#template") throws -> Note {
        let template = try env.store.create(text: text, now: start)
        env.app.settings.set(.startNoteTemplate, template.id)
        return template
    }

    @Test func commandNStartsFromTheChosenTemplate() throws {
        let env = try Env()
        let template = try startTemplate(env)
        let main = env.mainWindow()
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(id != template.id)
        let text = try #require(try env.store.note(id: id)?.text)
        #expect(text.hasPrefix("Daily 20") && text.hasSuffix("\n\n- "))
        #expect(!text.contains("#template"))
        #expect(main.editor.session?.noteId == id)
        #expect(env.app.settings.snapshot.startNoteTemplate == template.id)
    }

    @Test func commandNAsksForTheTitleAndCancelCreatesNothing() throws {
        let env = try Env()
        _ = try startTemplate(env, "# {{title}}\n#template")
        let main = env.mainWindow()
        let before = try env.texts()
        env.answer = nil
        main.newNote()
        #expect(env.asked.count == 1)
        #expect(try env.texts() == before)
        // Cancelling is not "the template is gone": the setting stays and no plain note follows.
        #expect(env.app.settings.snapshot.startNoteTemplate != "")
        env.answer = "Retro"
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "# Retro")
    }

    @Test func aDeletedTemplateFallsBackToAPlainNoteAndClearsTheSetting() throws {
        let env = try Env()
        let template = try startTemplate(env)
        let main = env.mainWindow()
        try env.store.deletePermanently([template.id])
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "")
        #expect(env.asked.isEmpty)
        #expect(env.app.settings.snapshot.startNoteTemplate == "")
    }

    @Test func aTrashedLockedOrUntaggedTemplateFallsBackToo() throws {
        for breakIt in ["trash", "lock", "archive", "untag"] {
            let env = try Env()
            let template = try startTemplate(env)
            let main = env.mainWindow()
            switch breakIt {
            case "trash": try env.store.trash([template.id])
            case "archive": try env.store.archive([template.id])
            case "untag": try env.store.removeTag("template", from: [template.id])
            default:
                try env.environment.database.pool.write {
                    try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [template.id])
                }
            }
            main.newNote()
            let id = try #require(main.model.focusedNoteID, "\(breakIt)")
            #expect(try env.store.note(id: id)?.text == "", "\(breakIt)")
            #expect(env.app.settings.snapshot.startNoteTemplate == "", "\(breakIt)")
        }
    }

    @Test func withoutTheSettingCommandNMakesAPlainNote() throws {
        let env = try Env()
        _ = try env.store.create(text: "Daily\n#template", now: start)
        let main = env.mainWindow()
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "")
    }

    @Test func commandNFromANoteWindowUsesTheFrontmostMainWindow() throws {
        let env = try Env()
        _ = try startTemplate(env, "From template\n#template")
        let main = env.mainWindow()
        env.app.newNoteInMainWindow()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "From template")
    }

    @Test func commandNInAWorkspaceTagsTheTemplateNote() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #work", now: start)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Daily\n#work")
        #expect(main.model.workspace == Workspace(path: "work"))
    }

    @Test func optionCommandNOpensTheTemplateNoteInANewWindow() throws {
        let env = try Env()
        _ = try startTemplate(env, "Daily {{cursor}}!\n#template")
        let main = env.mainWindow()
        env.app.newNoteInNewWindow(from: main)
        guard case .note(let id)? = env.requests.last else { Issue.record("no window: \(env.requests)"); return }
        #expect(try env.store.note(id: id)?.text == "Daily !")
        let (editor, page) = env.editor()
        let window = env.app.makeNoteWindow(noteId: id, editor: editor)
        #expect(page.loadNotes.last == .loadNote(
            noteId: id, text: "Daily !", revision: 0, readOnly: false, selection: SelectionRange(anchor: 6, head: 6)))
        window.close()
    }

    @Test func settingsListTemplatesAndOnlyUsableOnesCount() throws {
        let env = try Env()
        let template = try startTemplate(env)
        #expect(env.app.startTemplateId() == template.id)
        env.app.settings.set(.startNoteTemplate, "no-such-note")
        #expect(env.app.startTemplateId() == nil)
        #expect(env.app.settings.snapshot.startNoteTemplate == "")
        #expect(env.app.startTemplateId() == nil)
    }

    // MARK: - Fix round 1

    @Test func commandNKeepsTheSelectedTagAndTheSearchTags() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #projects", now: start)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.selectScope(.tag("projects"))
        main.model.search.query = "#projects meeting"
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Daily\n#projects")
        #expect(main.model.scope == .tag("projects"), "the note is listed there: no scope change")
        #expect(main.model.items.contains { $0.id == id })
        #expect(main.model.search.query == "", "a search the note may not match ends, as for a plain note")
        #expect(main.model.selectedNoteIDs == [id])
        #expect(main.editor.session?.noteId == id)
    }

    @Test func aTagOnlySearchStaysAndAddsItsTag() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #work #home", now: start)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.search.query = "#work #home"
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Daily\n#work #home")
        #expect(main.model.search.query == "#work #home")
    }

    @Test func aNoteNotListedInTheScopeMovesToNotes() throws {
        let env = try Env()
        let seed = try env.store.create(text: "Seed", now: start)
        try env.store.setPinned([seed.id], pinned: true)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.selectScope(.pinned)
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(main.model.scope == .notes)
        #expect(main.model.items.contains { $0.id == id })
    }

    @Test func commandNInAWorkspaceAndATagScopeAddsTheScopeTagOnly() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #work/projects", now: start)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.enterWorkspace("work")
        main.model.selectScope(.tag("work/projects"))
        main.newNote()
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Daily\n#work/projects")
        #expect(main.model.scope == .tag("work/projects"))
    }

    // MARK: - Final review I3: Quick Open and the picker tag like ⌘N

    @Test func quickOpenTemplateKeepsTheSelectedTagAndTheSearchTags() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #projects #meetings", now: start)
        _ = try env.store.create(text: "Plain\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.selectScope(.tag("projects"))
        main.model.search.query = "#meetings agenda"
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Plain\n#projects #meetings")
        #expect(main.model.scope == .tag("projects"), "the note is listed there: no jump to Notes")
        #expect(main.model.items.contains { $0.id == id })
        #expect(main.model.search.query == "", "a search the note may not match ends, as for ⌘N")
        #expect(main.model.selectedNoteIDs == [id])
        #expect(main.editor.session?.noteId == id)
    }

    @Test func thePickerKeepsTheSelectedTagAndATagOnlySearch() async throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #meetings #work", now: start)
        _ = try env.store.create(text: "Meeting\n\n- {{cursor}}\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.selectScope(.tag("meetings"))
        main.model.search.query = "#work"
        let model = try await env.showPicker(main: main)
        model.handle(.open)
        let id = try #require(main.model.focusedNoteID)
        #expect(try env.store.note(id: id)?.text == "Meeting\n\n- \n#meetings #work")
        #expect(main.model.scope == .tag("meetings"))
        #expect(main.model.search.query == "#work", "the note matches a tag-only search: it stays")
        #expect(main.editor.session?.noteId == id)
        #expect(main.editor.session?.noteId == main.model.focusedNoteID)
    }

    @Test func aTemplateNoteNotListedInTheScopeMovesToNotes() throws {
        let env = try Env()
        let seed = try env.store.create(text: "Seed", now: start)
        try env.store.setPinned([seed.id], pinned: true)
        _ = try env.store.create(text: "Plain\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.selectScope(.pinned)
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: false, from: .main(main))
        let id = try #require(main.model.focusedNoteID)
        #expect(main.model.scope == .notes)
        #expect(main.model.items.contains { $0.id == id })
    }

    @Test func commandReturnFromATagScopeTagsTheNewWindowsNote() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #projects", now: start)
        _ = try env.store.create(text: "Plain\n#template", now: start.addingTimeInterval(1))
        let main = env.mainWindow()
        main.model.selectScope(.tag("projects"))
        let focused = main.model.focusedNoteID
        env.app.performQuickOpen(try env.quickOpenRow("Plain"), newWindow: true, from: .main(main))
        guard case .note(let id)? = env.requests.last else { Issue.record("no window: \(env.requests)"); return }
        #expect(try env.store.note(id: id)?.text == "Plain\n#projects")
        #expect(main.model.focusedNoteID == focused)
    }

    @Test func optionCommandNKeepsTheSelectedTag() throws {
        let env = try Env()
        _ = try env.store.create(text: "Seed #projects", now: start)
        _ = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        main.model.selectScope(.tag("projects"))
        env.app.newNoteInNewWindow(from: main)
        guard case .note(let id)? = env.requests.last else { Issue.record("no window: \(env.requests)"); return }
        #expect(try env.store.note(id: id)?.text == "Daily\n#projects")
    }

    @Test func aFailureThatIsNotAMissingTemplateKeepsTheSetting() throws {
        let env = try Env()
        let template = try startTemplate(env, "Daily\n#template")
        let main = env.mainWindow()
        // An unusable workspace tag makes creating fail; the template is fine.
        main.model.restoreWorkspace("", scope: .notes)
        let before = try env.texts()
        // R35: the plain path runs instead (here it fails the same way and shows the banner).
        main.newNote()
        #expect(try env.texts() == before)
        #expect(main.model.banner == .commandFailed(action: "new note"))
        #expect(env.app.settings.snapshot.startNoteTemplate == template.id)
        env.app.newNoteInNewWindow(from: main)
        #expect(env.requests.isEmpty)
        #expect(env.beeps == 0)
        #expect(env.app.settings.snapshot.startNoteTemplate == template.id)
    }

    @Test func aMissingTemplateStillClearsTheSettingWithoutABeep() throws {
        let env = try Env()
        let template = try startTemplate(env)
        let main = env.mainWindow()
        try env.store.deletePermanently([template.id])
        main.newNote()
        #expect(env.app.settings.snapshot.startNoteTemplate == "")
        #expect(env.beeps == 0)
    }

    @Test func theTemplateTextIsReadOnceAroundThePrompt() throws {
        let env = try Env()
        let template = try env.store.create(text: "Original {{title}}\n#template", now: start)
        env.app.askForTemplateTitle = { [unowned env] _ in
            _ = try? env.store.updateText(
                id: template.id, text: "Changed\n#template", expectedRevision: template.revision)
            return "Standup"
        }
        guard case .created(let id, _) = env.app.createNoteFromTemplate(id: template.id) else {
            Issue.record("expected a note"); return
        }
        #expect(try env.store.note(id: id)?.text == "Original Standup")
    }

    @Test func aFailedPickWhileChoosingBeepsAndACancelDoesNot() async throws {
        let env = try Env()
        let template = try env.store.create(text: "Plain {{title}}\n#template", now: start)
        let main = env.mainWindow()
        env.answer = nil
        let cancelled = try await env.showPicker(main: main)
        cancelled.handle(.open)
        #expect(env.beeps == 0)
        let model = try await env.showPicker(main: main)
        try env.store.deletePermanently([template.id])
        model.handle(.open)
        #expect(env.beeps == 1)
        // Quick Open too.
        let other = try env.store.create(text: "Other\n#template", now: start)
        let row = try env.quickOpenRow("Other")
        try env.store.deletePermanently([other.id])
        env.app.performQuickOpen(row, newWindow: false, from: .main(main))
        #expect(env.beeps == 2)
    }

    @Test func theTitleIsTrimmedAndBlankIsNoTitle() throws {
        #expect(AppModel.templateTitle(from: "  Standup \n") == "Standup")
        #expect(AppModel.templateTitle(from: " \t\n ") == nil)
        #expect(AppModel.templateTitle(from: "") == nil)
        let env = try Env()
        let template = try env.store.create(text: "# {{title}}\n#template", now: start)
        env.answer = "  Retro  "
        guard case .created(let id, _) = env.app.createNoteFromTemplate(id: template.id) else {
            Issue.record("expected a note"); return
        }
        #expect(try env.store.note(id: id)?.text == "# Retro")
        let before = try env.texts()
        env.answer = "   "
        #expect(env.app.createNoteFromTemplate(id: template.id) == .cancelled)
        #expect(try env.texts() == before)
    }

    @Test func settingsLabelsTellDuplicateTitlesApart() {
        let a = TemplateInfo(id: "a", title: "Meeting", tagPath: "template", modifiedAt: start)
        let b = TemplateInfo(id: "b", title: "Meeting", tagPath: "template/work", modifiedAt: start)
        let c = TemplateInfo(id: "c", title: "", tagPath: "template", modifiedAt: start)
        let d = TemplateInfo(id: "d", title: "Daily", tagPath: "template", modifiedAt: start)
        let all = [a, b, c, d]
        #expect(all.map { TemplateChoice.label(for: $0, among: all) }
            == ["Meeting (#template)", "Meeting (#template/work)", "Untitled", "Daily"])
    }

    // MARK: - Menu

    @Test func newNoteFromTemplateIsInTheFileMenuWithShiftCommandN() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        /// AppKit writes ⇧ + letter as the uppercase key equivalent without the shift flag.
        func shortcut(_ item: NSMenuItem) -> (String, NSEvent.ModifierFlags) {
            let flags = item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
            let key = item.keyEquivalent
            return key.count == 1 && key != key.lowercased() ? (key.lowercased(), flags.union(.shift)) : (key, flags)
        }
        let file = try #require(mainMenu.items.first { $0.title == "File" }?.submenu)
        let item = try #require(file.items.first { $0.title == "New Note from Template…" })
        let (key, flags) = shortcut(item)
        #expect(key == "n")
        #expect(flags == [.command, .shift])
        // Nothing else uses ⇧⌘N.
        let sharing = mainMenu.items.compactMap(\.submenu).flatMap(items).filter {
            let (k, f) = shortcut($0)
            return k == "n" && f == [.command, .shift]
        }
        #expect(sharing.map(\.title) == ["New Note from Template…"])
        // The existing New Note shortcuts are untouched.
        let plain = try #require(file.items.first { $0.title == "New Note" })
        #expect(shortcut(plain) == ("n", [.command]))
        let newWindow = try #require(file.items.first { $0.title == "New Note in New Window" })
        #expect(shortcut(newWindow) == ("n", [.command, .option]))
    }
}
