// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Combine
import Observation
import SwiftUI

/// A window the app asks SwiftUI to open.
enum WindowRequest: Hashable {
    case main
    case note(id: String)
}

/// What the window commands show for the focused window: Go Back / Go Forward (⌘[ / ⌘]), in a
/// note window Float on Top (nil in main windows), in a main window Dismiss Workspace (⇧⌘0).
struct WindowCommandState: Equatable {
    var canGoBack = false
    var canGoForward = false
    var isFloating: Bool?
    var isInWorkspace = false
}

/// App-wide state shared by all windows: the environment (store, sessions), settings, and the
/// routing between main windows (each with its own `MainWindowState`) and note windows.
@MainActor
@Observable
final class AppModel {
    static let mainWindowID = "main"
    static let noteWindowID = "note"

    let environment: AppEnvironment
    let settings: SettingsModel

    /// The voice note being made, if any, and the panel that shows it (spec A2).
    @ObservationIgnored let voice: VoiceCaptureModel
    @ObservationIgnored let voicePanel: VoicePanelController
    @ObservationIgnored private var voiceBusyObservation: AnyCancellable?
    /// A voice note is being set up or recorded (mirrors `voice.isBusy` for the menus).
    private(set) var isMakingVoiceNote = false

    /// Opens a SwiftUI window; installed by the windows' views from `@Environment(\.openWindow)`.
    /// Requests made before it is installed (the automation socket starts before the first window
    /// exists) wait in `queuedWindowRequests` and run when it is.
    @ObservationIgnored var openWindowRequest: ((WindowRequest) -> Void)? {
        didSet { drainWindowRequests() }
    }
    @ObservationIgnored private var queuedWindowRequests: [WindowRequest] = []
    /// The lock generation each note-window request was made under, per note, until a host claims one.
    @ObservationIgnored private var noteRequestGenerations: [String: [Int]] = [:]
    /// The Quick Open panel (⌘O, AppModel+QuickOpen.swift).
    @ObservationIgnored let quickOpen = QuickOpenController()
    /// `{{clipboard}}` for templates (tests replace it).
    @ObservationIgnored var clipboardText: () -> String? = { NSPasteboard.general.string(forType: .string) }
    /// The template picker (⇧⌘N, AppModel+Templates.swift), when each template was last used, and
    /// the `{{title}}` prompt (tests replace it).
    @ObservationIgnored let templatePicker = QuickOpenController()
    @ObservationIgnored let templateRecents: TemplateRecents
    /// Tells the user an action did not happen (tests replace it).
    @ObservationIgnored var beep: () -> Void = { NSSound.beep() }
    @ObservationIgnored var askForTemplateTitle: @MainActor (_ templateTitle: String) -> String? = AppModel.promptForTemplateTitle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pullsFromBearAtLaunch: Bool
    /// Held weakly: a window's view owns its state; a released one drops out by itself.
    @ObservationIgnored private var mainWindowRefs: [WeakMainWindow] = []
    @ObservationIgnored private var madeMainWindow = false
    /// Where the editor of a note made by `newNoteInNewWindow` puts the caret, until its window opens.
    @ObservationIgnored private var pendingCarets: [String: Int] = [:]
    /// The heading a link opens a note window at (⌥⌘-click, ⌥⇧⌘K), until its window opens.
    @ObservationIgnored private var pendingHeadings: [String: Int] = [:]
    /// A tag link clicked in a note window with no main window open: the main window it opens
    /// selects the tag.
    @ObservationIgnored private var pendingTagSelection: String?
    /// Capture windows whose close is waiting for their editor to drain (AppModel+Capture.swift).
    @ObservationIgnored var captureCloses: [UUID: Task<Void, Never>] = [:]
    /// Told when the window Capture Thought opened has closed (capture from any app hands focus back).
    @ObservationIgnored var onCaptureWindowClosed: ((String) -> Void)?
    /// The app is quitting: a capture whose close is still undecided is kept.
    @ObservationIgnored var isQuitting = false
    /// The open note windows, held weakly (a window's view owns its state). `app open` finds the
    /// window of a note and the key editor through them (AppModel+Automation.swift).
    @ObservationIgnored var noteWindowRefs: [WeakNoteWindow] = []
    /// What `app open --new-window` / `--float` asks of a note window that is still being opened.
    @ObservationIgnored var pendingNoteOpens: [String: OpenNoteRequest] = [:]
    /// What `app open` and x-callback URLs ask of the main window that is still being opened (none was
    /// open): note opens, sidebar and workspace changes, in arrival order.
    @ObservationIgnored var pendingMainActions: [(MainWindowState) -> Void] = []
    /// Brings Theo Notes to the front (tests replace it).
    @ObservationIgnored var activate: () -> Void = { NSApp.activate() }
    /// When each window last became key (weak keys), for `keyEditor`'s fallback.
    @ObservationIgnored let windowActivation = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    @ObservationIgnored private var activationCounter = 0
    /// Orders windows by when they were made, across main and note windows.
    @ObservationIgnored var windowSerial = 0
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    /// The windows App Lock scrubs (titles, Dock images) when it engages; tests pass their own.
    @ObservationIgnored var lockableWindows: () -> [NSWindow] = { NSApp.windows }
    @ObservationIgnored let windowScrubber = AppLockWindowScrubber()

