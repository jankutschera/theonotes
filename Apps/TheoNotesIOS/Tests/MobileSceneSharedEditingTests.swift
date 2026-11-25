// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import TheoNotesCore
import UIKit
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileSceneSharedEditingTests {
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition())
    }

    private func text(_ editor: MobileEditor) async -> String? {
        try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.toString()") as? String
    }

    @Test func twoWindowsExchangeEditsThroughOneSession() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        let note = try library.store.create(text: "# Shared\n")
        let first = MobileEditor(library: library), second = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let left = UIWindow(windowScene: scene), right = UIWindow(windowScene: scene)
        let leftController = UIViewController(), rightController = UIViewController()
        leftController.view = first.webView; rightController.view = second.webView
        left.rootViewController = leftController; right.rootViewController = rightController
        left.makeKeyAndVisible(); right.makeKeyAndVisible()
        defer {
            left.isHidden = true; right.isHidden = true
            left.rootViewController = nil; right.rootViewController = nil
            try? first.closeForPrivacy(); try? second.closeForPrivacy()
            try? library.close(); try? FileManager.default.removeItem(at: paths.root)
            previous?.makeKey()
        }
        try first.open(note.id); try second.open(note.id)
        try await wait { first.ready && second.ready && first.session === second.session }
        try await wait { let a = await text(first); let b = await text(second); return a == note.text && b == note.text }
        _ = try await first.webView.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({selection:{anchor:v.state.doc.length}})})()")
        first.command(.insertText, args: ["text": .string(" from-first")])
        let afterFirst = note.text + " from-first"
        try await wait { let a = await text(first); let b = await text(second); return a == afterFirst && b == afterFirst }
        _ = try await second.webView.evaluateJavaScript("(()=>{const v=document.querySelector('.cm-content').cmTile.root.view;v.dispatch({selection:{anchor:v.state.doc.length}})})()")
        second.command(.insertText, args: ["text": .string(" from-second")])
        let expected = afterFirst + " from-second"
        try await wait { let a = await text(first); let b = await text(second); return a == expected && b == expected }
        try library.flush()
        #expect(try library.store.note(id: note.id)?.text == expected)
    }
}
