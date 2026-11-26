// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesAutomation
import TheoNotesCore
import Foundation

/// The selection the cold-start URL of `app open` carries (`selection_*`). Offsets
/// are UTF-8 bytes.
struct XCallbackSelection: Equatable {
    var text: String?
    var offset: Int?
    var length: Int?

    /// Only `open-note` takes a selection; values that do not parse are left out.
    init?(_ request: XCallbackRequest) {
        guard request.action == .openNote else { return nil }
        text = request.params["selection_text"].flatMap { $0.isEmpty ? nil : $0 }
        offset = request.params["selection_offset"].flatMap { Int($0) }
        length = request.params["selection_length"].flatMap { Int($0) }
        if text == nil, offset == nil { return nil }
    }
}

/// Shows what the executor asked for: a note, a sidebar location or a workspace. Never activates the
/// app or orders a window forward for `showWindow: false`. Never logs note text.
@MainActor
struct XCallbackUIRouter {
    let app: AppModel

    func perform(_ intent: XCallbackUIIntent, selection: XCallbackSelection? = nil) {
        switch intent {
        case .none:
            return
        case .openNote(let id, let header, let newWindow, let float, let edit, let find, let showWindow):
            openNote(
                OpenParams(
                    noteId: id, header: header, edit: edit, newWindow: newWindow, float: float,
                    selectionText: selection?.text, selectionOffset: selection?.offset,
                    selectionLength: selection?.length),
                find: find, showWindow: showWindow, hasSelection: selection != nil)
        case .select(let scope, let search, let showWindow):
            guard
                app.withMainWindow({ main in
                    main.model.selectScope(scope)
                    main.model.search.query = search ?? ""
                    show(main, showWindow: showWindow)
                })
            else { return appLogger.error("x-callback: too many requests waiting for a window") }
        case .openWorkspace(let name):
            guard
                app.withMainWindow({ main in
                    if main.model.enterWorkspace(named: name) {
                        show(main, showWindow: true)
                    } else {
                        appLogger.notice("x-callback: open-workspace names no tag")
                    }
                })
            else { return appLogger.error("x-callback: too many requests waiting for a window") }
        case .closeWorkspace:
            guard
                app.withMainWindow({ main in
                    main.model.dismissWorkspace()
                    show(main, showWindow: true)
                })
            else { return appLogger.error("x-callback: too many requests waiting for a window") }
        }
    }

    private func show(_ main: MainWindowState, showWindow: Bool) {
        guard showWindow else { return }
        main.window?.makeKeyAndOrderFront(nil)
        app.activate()
    }

    /// The shared open path of `app open` (`AppAutomationHandler.open`). A selection the note no longer
    /// fits (a cold start can lag behind edits) must not keep the note from opening: it opens without.
    private func openNote(_ params: OpenParams, find: String?, showWindow: Bool, hasSelection: Bool) {
        let handler = AppAutomationHandler(app: app)
        do throws(AutomationError) {
            try handler.open(params, find: find, showWindow: showWindow)
        } catch {
            guard hasSelection else {
                return appLogger.notice("x-callback: open-note failed (\(error.code.rawValue, privacy: .public))")
            }
            var plain = params
            plain.selectionText = nil
            plain.selectionOffset = nil
            plain.selectionLength = nil
            do throws(AutomationError) {
                try handler.open(plain, find: find, showWindow: showWindow)
            } catch {
                appLogger.notice("x-callback: open-note failed (\(error.code.rawValue, privacy: .public))")
            }
        }
    }
}