    /// `makeVoice` is a test seam for the voice note model (the default uses the microphone and the
    /// on-device speech engine).
    init(
        environment: AppEnvironment, defaults: UserDefaults = .standard, pullsFromBearAtLaunch: Bool = false,
        makeVoice: ((AppEnvironment) -> VoiceCaptureModel)? = nil
    ) {
        self.environment = environment
        self.defaults = defaults
        self.pullsFromBearAtLaunch = pullsFromBearAtLaunch
        templateRecents = TemplateRecents(defaults: defaults)
        settings = SettingsModel(database: environment.database)
        voice = makeVoice?(environment) ?? VoiceCaptureModel(environment: environment)
        voicePanel = VoicePanelController(model: voice)
        voice.openNote = { [weak self] noteId in self?.openNote(OpenNoteRequest(noteId: noteId)) ?? false }
        voiceBusyObservation = voice.$isBusy.sink { [weak self] busy in
            Task { @MainActor in self?.isMakingVoiceNote = busy }
        }
        environment.voiceCaptureBusy = { [weak voice] in voice?.isBusy == true }
        environment.linkUpdater?.preferredPresenter = { [weak self] in self?.frontmostMainWindow?.model }
        // Before the state is published: titles and Dock images are neutral when the lock shows.
        environment.appLock.addWillLockHandler { [weak self] in self?.appLockEngaged() }
        environment.appLock.addDidUnlockHandler { [weak self] in self?.appLockOpened() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The notification is delivered on the main queue; the window never leaves the main actor.
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        }
    }

    isolated deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// Notes that `window` is the one the user is working in now.
    func windowBecameKey(_ window: NSWindow?) {
        guard let window else { return }
        activationCounter += 1
        windowActivation.setObject(NSNumber(value: activationCounter), forKey: window)
    }

    /// Most requests that wait for `openWindow`.
    static let maxQueuedWindowRequests = 16

    /// Runs a window request now, or keeps it until SwiftUI's `openWindow` is installed. False when the
    /// request could not be kept (the queue is full): the caller must not report success.
    @discardableResult
    func requestWindow(_ request: WindowRequest) -> Bool {
        // A note window is tagged with the lock generation it was asked for under: its
        // host may appear only after a lock came and went, and then must not open the note.
        if case .note(let id) = request { noteRequestGenerations[id, default: []].append(environment.appLock.generation) }
        if let openWindowRequest {
            openWindowRequest(request)
            return true
        }
        guard queuedWindowRequests.count < Self.maxQueuedWindowRequests else { return false }
        queuedWindowRequests.append(request)
        return true
    }

