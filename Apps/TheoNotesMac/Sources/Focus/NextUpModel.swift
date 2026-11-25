// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation

/// The Next Up card of one main window (spec A3, FOC-R7, FOC-R280 … FOC-R289): one candidate at a
/// time, its actions, and the two-minute timer. It reads `FocusCard` (TheoNotesCore) and writes
/// only through it; Later and Not Today never touch a note (I4), and the timer touches no row of
/// the library at all (its notification is tracked in the device-local ledger and nowhere else).
///
/// While App Lock is engaged the model shows nothing, offers nothing and does nothing (FOC-R281).
@MainActor
final class NextUpModel: ObservableObject {
    enum TimerState: Equatable {
        case idle
        case running(endsAt: Date)
        /// The two minutes are over; the panel says so until the timer is dismissed.
        case finished
    }

    /// The timer's length: two minutes.
    static let timerSeconds: TimeInterval = 120
    /// The one line of the timer notification (spec A3: no other copy).
    static let timerNotificationTitle = "Time's up"
    static let unsavedNotice = "This note has changes that are not saved yet."
    static let changedNotice = "That to-do changed, so it was not checked off."
    static let notShownNotice = "That note could not be opened."

    /// What the card shows now; nil when nothing is waiting (or App Lock is engaged).
    @Published private(set) var candidate: FocusCandidate?
    @Published private(set) var timerState: TimerState = .idle {
        didSet { syncToolbarState() }
    }
    /// What the toolbar button's symbol shows. It follows `timerState`, but never while the popover
    /// is up: changing the button under its own popover is the suspected cause of K5's stuck panel
    /// (FOC-R392), so the symbol catches up when the popover closes.
    @Published private(set) var toolbarTimerState: TimerState = .idle
    /// The popover is up.
    @Published var isPresented = false {
        didSet { syncToolbarState() }
    }
    /// A short remark under the card: why an action did not happen.
    @Published private(set) var notice: String?

    /// Shows a note with the caret at a UTF-16 offset; true when it was shown. The window sets it.
    var openNote: (_ noteId: String, _ caret: Int?) -> Bool = { _, _ in false }
    /// Starts a voice note. Nil until the voice UI is wired (C13); the empty card offers it when set.
    var startVoiceCapture: (() -> Void)?
    /// Whether the app is in front (tests set it).
    var isAppActive: () -> Bool = { NSApp?.isActive ?? false }
    /// Whether the panel may open itself when the timer ends (the window sets it to "is the key window").
    var canPresentOnTimerEnd: () -> Bool = { true }
    /// Edit ▸ Undo goes here (the window's undo manager; tests set one).
    weak var undoManager: UndoManager?

    private let environment: AppEnvironment
    private let scheduler: MacNotificationScheduler
    private let clock: any DebounceScheduler
    private let now: () -> Date
    private var timerAction: ScheduledAction?
    private var timerNotificationId: String?
    private var timerGeneration = 0
    private var lockToken: AppLock.HandlerToken?
    private var libraryObservation: ObservationToken?

    init(environment: AppEnvironment, scheduler: MacNotificationScheduler, clock: any DebounceScheduler, now: @escaping () -> Date) {
        self.environment = environment
        self.scheduler = scheduler
        self.clock = clock
        self.now = now
        lockToken = environment.appLock.addDidLockHandler { [weak self] in self?.appLockEngaged() }
        // A note locked in another window, by sync or by the CLI must leave the card at once (FOC-R286).
        libraryObservation = environment.notifier.observe { [weak self] in
            Task { @MainActor in self?.libraryChanged() }
        }
    }

    isolated deinit {
        if let lockToken { environment.appLock.removeDidLockHandler(lockToken) }
    }

    private var card: FocusCard { FocusCard(store: environment.store) }

    private func syncToolbarState() {
        guard !isPresented, toolbarTimerState != timerState else { return }
        toolbarTimerState = timerState
    }

    // MARK: State

    var isLocked: Bool { environment.appLock.isLocked }

