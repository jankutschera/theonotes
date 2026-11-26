// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import SwiftUI

/// Shows `content` while the app is open and the lock screen in its place while App Lock is
/// engaged. The content is not built, laid out or exposed to accessibility while locked, so no
/// note title or text exists in the window until the Mac has confirmed its owner.
struct AppLockGate<Content: View>: View {
    let lock: AppLock?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let lock, lock.isLocked {
            AppLockScreen(lock: lock)
        } else {
            content()
        }
    }
}

/// The full-window lock screen. It shows no library content, names no note and keeps the window
/// title to the app's name, so neither the Window menu nor the Dock lists a title.
struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Theo Notes is locked")
                .font(.title2)
            Text("Use Touch ID or your Mac password to open your notes.")
                .foregroundStyle(.secondary)
            if let notice = lock.notice {
                Text(notice)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button("Unlock") { Task { await lock.unlock() } }
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        .background(.background)
        .navigationTitle("Theo Notes")
        .task { await lock.requestAutomaticUnlock() }
    }
}
