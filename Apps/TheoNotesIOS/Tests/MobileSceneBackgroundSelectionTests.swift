// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Observation
import SwiftUI
import Testing
import TheoNotesCore
import UIKit
import WebKit
@testable import BaerchenIOS

@MainActor @Observable private final class BackgroundSelectionPhase { var value: ScenePhase = .active }
@MainActor private struct BackgroundSelectionHost: View {
    let library: MobileLibrary
    let navigation: MobileSceneNavigation
    let editor: MobileEditor
    @Bindable var phase: BackgroundSelectionPhase
    var body: some View {
        MobileLibraryView(library: library, editor: editor, sceneNavigation: navigation, applicationState: { .active })
            .environment(\.scenePhase, phase.value)
    }
}

@Suite(.serialized) @MainActor struct MobileSceneBackgroundSelectionTests {
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(try await condition())
    }
    private func webView(in view: UIView) -> WKWebView? {
        if let value = view as? WKWebView { return value }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }
    private func source(in window: UIWindow) async -> String? {
        guard let page = webView(in: window) else { return nil }
        return (try? await page.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()")) as? String
    }

    @Test(arguments: [false, true])
    func protectedLateTargetWaitsForOwnForegroundEvenWhenAnotherSceneKeepsVaultOpen(initiallyActive: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        try await library.unlockNotes(password: "isolated scene fixture", createPassword: true)
        let initialText = "# Initial protected drawing origin", lateText = "# Private late background destination"
        let first = try library.store.create(text: initialText), late = try library.store.create(text: lateText)
        try library.lockNote(first.id); try library.lockNote(late.id)
        let rightNote = try library.store.create(text: "# Other active window")
        let leftNavigation = MobileSceneNavigation(), rightNavigation = MobileSceneNavigation()
        if initiallyActive { leftNavigation.selectedID = first.id }
        rightNavigation.selectedID = rightNote.id
        let leftEditor = MobileEditor(library: library), rightEditor = MobileEditor(library: library)
        let leftPhase = BackgroundSelectionPhase(), rightPhase = BackgroundSelectionPhase()
        if !initiallyActive { leftPhase.value = .background }
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let left = UIWindow(windowScene: scene), right = UIWindow(windowScene: scene)
        defer {
            left.isHidden = true; right.isHidden = true
            left.rootViewController = nil; right.rootViewController = nil
            try? library.close(); try? FileManager.default.removeItem(at: paths.root)
            previousKey?.makeKey()
        }
        right.rootViewController = UIHostingController(rootView: BackgroundSelectionHost(library: library,
            navigation: rightNavigation, editor: rightEditor, phase: rightPhase))
        left.rootViewController = UIHostingController(rootView: BackgroundSelectionHost(library: library,
            navigation: leftNavigation, editor: leftEditor, phase: leftPhase))
        right.makeKeyAndVisible(); left.makeKeyAndVisible()
        try await wait { rightEditor.ready && library.sceneRegistry.sceneCount == 2 }
        if initiallyActive {
            try await wait { await source(in: left) == initialText }
            leftPhase.value = .background
            leftNavigation.selectedID = late.id // Arrives while the prior source still owns its page.
            try await wait { leftEditor.isClosedForPrivacy && leftEditor.session == nil && !library.sceneOperationPending }
        }
        #expect(library.privateAccess != nil && library.hasActiveSceneWindows)
        try await wait { MobilePrivacyShield.isCovered(left) }
        if !initiallyActive { leftNavigation.selectedID = late.id }
        try await Task.sleep(for: .milliseconds(150))
        #expect(leftEditor.session == nil)
        #expect(await source(in: left) != lateText)
        #expect(rightEditor.session?.noteId == rightNote.id && library.privateAccess != nil)
        #expect(MobilePrivacyShield.isCovered(left) && !MobilePrivacyShield.isCovered(right))
        leftPhase.value = .active
        try await wait { await source(in: left) == lateText }
        #expect(leftNavigation.selectedID == late.id && rightNavigation.selectedID == rightNote.id)
        #expect(!MobilePrivacyShield.isCovered(left))
        left.isHidden = true; right.isHidden = true
        left.rootViewController = nil; right.rootViewController = nil
        try await wait { !library.hasRegisteredSceneWindows }
    }
}