    /// Done is offered for an open to-do in a note that can be edited.
    var canDone: Bool {
        guard !isLocked, case .todo(let todo)? = candidate else { return false }
        return !todo.isReadOnly
    }

    /// The empty card offers a voice note, once a voice UI is wired.
    var offersVoiceCapture: Bool {
        !isLocked && candidate == nil && startVoiceCapture != nil
    }

    /// Seconds left on a running timer; nil when none runs.
    var timerRemaining: TimeInterval? { timerRemaining(at: now()) }

    func timerRemaining(at date: Date) -> TimeInterval? {
        guard case .running(let endsAt) = timerState else { return nil }
        return max(0, endsAt.timeIntervalSince(date))
    }

    // MARK: Showing

    /// Reads the card again. Nothing is read while App Lock is engaged.
    func refresh() {
        guard !isLocked else {
            set(candidate: nil)
            return
        }
        do {
            set(candidate: try card.next(now: now()))
        } catch {
            appLogger.error("Next Up could not read the card: \(error)")
            set(candidate: nil)
        }
    }

    private func set(candidate new: FocusCandidate?) {
        if candidate != new { candidate = new }
    }

    /// Opens the panel with a fresh card.
    func present() {
        guard !isLocked else { return }
        notice = nil
        refresh()
        isPresented = true
    }

    func toggle() {
        if isPresented { isPresented = false } else { present() }
    }

    /// The library changed under a shown card: it is read again, so a note that was locked meanwhile
    /// supplies no text (a locked note's reminder falls back to its title).
    func libraryChanged() {
        guard candidate != nil else { return }
        refresh()
    }

    private func appLockEngaged() {
        set(candidate: nil)
        notice = nil
        isPresented = false
    }

    /// The window closed: the timer goes with it.
    func close() {
        dismissTimer()
        isPresented = false
        if let lockToken { environment.appLock.removeDidLockHandler(lockToken) }
        lockToken = nil
    }

    // MARK: Actions

    /// Open: shows the note, with the caret at the to-do's or reminder's line, records the open
    /// and handles a reminder (it is deleted). A note that could not be shown changes nothing.
    @discardableResult
    func open() -> Bool {
        guard !isLocked, let candidate else { return false }
        notice = nil
        guard openNote(candidate.noteId, caret(of: candidate)) else {
            notice = Self.notShownNotice
            return false
        }
        do {
            try card.opened(candidate, now: now())
        } catch {
            appLogger.error("Next Up could not record an open: \(error)")
        }
        isPresented = false
        refresh()
        return true
    }

    /// Later: hides this candidate until the next local midnight. Writes no note.
    func later() {
        guard !isLocked, let candidate else { return }
        notice = nil
        do {
            try card.later(candidate, now: now())
        } catch {
            appLogger.error("Next Up could not hide a candidate: \(error)")
        }
        refresh()
    }

    /// Not Today: hides the whole card until the next local midnight. Writes no note.
    func notToday() {
        guard !isLocked else { return }
        notice = nil
        do {
            try card.notToday(now: now())
        } catch {
            appLogger.error("Next Up could not hide the card: \(error)")
        }
        refresh()
    }

    /// Done: checks the one box. What was typed is saved first; a note that cannot be saved is left
    /// alone. One undo step, "Done". False when nothing was checked.
    @discardableResult
    func done() -> Bool {
        guard canDone, case .todo(let todo)? = candidate else { return false }
        notice = nil
        environment.flushAll()
        guard !environment.unsavedNoteIds.contains(todo.noteId) else {
            notice = Self.unsavedNotice
            return false
        }
        return applyDone(todo)
    }

    private func applyDone(_ todo: TodoCandidate) -> Bool {
        let toggle: TodoToggle
        do {
            toggle = try card.done(todo, now: now())
        } catch {
            appLogger.error("Next Up could not check a to-do: \(error)")
            notice = Self.changedNotice
            refresh()
            return false
        }
        registerUndo(of: toggle, for: todo)
        // The open session takes the new text now, not when the change notification arrives.
        environment.databaseDidChange()
        refresh()
        return true
    }

