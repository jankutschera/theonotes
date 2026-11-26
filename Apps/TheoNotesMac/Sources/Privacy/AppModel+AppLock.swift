// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit

extension AppModel {
    /// App Lock is about to engage (`isLocked` is still false),. In this order: work
    /// that was accepted but not yet run is dropped, running copies stop, panels and sheets close,
    /// every window gets a neutral title and a neutral Dock image. The windows themselves swap to the
    /// lock screen through `AppLockGate` once the state is published.
    func appLockEngaged() {
        discardDeferredWork()
        CopyAsRunner.cancelCurrent()
        quickOpen.dismiss(restoringFocus: false)
        templatePicker.dismiss(restoringFocus: false)
        let windows = lockableWindows()
        AppLockWindowSweep.run(windows: windows)
        windowScrubber.scrub(windows)
    }

    /// The app was unlocked: titles and Dock images come back.
    func appLockOpened() {
        windowScrubber.restore()
    }

    /// Requests that waited for a window or for the app to finish starting do not survive the lock
    ///: an open accepted before it would otherwise show a note right after the unlock.
    func discardDeferredWork() {
        pendingMainActions = []
        pendingNoteOpens = [:]
        discardPendingWindowWork()
    }
}
