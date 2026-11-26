// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// What each menu bar item does; a seam so tests need no running app.
struct CaptureMenuBarActions {
    var capture: () -> Void
    var voiceNote: () -> Void
    var nextUp: () -> Void
    var openApp: () -> Void
    /// Read when the item is drawn, so they follow the lock state live.
    var voiceNoteDisabled: () -> Bool = { false }
    var nextUpDisabled: () -> Bool = { false }
}

enum CaptureMenuItem: CaseIterable {
    case capture, voiceNote, nextUp, openApp

    var title: String {
        switch self {
        case .capture: "Capture Thought"
        case .voiceNote: "Voice Note"
        case .nextUp: "Next Up"
        case .openApp: "Open Theo Notes"
        }
    }

    func perform(_ actions: CaptureMenuBarActions) {
        switch self {
        case .capture: actions.capture()
        case .voiceNote: actions.voiceNote()
        case .nextUp: actions.nextUp()
        case .openApp: actions.openApp()
        }
    }

    func isDisabled(_ actions: CaptureMenuBarActions) -> Bool {
        switch self {
        case .voiceNote: actions.voiceNoteDisabled()
        case .nextUp: actions.nextUpDisabled()
        case .capture, .openApp: false
        }
    }
}

/// The menu bar item's menu (it lives and dies with `CaptureSettings.showInMenuBar`).
struct CaptureMenuBarContent: View {
    let actions: CaptureMenuBarActions

    var body: some View {
        ForEach(CaptureMenuItem.allCases, id: \.self) { item in
            Button(item.title) { item.perform(actions) }.disabled(item.isDisabled(actions))
        }
    }
}

extension CaptureMenuBarActions {
    /// The live wiring. Clicking from another app must bring Theo Notes forward, which the voice and
    /// Next Up helpers do not do themselves.
    @MainActor
    static func live(app: AppModel?, capture: CaptureFromAnywhere?) -> CaptureMenuBarActions {
        CaptureMenuBarActions(
            capture: { capture?.capture() },
            voiceNote: { NSApp.activate(); app?.captureVoiceNote() },
            nextUp: { NSApp.activate(); app?.showNextUp(preferring: nil) },
            openApp: { app?.showMainWindow(); NSApp.activate() },
            voiceNoteDisabled: { VoiceMenu.isCaptureDisabled(app: app) },
            // Without a main window Next Up opens one first, so only the lock turns it off.
            nextUpDisabled: { app?.isLocked ?? true })
    }
}
