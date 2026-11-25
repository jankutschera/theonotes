// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import SwiftUI
import Testing
import TheoNotesCore
import UIKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneViewIntegrationTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    @Test func nativeShieldCoversOnlyItsOwnWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let left = UIWindow(windowScene: scene), right = UIWindow(windowScene: scene)
        defer { MobilePrivacyShield.uncover(in: left); MobilePrivacyShield.uncover(in: right) }
        MobilePrivacyShield.cover(in: left)
        #expect(MobilePrivacyShield.isCovered(left) && !MobilePrivacyShield.isCovered(right))
        MobilePrivacyShield.cover(in: right)
        MobilePrivacyShield.uncover(in: left)
        #expect(!MobilePrivacyShield.isCovered(left) && MobilePrivacyShield.isCovered(right))
        MobilePrivacyShield.cover(in: nil) // Missing native identity must never mean all windows.
        #expect(!MobilePrivacyShield.isCovered(left))
    }

    @Test func twoHostedScenesKeepListsSelectionAndAttachmentOriginsIndependent() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let leftNote = try library.store.create(text: "# Left\n#Work"), rightNote = try library.store.create(text: "# Right\n#Home")
        let leftNavigation = MobileSceneNavigation(), rightNavigation = MobileSceneNavigation()
        leftNavigation.workspace = Workspace(path: "Work"); leftNavigation.selectedID = leftNote.id
        rightNavigation.scope = .tag("Home"); rightNavigation.selectedID = rightNote.id
        let leftEditor = MobileEditor(library: library), rightEditor = MobileEditor(library: library)
        let leftObserver = MobileSceneLibraryObservation(navigation: leftNavigation, database: library.database,
            isCurrent: { !library.appLocked && !library.isClosed && !library.sceneOperationPending }, debounce: .zero)
        let rightObserver = MobileSceneLibraryObservation(navigation: rightNavigation, database: library.database,
            isCurrent: { !library.appLocked && !library.isClosed && !library.sceneOperationPending }, debounce: .zero)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let left = UIWindow(windowScene: scene), right = UIWindow(windowScene: scene)
        defer {
            left.isHidden = true; right.isHidden = true
            left.rootViewController = nil; right.rootViewController = nil
            leftObserver.stop(); rightObserver.stop()
            try? library.close(); try? FileManager.default.removeItem(at: paths.root)
            previousKey?.makeKey()
        }
        left.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: leftEditor,
            sceneNavigation: leftNavigation, sceneObservation: leftObserver, applicationState: { .active }).environment(\.scenePhase, .active))
        right.rootViewController = UIHostingController(rootView: MobileLibraryView(library: library, editor: rightEditor,
            sceneNavigation: rightNavigation, sceneObservation: rightObserver, applicationState: { .active }).environment(\.scenePhase, .active))
        left.makeKeyAndVisible(); right.makeKeyAndVisible()
        try await wait { leftEditor.ready && rightEditor.ready && leftEditor.session?.noteId == leftNote.id && rightEditor.session?.noteId == rightNote.id }
        #expect(leftObserver.items.map(\.id) == [leftNote.id] && rightObserver.items.map(\.id) == [rightNote.id])
        let origin = try await leftEditor.captureAttachmentInsertionOrigin()
        rightNavigation.query = "Right"
        try await wait { rightObserver.searchTerms == ["Right"] }
        #expect(leftNavigation.query.isEmpty && leftNavigation.selectedID == leftNote.id)
        try await leftEditor.insertAttachments([ImportedAttachment(filename: "scene.txt", data: Data("left-only".utf8))], origin: origin)
        #expect(leftEditor.session?.text.contains("scene.txt") == true)
        #expect(rightEditor.session?.text == rightNote.text)
        #expect(library.selectedID == nil) // No view navigation is written into the legacy slot.
        rightNavigation.query = ""; rightNavigation.workspace = nil; rightNavigation.scope = .notes
        rightNavigation.selectedID = leftNote.id
        try await wait { rightEditor.ready && rightEditor.session === leftEditor.session }
        #expect(leftEditor.webView !== rightEditor.webView)
        left.isHidden = true; left.rootViewController = nil
        try await wait { library.sceneRegistry.sceneCount == 1 }
        #expect(leftEditor.session == nil && rightEditor.session?.noteId == leftNote.id)
        #expect(library.hasCachedSession(for: leftNote.id))
        right.isHidden = true; right.rootViewController = nil
        try await wait { !library.hasRegisteredSceneWindows }
        try await leftObserver.stopAndWait(); try await rightObserver.stopAndWait()
    }

    @Test func nativeWikiWindowRoutingPreservesSameWindowFallbackAndPrivacy() throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let editor = MobileEditor(library: library)
        let navigation = MobileSceneNavigation()
        editor.sceneNavigation = navigation
        var same: [String] = [], windows: [String] = []
        editor.onOpenNote = { same.append($0) }
        #expect(!editor.dispatchNoteLink("first", newWindow: true))
        editor.onOpenNoteInNewWindow = { windows.append($0) }
        #expect(editor.dispatchNoteLink("second", newWindow: true))
        #expect(!editor.dispatchNoteLink("third", newWindow: false))
        #expect(same == ["first", "third"] && windows == ["second"])
        #expect(!editor.dispatchNoteLink("heading-target", newWindow: true, heading: "Private heading"))
        #expect(same == ["first", "third", "heading-target"] && windows == ["second"])
        #expect(navigation.pendingCallbackNavigation?.noteID == "heading-target")
        #expect(navigation.pendingCallbackNavigation?.header == "Private heading")
        #expect(library.errorMessage?.contains("this window") == true)
        #expect(library.errorMessage?.contains("Private heading") == false)
        try editor.closeForPrivacy()
        #expect(!editor.dispatchNoteLink("refused", newWindow: true))
        #expect(windows == ["second"])
    }

    @Test func sceneBoundEmptySelectionNeverFallsBackToAnotherWindowsLegacySelection() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let note = try library.store.create(text: "# A note")
        library.selectedID = note.id
        let navigation = MobileSceneNavigation()
        let editor = MobileEditor(library: library)
        editor.sceneNavigation = navigation
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view = editor.webView; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; try? editor.closeForPrivacy(); previousKey?.makeKey() }
        try editor.open(note.id)
        try await wait { editor.ready && editor.editable }
        // Prove this is a ready editor; nil selection alone must refuse admission.
        await #expect(throws: MobileAttachmentError.self) { try await editor.captureAttachmentInsertionOrigin() }
        navigation.selectedID = note.id
        let origin = try await editor.captureAttachmentInsertionOrigin()
        navigation.selectedID = nil
        await #expect(throws: MobileAttachmentError.self) {
            try await editor.insertAttachments([ImportedAttachment(filename: "refused.txt", data: Data([1]))], origin: origin)
        }
        try library.flush()
        #expect(navigation.selectedID == nil)
        #expect(try library.store.note(id: note.id)?.text == note.text)
    }
}
