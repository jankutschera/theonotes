// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

/// What engaging App Lock does to AppKit windows that SwiftUI does not own (M9M-R64): sheets and
/// floating panels (Quick Open, the template picker, import and export panels) are closed, because
/// they list note titles or sit on top of the lock screen.
@MainActor
enum AppLockWindowSweep {
    /// Closes the sheets of `windows`, hides their panels and aborts a modal panel (an open or save
    /// panel). Returns the windows it touched.
    @discardableResult
    static func run(windows: [NSWindow] = NSApp.windows, abortModal: Bool = true) -> [NSWindow] {
        var touched: [NSWindow] = []
        if abortModal, NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        for window in windows {
            for sheet in window.sheets {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
                touched.append(sheet)
            }
            if window is NSPanel, window.isVisible {
                window.orderOut(nil)
                touched.append(window)
            }
        }
        return touched
    }
}

/// Window metadata the Window menu and the Dock read: the title, the minimised title and the
/// minimised image (M9M-R78). `scrub` runs before the locked state is published, so no title or
/// thumbnail of a note is ever visible while the app is locked; `restore` runs after the unlock.
/// A title that SwiftUI has set again meanwhile (the unlocked view came back first) is kept.
@MainActor
final class AppLockWindowScrubber {
    static let neutralTitle = "Theo Notes"

    private struct Saved {
        weak var window: NSWindow?
        let title: String
        let miniwindowTitle: String
        let miniwindowImage: NSImage?
    }

    private var saved: [ObjectIdentifier: Saved] = [:]

    /// A plain card with a lock; it carries nothing of the window it stands in for.
    static let placeholder: NSImage = {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 48, weight: .regular)) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            }
            return true
        }
    }()

    func scrub(_ windows: [NSWindow]) {
        for window in windows {
            let id = ObjectIdentifier(window)
            if saved[id] == nil {
                saved[id] = Saved(
                    window: window, title: window.title, miniwindowTitle: window.miniwindowTitle,
                    miniwindowImage: window.miniwindowImage)
            }
            window.title = Self.neutralTitle
            window.miniwindowTitle = Self.neutralTitle
            window.miniwindowImage = Self.placeholder
        }
    }

    func restore() {
        for entry in saved.values {
            guard let window = entry.window else { continue }
            window.miniwindowImage = entry.miniwindowImage
            window.miniwindowTitle = entry.miniwindowTitle
            if window.title == Self.neutralTitle { window.title = entry.title }
        }
        saved = [:]
    }
}
