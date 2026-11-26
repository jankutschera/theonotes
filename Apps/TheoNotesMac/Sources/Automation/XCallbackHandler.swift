// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Foundation

/// URLs that arrive before there is an `XCallbackHandler` (the app is still opening its library) wait
/// here and run, in order, once it is set.
@MainActor
final class XCallbackInbox {
    static let maxPending = 16

    private var pending: [URL] = []
    var handler: XCallbackHandler? {
        didSet {
            guard let handler, !pending.isEmpty else { return }
            let waiting = pending
            pending = []
            waiting.forEach(handler.handle)
        }
    }

    func receive(_ url: URL) {
        if let handler { return handler.handle(url) }
        guard pending.count < Self.maxPending else {
            return appLogger.error("x-callback: dropped a URL, too many waiting for the app to start")
        }
        pending.append(url)
    }
}

/// `baerchen://x-callback-url/<action>`: parses the URL, runs it through `XCallbackExecutor` (the
/// same service the CLI and MCP use), shows what the executor asks for and opens the callback. The
/// outcome is used as the executor made it: `detailedErrors` is never changed here, so `x-error`
/// says no more than the executor allows; only the app's own log sees the code. Never logs
/// the URL or any note text.
@MainActor
final class XCallbackHandler {
    private let app: AppModel
    private let openURL: (URL) -> Void
    private let context: AutomationContext
    private let router: XCallbackUIRouter

    init(
        app: AppModel, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        context: AutomationContext = .live
    ) {
        self.app = app
        self.openURL = openURL
        self.context = context
        router = XCallbackUIRouter(app: app)
    }

    func handle(_ url: URL) {
        // App Lock: a locked app reads nothing, changes nothing and shows nothing. The caller
        // gets `x-error` (code 6) with a fixed text and nothing from the library.
        guard !app.isLocked else { return refuseWhileLocked(url) }
        let request: XCallbackRequest
        do throws(XCallbackFailure) {
            request = try XCallbackRequest.parse(url)
        } catch {
            appLogger.notice("x-callback: refused a URL (code \(error.code, privacy: .public))")
            // `parse` throws before it keeps `x-error`: read it from the URL (first one wins).
            let outcome = XCallbackOutcome(ui: .none, success: nil, failure: error)
            callBack(outcome, for: XCallbackRequest(action: .locked, error: Self.errorTarget(in: url)))
            return
        }
        // What was typed a moment ago is in the store before an action reads or changes the note.
        app.environment.flushAll()
        let outcome = executor().execute(request)
        router.perform(outcome.ui, selection: XCallbackSelection(request))
        if let failure = outcome.failure {
            appLogger.notice(
                "x-callback: \(request.action.rawValue, privacy: .public) failed (code \(failure.code, privacy: .public))")
        }
        if stopsBeforeAnswerForTesting { return }
        callBack(outcome, for: request)
        // The answer is handed back: a later identical request is a new one.
        if outcome.failure == nil, let receipt = outcome.receipt {
            XCallbackReceipts(database: app.environment.database).settle(receipt, now: context.now())
        }
    }

    /// Test seam: the request runs but the app stops before it answers (quit or crash).
    var stopsBeforeAnswerForTesting = false

    private func refuseWhileLocked(_ url: URL) {
        appLogger.notice("x-callback: refused a URL while the app is locked")
        let failure = XCallbackFailure(code: AppLockedRefusal.xCallbackCode, message: AppLockedRefusal.message)
        let outcome = XCallbackOutcome(ui: .none, success: nil, failure: failure, detailedErrors: true)
        callBack(outcome, for: XCallbackRequest(action: .locked, error: Self.errorTarget(in: url)))
    }

    private func callBack(_ outcome: XCallbackOutcome, for request: XCallbackRequest) {
        // The scheme rule lives in `callbackURL(for)`: nothing else opens a callback.
        if let callback = outcome.callbackURL(for: request) { openURL(callback) }
    }

    private func executor() -> XCallbackExecutor {
        let environment = app.environment
        let library = AutomationLibrary(paths: environment.paths, database: environment.database, store: environment.store)
        return XCallbackExecutor(
            library: library, context: context,
            selectedNoteId: { [app] in
                guard let id = app.keyEditor()?.session?.noteId, !id.isEmpty else { return nil }
                return id
            },
            clipboard: { [app] in app.clipboardText() })
    }

    /// The `x-error` URL of a request `XCallbackRequest.parse` refused: the first `x-error` with a
    /// value, so an empty one in front does not hide a real one.
    static func errorTarget(in url: URL) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "x-error" && !($0.value ?? "").isEmpty })?.value
        else { return nil }
        return URL(string: raw)
    }
}