    private func drainWindowRequests() {
        guard let openWindowRequest, !queuedWindowRequests.isEmpty else { return }
        let waiting = queuedWindowRequests
        queuedWindowRequests = []
        waiting.forEach(openWindowRequest)
    }

    /// Lets the windows' views route `WindowRequest`s to SwiftUI's `openWindow`.
    func install(_ openWindow: OpenWindowAction) {
        openWindowRequest = { request in
            switch request {
            case .main: openWindow(id: Self.mainWindowID)
            case .note(let id): openWindow(id: Self.noteWindowID, value: id)
            }
        }
    }

    // MARK: - Main windows

    /// The state of a new main window (File ▸ New Window, or a restored one). The first one made
    /// pulls from Bear when the setting asks for it.
    /// The window views call this when they appear and again when the app unlocks: while App Lock is
    /// engaged no window state is made, so no note is read, no session opened and no editor page
    /// loaded before the Mac has confirmed its owner.
    func makeMainWindowIfUnlocked() -> MainWindowState? {
        isLocked ? nil : makeMainWindow()
    }

    func makeNoteWindowIfUnlocked(noteId: String) -> NoteWindowState? {
        isLocked ? nil : makeNoteWindow(noteId: noteId)
    }

    enum NoteWindowClaim {
        case open(NoteWindowState)
        /// The app is locked: the host waits and shows the lock screen.
        case wait
        /// The request was made before a lock came; the host closes itself and opens nothing.
        case stale
    }

    /// What a note-window host does when it appears (and again when the app unlocks). A request made
    /// under an older lock generation is stale, whenever its host shows up; a window the system
    /// restored (no request of ours) opens once unlocked. A fresh request for the same note wins over
    /// stale ones.
    func claimNoteWindow(noteId: String) -> NoteWindowClaim {
        guard !isLocked else { return .wait }
        let current = environment.appLock.generation
        let recorded = noteRequestGenerations[noteId] ?? []
        if var fresh = recorded.filter({ $0 == current }) as [Int]?, !fresh.isEmpty {
            // One fresh request is used up; stale ones for this note are forgotten.
            fresh.removeLast()
            noteRequestGenerations[noteId] = fresh.isEmpty ? nil : fresh
        } else if !recorded.isEmpty {
            noteRequestGenerations[noteId] = nil
            return .stale
        }
        guard let state = makeNoteWindowIfUnlocked(noteId: noteId) else { return .wait }
        return .open(state)
    }

    /// Waiting window work that the lock drops: note windows that were queued, positions, headings.
    func discardPendingWindowWork() {
        queuedWindowRequests.removeAll { if case .note = $0 { true } else { false } }
        pendingCarets = [:]
        pendingHeadings = [:]
        pendingTagSelection = nil
    }

    func makeMainWindow(editor: EditorBridgeController? = nil) -> MainWindowState {
        let state = MainWindowState(environment: environment, defaults: defaults, editor: editor, settings: settings)
        state.openNoteWindow = { [weak self] in self?.openNoteInNewWindow(id: $0) }
        // The empty Next Up card offers a voice note.
        state.nextUp.startVoiceCapture = { [weak self] in self?.captureVoiceNote() }
        state.startNoteFromTemplate = { [weak self, weak state] in
            guard let self, let state else { return nil }
            return self.startNoteFromTemplate(in: state)
        }
        state.links.openNoteInNewWindow = { [weak self] in self?.openNoteInNewWindow(id: $0, headingIndex: $1) }
        state.onClose = { [weak self, weak state] in
            self?.mainWindowRefs.removeAll { $0.state == nil || $0.state === state }
        }
        windowSerial += 1
        mainWindowRefs.append(WeakMainWindow(state: state, serial: windowSerial))
        // Checked again here, not only when the action was accepted: nothing waiting runs while locked.
        if isLocked { discardDeferredWork() }
        if let tag = pendingTagSelection {
            pendingTagSelection = nil
            if !state.model.selectTag(named: tag) { appLogger.notice("tag link: no such tag in the sidebar") }
        }
        if !pendingMainActions.isEmpty {
            let actions = pendingMainActions
            pendingMainActions = []
            actions.forEach { $0(state) }
        }
        if !madeMainWindow {
            madeMainWindow = true
            if pullsFromBearAtLaunch, settings.snapshot.pullFromBearAtLaunch {
                state.importer.pullFromBear(quiet: true)
            }
        }
        return state
    }

