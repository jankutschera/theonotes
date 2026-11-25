// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI
import Foundation
import Testing
@testable import TheoNotes

/// M7 Task 12: no unlabelled controls. A hosted offscreen window exposes no SwiftUI AX children
/// (probe 2026-10-23: only the title-bar buttons, even ordered front), so the audit runs only with
/// `BAERCHEN_AX_AUDIT=1` on an unlocked screen, where the window is on screen and AX is live.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_AX_AUDIT"] == "1"))
struct AccessibilityAuditTests {
    /// The system's own title-bar widgets are not ours to label.
    private func ours(_ issues: [AXIssue]) -> [AXIssue] {
        issues.filter { !$0.detail.contains("_NSTheme") }
    }

    @Test func mainWindowHasNoUnlabelledControls() async throws {
        let hosted = try await MainWindowChromeTests.Hosted()
        defer { hosted.close() }
        hosted.window.makeKeyAndOrderFront(nil)
        try await hosted.settle()
        let titles = Dictionary(uniqueKeysWithValues: hosted.state.model.items.map { ($0.id, $0.title.isEmpty ? "Untitled" : $0.title) })
        #expect(ours(AccessibilityAudit.issues(in: hosted.window, noteTitles: titles)).isEmpty)
    }

    @Test func settingsWindowHasNoUnlabelledControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesAXAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: SettingsModel(database: environment.database), environment: environment))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        #expect(ours(AccessibilityAudit.issues(in: window)).isEmpty)
    }
    // Quick Open, the Info panel and note windows: the M7 Task 14 VoiceOver checklist (Accessibility
    // Inspector), since the hosted audit sees no SwiftUI elements there either.
}
