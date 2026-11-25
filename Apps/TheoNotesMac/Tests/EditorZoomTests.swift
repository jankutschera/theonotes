// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// M7 Task 10: View ▸ Zoom (one app-wide editor zoom), shell text styles, versioned TagCon URLs.
@MainActor
@Suite struct EditorZoomTests {
    @Test func zoomStepsClampAndSnap() {
        #expect(EditorZoom.zoomIn(1.0) == 1.1)
        #expect(EditorZoom.zoomIn(2.0) == 2.0)
        #expect(EditorZoom.zoomOut(0.8) == 0.8)
        #expect(EditorZoom.zoomOut(1.0) == 0.9)
        #expect(EditorZoom.zoomIn(1.05) == 1.1)
        // Off-step values snap first, then move one step.
        #expect(EditorZoom.zoomOut(1.05) == 0.9)
        #expect(EditorZoom.zoomOut(1.3) == 1.1)
        #expect(EditorZoom.zoomIn(1.3) == 1.5)
        #expect(EditorZoom.zoomIn(0.5) == 0.9)
        #expect(EditorZoom.snap(1.3) == 1.25)
        #expect(EditorZoom.snap(9) == 2.0)
        #expect(EditorZoom.snap(.nan) == 1.0)
        #expect(EditorZoom.actualSize == 1.0)
    }

    @Test func zoomIsAppliedToEveryEditorWebView() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesZoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment(paths: AppPaths(root: root))
        let settings = TheoNotesCore.Settings(db: environment.database)
        func editor() -> EditorBridgeController {
            EditorBridgeController(environment: environment, page: FakeEditorPage(), openExternally: { _ in }, checksumInterval: nil)
        }
        let first = editor(), second = editor()
        #expect(first.webView.pageZoom == 1.0)
        try settings.set(.editorZoom, to: 1.25)
        try await waitUntil("both editors zoomed") { first.webView.pageZoom == 1.25 && second.webView.pageZoom == 1.25 }
        // A new editor starts at the stored zoom; an off-step value snaps.
        try settings.set(.editorZoom, to: 1.3)
        try await waitUntil("snapped") { first.webView.pageZoom == 1.25 }
        #expect(editor().webView.pageZoom == 1.25)
        try settings.set(.editorZoom, to: 2.0)
        try await waitUntil("zoomed in") { second.webView.pageZoom == 2.0 }
    }

    @Test func viewMenuHasZoomItemsWithoutShortcutConflicts() throws {
        let mainMenu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let all = mainMenu.items.compactMap(\.submenu).flatMap(items)
        let mods: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        for (title, key) in [("Zoom In", "+"), ("Zoom Out", "-"), ("Actual Size", "0")] {
            let item = try #require(all.first { $0.title == title }, "\(title) missing")
            #expect(item.keyEquivalent == key, "\(title): \(item.keyEquivalent.debugDescription)")
            let flags = item.keyEquivalentModifierMask.intersection(mods)
            let sharing = all.filter { $0.keyEquivalent == item.keyEquivalent && $0.keyEquivalentModifierMask.intersection(mods) == flags }
            #expect(sharing.map(\.title) == [title], "\(title) shares its shortcut")
        }
    }

    @Test func noFixedPointFontsInShellViews() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        for folder in ["Library", "Info", "QuickOpen"] {
            let dir = sources.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                #expect(!text.contains(".font(.system(size:"), "\(folder)/\(file) uses a fixed point size")
            }
        }
    }

    @Test func tagconURLsAreVersioned() throws {
        let handler = AssetSchemeHandler(root: FileManager.default.temporaryDirectory)
        let icon = handler.response(for: URL(string: "baerchen-asset://tagcon/v2/star.png")!)
        #expect(icon.statusCode == 200)
        let image = try #require(NSBitmapImageRep(data: icon.body))
        #expect(image.pixelsWide == 96 && image.pixelsHigh == 96)
        #expect(handler.response(for: URL(string: "baerchen-asset://tagcon/star.png")!).statusCode == 404)
    }
}
