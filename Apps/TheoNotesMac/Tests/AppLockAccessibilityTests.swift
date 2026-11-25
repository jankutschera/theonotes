// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI
import Foundation
import Testing
@testable import TheoNotes

/// M9M-R62: what a screen reader and the window list see while App Lock is engaged. A hosted offscreen
/// window exposes no SwiftUI accessibility children (see `AccessibilityAuditTests`), so these run only
/// with `BAERCHEN_AX_AUDIT=1` on an unlocked screen, where the window is on screen and the tree is live.
/// On a locked screen they are NOT VERIFIED (GUI).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_AX_AUDIT"] == "1"))
struct AppLockAccessibilityTests {
    private func shown(_ view: some View, title: String = "Window") async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        return window
    }

    @Test func theLockedWindowNamesNoNoteAndOffersUnlock() async throws {
        let fixture = try AppLockFixture(enabled: true)
        defer { fixture.destroy() }
        let lock = fixture.makeLock(active: false)
        let secret = "SECRET-NOTE-TITLE-zqx"
        _ = try fixture.library.store.create(text: "# \(secret)")
        let window = try await shown(AppLockGate(lock: lock) { Text(secret) }, title: secret)
        defer { window.close() }

        let labels = AccessibilityWalker.labels(in: window)
        #expect(!labels.contains { $0.contains(secret) })
        #expect(labels.contains { $0.localizedCaseInsensitiveContains("locked") }, "\(labels)")
        #expect(labels.contains("Unlock"), "\(labels)")
        #expect(window.title == "Theo Notes", "the Window menu and the Dock list this title")

        fixture.authenticator.script(.success)
        #expect(await lock.unlock())
        try await Task.sleep(for: .milliseconds(300))
        #expect(AccessibilityWalker.labels(in: window).contains { $0.contains(secret) }, "the walker does see content once it is shown")
    }

    @Test func thePrivacyPaneHasItsRows() async throws {
        let root = URL(fileURLWithPath: "/tmp/theo-privacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(
            paths: AppPaths(root: root), vaultCache: FakeVaultKeyCache(), vaultLifecycle: nil,
            appAuthenticator: FakeAppAuthenticator(), appLockLifecycle: nil, appIdleSeconds: { 0 })
        _ = try environment.store.create(text: "# Quarterly numbers zqx")
        let settings = SettingsModel(database: environment.database)
        let window = try await shown(SettingsPane(tab: .privacy, settings: settings, environment: environment).frame(width: 500))
        defer { window.close() }
        let labels = AccessibilityWalker.labels(in: window).joined(separator: "\n")
        for expected in [
            "Use Touch ID to unlock notes", "Lock notes again after", "Change Note Password…",
            "Require Touch ID or your Mac password to open Theo Notes", "Lock after inactivity", "Reset Note Password…",
        ] {
            #expect(labels.contains(expected), "\(expected) in:\n\(labels)")
        }
        #expect(!labels.contains("Quarterly") && !labels.contains("zqx"))
    }
}
