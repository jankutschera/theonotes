// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// Offscreen renders of the three panes with sample notes, written to `docs/m1/`. The windows
/// are never ordered front. Run with `TEST_RUNNER_BAERCHEN_SNAPSHOTS=1 xcodebuild … test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BAERCHEN_SNAPSHOTS"] == "1"))
struct LibrarySnapshotTests {
    private static let outputDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/m1", isDirectory: true)

    /// Sidebar and list need a `FocusState` owner.
    private struct Panes: View {
        enum Kind { case sidebar, list, window }
        let kind: Kind
        let state: MainWindowState
        @FocusState private var pane: Pane?

        var body: some View {
            switch kind {
            case .sidebar:
                SidebarView(model: state.model, showNoteCounts: true, pane: $pane)
            case .list:
                NavigationStack { NoteListView(state: state, pane: $pane) }
            case .window:
                MainWindow(state: state)
            }
        }
    }

    @Test func renderPanes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesSnapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let store = environment.store
        let now = Date()
        let kickoff = try store.create(
            text: "Project kickoff\nAgenda for Monday: scope, owners and the first milestone. #work/projects",
            now: now.addingTimeInterval(-60)
        )
        _ = try store.create(
            text: "Groceries\nMilk, eggs, sourdough, coffee beans and something for the weekend. #home",
            now: now.addingTimeInterval(-3_600)
        )
        _ = try store.create(
            text: "Weekly review #work\n- [ ] Inbox zero\n- [x] Plan next week",
            now: now.addingTimeInterval(-86_400)
        )
        _ = try store.create(text: "", now: now.addingTimeInterval(-90_000))
        let old = try store.create(text: "Old ideas\nThings that did not make it.", now: now.addingTimeInterval(-900_000))
        try store.setPinned([kickoff.id], pinned: true)
        try store.archive([old.id])

        let suite = "TheoNotesSnapshots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MainWindowState(environment: environment, defaults: defaults)
        state.model.banner = .conflictCopiesCreated(noteIds: [kickoff.id])

        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try await render(Panes(kind: .sidebar, state: state), size: CGSize(width: 240, height: 460), name: "sidebar")
        try await render(Panes(kind: .list, state: state), size: CGSize(width: 320, height: 460), name: "note-list")

        state.model.banner = nil
        state.model.selectScope(.trash)
        try await render(Panes(kind: .list, state: state), size: CGSize(width: 320, height: 300), name: "note-list-empty")
        try await render(EditorPane(state: state), size: CGSize(width: 480, height: 300), name: "editor-placeholder")

        state.model.selectScope(.tag("work"))
        state.model.selectNotes([])
        try await render(Panes(kind: .window, state: state), size: CGSize(width: 1100, height: 560), name: "main-window")
    }

    private static let m7Directory = outputDirectory.deletingLastPathComponent().appendingPathComponent("m7", isDirectory: true)

    /// M7 Task 9: the whole main window in five themes, `docs/m7/shell-<id>.png`.
    @Test func renderThemedShell() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TheoNotesSnapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let store = environment.store
        let now = Date()
        let kickoff = try store.create(
            text: "Project kickoff\nAgenda for Monday: scope, owners and the first milestone. #work/projects",
            now: now.addingTimeInterval(-60))
        _ = try store.create(
            text: "Groceries\nMilk, eggs, sourdough, coffee beans and something for the weekend. #home",
            now: now.addingTimeInterval(-3_600))
        _ = try store.create(
            text: "Weekly review #work\n- [ ] Inbox zero\n- [x] Plan next week", now: now.addingTimeInterval(-86_400))
        let locked = try store.create(text: "Journal\nSecret thoughts.", now: now.addingTimeInterval(-90_000))
        _ = locked
        try store.setPinned([kickoff.id], pinned: true)

        let suite = "TheoNotesSnapshots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MainWindowState(environment: environment, defaults: defaults)
        state.model.selectScope(.notes)
        state.model.search.query = "week"
        state.model.banner = .conflictCopiesCreated(noteIds: [kickoff.id])
        try await Task.sleep(for: .milliseconds(300))

        let settings = TheoNotesCore.Settings(db: environment.database)
        try FileManager.default.createDirectory(at: Self.m7Directory, withIntermediateDirectories: true)
        let themes: [(id: String, dark: Bool)] = [
            ("baerchen-red", false), ("baerchen-dark", true), ("high-contrast", false), ("nord", true),
            ("solarized-light", false),
        ]
        for (id, dark) in themes {
            if dark {
                settings.darkTheme = id
                settings.appearanceMode = .dark
            } else {
                settings.lightTheme = id
                settings.appearanceMode = .light
            }
            try await waitUntil("theme \(id)") { environment.appearance.resolved.theme.id == id }
            try await render(
                MainWindow(state: state), size: CGSize(width: 1100, height: 560), name: "shell-\(id)",
                appearance: dark ? .darkAqua : .aqua, directory: Self.m7Directory)
        }
    }

    private func render(
        _ view: some View, size: CGSize, name: String, appearance: NSAppearance.Name = .aqua, directory: URL? = nil
    ) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Lists load their rows on the next passes; a themed window also lets its web view repaint.
        try await Task.sleep(for: directory == nil ? .milliseconds(600) : .milliseconds(2000))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: (directory ?? Self.outputDirectory).appendingPathComponent("\(name).png"))
        window.contentView = nil
        window.close()
    }
}