    /// One "Done" step; its undo registers the redo, which registers the undo again.
    private func registerUndo(of toggle: TodoToggle, for todo: TodoCandidate) {
        guard let undoManager else { return }
        let opensGroup = undoManager.groupingLevel == 0
        if opensGroup { undoManager.beginUndoGrouping() }
        defer { if opensGroup { undoManager.endUndoGrouping() } }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.revert(toggle, for: todo) }
        }
        undoManager.setActionName("Done")
    }

    private func revert(_ toggle: TodoToggle, for todo: TodoCandidate) {
        environment.flushAll()
        // Only while the note still reads what Done wrote: a later edit keeps the user's text.
        guard (try? card.undo(toggle, now: now())) == true else { return }
        environment.databaseDidChange()
        refresh()
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { _ = model.applyDone(todo) }
        }
        undoManager.setActionName("Done")
    }

    /// The empty card's voice note button.
    func captureVoice() {
        guard offersVoiceCapture else { return }
        isPresented = false
        startVoiceCapture?()
    }

    /// Where Open puts the caret: the to-do's line as it is now (lines may have moved since the card
    /// was read), else the position the card carries.
    private func caret(of candidate: FocusCandidate) -> Int? {
        switch candidate {
        case .reminder(let reminder):
            return reminder.caretOffset
        case .todo(let todo):
            if let note = (try? environment.store.note(id: todo.noteId)) ?? nil, !note.isLocked,
               let line = todo.anchor.resolve(in: note.text),
               let offset = LineAnchor.utf16Offset(ofLine: line, in: note.text) {
                return offset
            }
            return todo.caretOffset
        case .capture:
            return nil
        }
    }

    // MARK: Timer

    /// Starts the two-minute timer. One notification is scheduled for its end ("Time's up"); the
    /// panel shows the countdown and, when the app is in front at the end, the end itself. Nothing is
    /// written to the library. A timer that runs is not started again.
    func startTimer() async {
        guard !isLocked else { return }
        if case .running = timerState { return }
        timerGeneration += 1
        let generation = timerGeneration
        let endsAt = now().addingTimeInterval(Self.timerSeconds)
        timerState = .running(endsAt: endsAt)
        timerAction?.cancel()
        timerAction = clock.schedule(after: .seconds(Self.timerSeconds)) { [weak self] in
            self?.timerEnded(generation)
        }
        guard let identifier = await scheduler.startPanelTimer(
            title: Self.timerNotificationTitle, at: endsAt,
            panelShowsTheEnd: { [weak self] in self?.panelWillShowTheEnd() ?? false }) else { return }
        // Dismissed or started again while the request was on its way: that notification is stale.
        guard generation == timerGeneration, timerState != .idle else {
            scheduler.cancelTimer(identifier)
            return
        }
        timerNotificationId = identifier
        if timerState == .finished, panelWillShowTheEnd() { cancelTimerNotification() }
    }

    /// Dismiss: the timer stops and its notification (pending or already on screen) goes. No trace.
    func dismissTimer() {
        timerGeneration += 1
        timerAction?.cancel()
        timerAction = nil
        cancelTimerNotification()
        timerState = .idle
    }

    private func timerEnded(_ generation: Int) {
        guard generation == timerGeneration, case .running = timerState else { return }
        timerAction = nil
        timerState = .finished
        // Only a panel that really opens may take the system's place: in front, unlocked and in the
        // key window. Anywhere else the notification stays and banners (FOC-R282).
        guard panelWillShowTheEnd() else {
            appLogger.notice("next-up: the timer ended; the panel stays closed and the notification rings")
            return
        }
        cancelTimerNotification()
        isPresented = true
        appLogger.notice("next-up: the timer ended; the panel opened")
    }

    /// Whether this window's panel would open itself for the end of the timer right now.
    private func panelWillShowTheEnd() -> Bool {
        isAppActive() && !isLocked && canPresentOnTimerEnd()
    }

    private func cancelTimerNotification() {
        guard let identifier = timerNotificationId else { return }
        timerNotificationId = nil
        scheduler.cancelTimer(identifier)
    }
}