    /// The open main windows, oldest first.
    var mainWindows: [MainWindowState] { mainWindowRefs.compactMap(\.state) }
    /// Each open main window with the serial it was made under.
    var mainWindowSerials: [(state: MainWindowState, serial: Int)] {
        mainWindowRefs.compactMap { ref in ref.state.map { ($0, ref.serial) } }
    }

    /// The main window in front (the last one used), if any is open.
    var frontmostMainWindow: MainWindowState? {
        let ordered = NSApp?.orderedWindows ?? []
        for window in ordered {
            if let state = mainWindows.first(where: { $0.window === window }) { return state }
        }
        return mainWindows.last
    }

    /// App Lock is engaged: nothing that shows or reaches library content runs.
    var isLocked: Bool { environment.appLock.isLocked }

    /// File ▸ New Window.
    func newMainWindow() {
        requestWindow(.main)
    }

    /// Window ▸ Main Window (⌘\): brings the frontmost main window forward, or opens one.
    func showMainWindow() {
        guard let window = frontmostMainWindow?.window else { return newMainWindow() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// File ▸ New Note (⌘N) from a note window: in the frontmost main window.
    func newNoteInMainWindow() {
        guard !isLocked else { return }
        guard let main = frontmostMainWindow else { return newMainWindow() }
        showMainWindow()
        main.newNote()
    }

    /// Quitting: link updates still waiting for their debounce run now (all windows).
    func runPendingLinkRewrites() {
        environment.linkUpdater?.runPendingNow()
    }

    /// Persists the frontmost main window's scope and note for the next launch.
    func saveSelection() {
        frontmostMainWindow?.saveSelection()
    }

    // MARK: - Note windows

    /// Opens `id` in its own note window (double-click, Note ▸ Open In New Window, ⌥⌘-click and
    /// ⌥⇧⌘K on a wiki link, with the caret on `headingIndex`). Also the entry point for Quick Open
    /// ⌘↩ (M4 Task 4; `caret` for a note it just made from a template).
    @discardableResult
    func openNoteInNewWindow(id: String, headingIndex: Int? = nil, caret: Int? = nil) -> Bool {
        guard !isLocked else { return false }
        if let headingIndex { pendingHeadings[id] = headingIndex } else { pendingHeadings[id] = nil }
        if let caret { pendingCarets[id] = caret }
        guard requestWindow(.note(id: id)) else {
            pendingHeadings[id] = nil
            if caret != nil { pendingCarets[id] = nil }
            return false
        }
        return true
    }

    /// ⌥⌘N: a new note (tagged like ⌘N would in `main`'s selected tag) in a new note window.
    func newNoteInNewWindow(from main: MainWindowState?) {
        guard !isLocked else { return }
        if startNoteFromTemplateInNewWindow(from: main) { return }
        do {
            let caret: LibraryModel.Caret
            if let main {
                caret = try main.model.createNoteForScope()
            } else {
                caret = LibraryModel.Caret(noteId: try environment.store.create(text: "").id, utf16Offset: 0)
            }
            pendingCarets[caret.noteId] = caret.utf16Offset
            openNoteInNewWindow(id: caret.noteId)
        } catch {
            appLogger.error("could not create a note for a new window: \(error)")
        }
    }

    /// The state of the note window SwiftUI opened for `noteId`.
    func makeNoteWindow(noteId: String, editor: EditorBridgeController? = nil) -> NoteWindowState {
        let state = NoteWindowState(
            environment: environment, noteId: noteId, editor: editor, caret: pendingCarets.removeValue(forKey: noteId),
            headingIndex: pendingHeadings.removeValue(forKey: noteId)
        )
        state.links.openNoteInNewWindow = { [weak self] in self?.openNoteInNewWindow(id: $0, headingIndex: $1) }
        environment.captureWindowOpened(noteId: noteId)
        state.onClose = { [weak self] editor, finish in
            guard let self else { return finish() }
            self.captureWindowClosed(noteId: noteId, editor: editor, finish: finish)
        }
        noteWindowRefs.removeAll { $0.state == nil || $0.state?.isOpen == false }
        windowSerial += 1
        noteWindowRefs.append(WeakNoteWindow(state: state, serial: windowSerial))
        if isLocked { discardDeferredWork() }
        if var request = pendingNoteOpens.removeValue(forKey: noteId) {
            // The heading went in with the window (`pendingHeadings`).
            request.headingIndex = nil
            apply(request, to: state)
        }
        // A note window has no sidebar: a tag link selects it in the frontmost main window, or in
        // the main window it opens when none is open.
        state.links.selectTag = { [weak self] name in
            guard let self else { return false }
            guard let main = self.frontmostMainWindow else {
                self.pendingTagSelection = name
                self.newMainWindow()
                return true
            }
            guard main.model.selectTag(named: name) else { return false }
            self.showMainWindow()
            return true
        }
        return state
    }
}

@MainActor
private struct WeakMainWindow {
    weak var state: MainWindowState?
    var serial: Int
}

@MainActor
struct WeakNoteWindow {
    weak var state: NoteWindowState?
    var serial: Int
}

/// A main window's content; makes its `MainWindowState` once the window exists.
struct MainWindowHost: View {
    let app: AppModel?
    let startupError: (any Error)?

    @State private var state: MainWindowState?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // App Lock: while it is engaged the lock screen replaces the whole window content.
        AppLockGate(lock: app?.environment.appLock) {
            Group {
                if let state {
                    MainWindow(state: state)
                        .background(WindowAccessor { state.attach(window: $0) })
                } else if let startupError {
                    Text("Theo Notes could not open its library: \(String(describing: startupError))")
                        .padding()
                } else {
                    Text("Theo Notes")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
            guard let app, state == nil else { return }
            app.install(openWindow)
            makeState(app)
        }
        // A window restored while the app was locked gets its state once the app is unlocked.
        .onChange(of: app?.isLocked ?? false) { _, locked in
            if !locked, state == nil, let app { makeState(app) }
        }
    }

    private func makeState(_ app: AppModel) {
        guard let made = app.makeMainWindowIfUnlocked() else { return }
        made.installKeyMonitor()
        state = made
    }
}

/// A note window's content; makes its `NoteWindowState` for the note it was opened with and keeps
/// the scene's value on the note it shows (in-window navigation), so restoration reopens that one.
struct NoteWindowHost: View {
    let app: AppModel?
    @Binding var noteId: String?

    @State private var state: NoteWindowState?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        AppLockGate(lock: app?.environment.appLock) {
            Group {
                if let state {
                    NoteWindow(state: state)
                } else {
                    Color.clear
                }
            }
        }
        .frame(minWidth: 360, minHeight: 240)
        .onAppear {
            guard let app, state == nil else { return }
            guard noteId != nil else { return dismissWindow() }
            app.install(openWindow)
            makeState(app)
        }
        .onChange(of: app?.isLocked ?? false) { _, locked in
            if !locked, state == nil, let app { makeState(app) }
        }
    }

    private func makeState(_ app: AppModel) {
        guard let noteId else { return }
        switch app.claimNoteWindow(noteId: noteId) {
        case .wait: return
        case .stale: dismissWindow()
        case .open(let made):
            let sceneValue = $noteId
            made.onNoteChange = { sceneValue.wrappedValue = $0 }
            state = made
        }
    }
}
