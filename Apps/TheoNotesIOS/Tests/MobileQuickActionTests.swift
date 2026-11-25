// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import UIKit
import TheoNotesCore
@testable import BaerchenIOS

@Suite @MainActor struct MobileQuickActionTests {
    @Test func staticMenuMatchesTheThreeSupportedActions() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any])
        let items = try #require(plist["UIApplicationShortcutItems"] as? [[String: String]])
        #expect(items.count == 3)
        #expect(Set(items.compactMap { $0["UIApplicationShortcutItemType"] }) == Set(MobileQuickActions.Action.allCases.map(\.rawValue)))
    }

    @Test(arguments: MobileQuickActions.Action.allCases)
    func coldAndWarmActionsUseTheCaptureQueueExactlyOnce(action: MobileQuickActions.Action) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let router = MobileCaptureRouter(canScan: { true })
        let coldID = UUID()
        #expect(MobileQuickActions.receive(type: action.rawValue, deliveryID: coldID, router: router))
        #expect(MobileQuickActions.receive(type: action.rawValue, deliveryID: coldID, router: router))
        try await router.drain()
        #expect(router.pendingCount == 1)
        #expect(try library.store.allNotes().isEmpty)
        router.connect(library, ready: false)
        try await router.drain()
        #expect(router.pendingCount == 1)
        try await library.setAppLock(true, authenticate: {})
        library.lockApplication()
        router.connect(library, ready: true)
        try await router.drain()
        #expect(router.pendingCount == 1)
        try await library.setAppLock(false, authenticate: {})
        try await router.drain()
        #expect(router.pendingCount == 0)
        if action != .newNote {
            let presentation = try #require(router.presentation)
            #expect(presentation.id == coldID && presentation.action == action.route)
            // Scan cancellation consumes the presentation, without creating any attachment.
            #expect(router.finishPresentation(deliveryID: coldID))
        }
        let expectedColdCount = action == .search ? 0 : 1
        #expect(try library.store.allNotes().count == expectedColdCount)
        if action == .scan {
            let note = try #require(try library.store.allNotes().first)
            let directory = paths.attachments.appendingPathComponent(note.id).path
            let files = FileManager.default.fileExists(atPath: directory)
                ? try FileManager.default.contentsOfDirectory(atPath: directory) : []
            #expect(files.isEmpty)
        }
        let warmID = UUID()
        #expect(MobileQuickActions.receive(type: action.rawValue, deliveryID: warmID, router: router))
        try await router.drain()
        #expect(router.pendingCount == 0)
        #expect(try library.store.allNotes().count == expectedColdCount * 2)
        if action != .newNote { #expect(router.finishPresentation(deliveryID: warmID)) }
    }

    @Test func sceneColdDeliveryDeduplicatesWhileWarmCallbacksRemainNewActions() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let router = MobileCaptureRouter()
        let delegate = MobileQuickActionSceneDelegate(receive: { type, id in
            MobileQuickActions.receive(type: type, deliveryID: id, router: router)
        })
        #expect(delegate.responds(to: #selector(UISceneDelegate.scene(_:willConnectTo:options:))))
        let item = UIApplicationShortcutItem(type: MobileQuickActions.Action.newNote.rawValue, localizedTitle: "Fixture")
        // UIKit alone constructs ConnectionOptions (its init is unavailable); exercise the
        // same production forwarding method that willConnect calls with options.shortcutItem.
        #expect(delegate.receiveColdShortcut(item))
        #expect(delegate.receiveColdShortcut(item))
        #expect(router.pendingCount == 1)
        router.connect(library, ready: true)
        try await router.drain()
        #expect(try library.store.allNotes().count == 1)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        var acknowledged = false
        delegate.windowScene(scene, performActionFor: item) { acknowledged = $0 }
        #expect(acknowledged)
        try await router.drain()
        #expect(try library.store.allNotes().count == 2)
        // Repeating a different user-invoked warm action must remain possible.
        delegate.windowScene(scene, performActionFor: item) { acknowledged = $0 }
        try await router.drain()
        #expect(acknowledged && router.pendingCount == 0)
        #expect(try library.store.allNotes().count == 3)
    }

    @Test func unknownActionDoesNotQueueAnything() {
        let router = MobileCaptureRouter()
        #expect(!MobileQuickActions.receive(type: "unknown.fixture", router: router))
        #expect(router.pendingCount == 0)
    }
}
