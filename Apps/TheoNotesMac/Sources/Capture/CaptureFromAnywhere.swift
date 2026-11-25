// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

/// The running-app side of capture from any app: who is frontmost, and bringing apps forward.
@MainActor
protocol FrontmostAppProviding: AnyObject {
    /// Opaque id of the frontmost app other than Theo Notes (the live one is its process id).
    var frontmostAppID: String? { get }
    /// Theo Notes is the active app: only then is handing focus back right.
    var isActive: Bool { get }
    func activate(appID: String) -> Bool
    func activateSelf()
}

@MainActor
final class WorkspaceFrontmostApp: FrontmostAppProviding {
    /// The frontmost app, unless that is Theo Notes itself (nothing to hand back to then).
    var frontmostAppID: String? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return String(app.processIdentifier)
    }

    var isActive: Bool { NSApp.isActive }

    /// By process id, so two instances of one app are told apart. False when the app has quit.
    func activate(appID: String) -> Bool {
        guard let pid = Int32(appID), let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated
        else { return false }
        NSApp.yieldActivation(to: target)
        return target.activate(from: .current, options: [])
    }

    func activateSelf() { NSApp.activate() }
}

/// Capture Thought from any app (global shortcut, menu bar): a new empty note in its own window over
/// the current app; closing it hands focus back. Same App Lock rule as File ▸ Capture Thought.
@MainActor
final class CaptureFromAnywhere {
    private let app: AppModel
    private let workspace: FrontmostAppProviding
    private var open: (noteId: String, previousApp: String?)?

    init(app: AppModel, workspace: FrontmostAppProviding) {
        self.app = app
        self.workspace = workspace
        app.onCaptureWindowClosed = { [weak self] in self?.captureWindowClosed(noteId: $0) }
    }

    func capture() {
        // Locked: show the lock screen, create nothing.
        // The lock screen lives inside windows, so open one when none is.
        guard !app.isLocked else {
            app.showMainWindow()
            return workspace.activateSelf()
        }
        // A capture the lock cancelled never opens a window, so nothing would clear it.
        if let held = open, !app.environment.holdsCapture(noteId: held.noteId) { open = nil }
        if let open {
            // Second press: the capture is still open, so bring it forward instead of making another.
            app.noteWindow(showing: open.noteId)?.hostWindow?.makeKeyAndOrderFront(nil)
            return workspace.activateSelf()
        }
        let previous = workspace.frontmostAppID
        guard let noteId = app.captureThought() else { return }
        open = (noteId, previous)
        workspace.activateSelf()
    }

    func captureWindowClosed(noteId: String) {
        guard let open, open.noteId == noteId else { return }
        self.open = nil
        // The editor drain is async: if the user has moved on to another app, do not pull them back.
        if let previous = open.previousApp, workspace.isActive { _ = workspace.activate(appID: previous) }
    }
}
