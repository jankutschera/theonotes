// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotes

@MainActor
@Suite struct CaptureMenuBarTests {
    final class Recorder {
        var calls: [String] = []
        var actions: CaptureMenuBarActions {
            CaptureMenuBarActions(
                capture: { self.calls.append("capture") }, voiceNote: { self.calls.append("voice") },
                nextUp: { self.calls.append("nextUp") }, openApp: { self.calls.append("open") })
        }
    }

    @Test func menuBarItemsInOrder() {
        #expect(CaptureMenuItem.allCases.map(\.title) == ["Capture Thought", "Voice Note", "Next Up", "Open Theo Notes"])
    }

    @Test func captureItemCallsTheCoordinator() {
        let recorder = Recorder()
        for item in CaptureMenuItem.allCases { item.perform(recorder.actions) }
        #expect(recorder.calls == ["capture", "voice", "nextUp", "open"])
    }

    @Test func hidingTheItemPersists() throws {
        let name = "CaptureMenuBarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CaptureSettings(defaults: defaults, identity: .current).showInMenuBar)
        CaptureSettings(defaults: defaults, identity: .current).showInMenuBar = false
        #expect(!CaptureSettings(defaults: defaults, identity: .current).showInMenuBar)
    }

    @Test func nextUpWithoutAWindowRequestsOneAndShowsThePanelWhenItAppears() throws {
        let env = try AppSocketServerTests.Env()
        env.app.openWindowRequest = { [unowned env] in env.requests.append($0) }
        #expect(env.app.frontmostMainWindow == nil)
        let actions = CaptureMenuBarActions.live(app: env.app, capture: nil)
        #expect(!actions.nextUpDisabled())
        actions.nextUp()
        #expect(env.requests == [.main])
        let main = env.app.makeMainWindow()
        defer { main.close() }
        #expect(main.nextUp.isPresented)
        #expect(env.app.pendingMainActions.isEmpty)
    }

    @Test func lockedDisablesNextUpAndVoiceNote() async throws {
        let env = try AppSocketServerTests.Env()
        let actions = CaptureMenuBarActions.live(app: env.app, capture: nil)
        #expect(!actions.nextUpDisabled() && !actions.voiceNoteDisabled())
        await env.engageAppLock()
        #expect(actions.nextUpDisabled() && actions.voiceNoteDisabled())
        actions.nextUp()
        #expect(env.app.pendingMainActions.isEmpty)
        await env.unlockApp()
    }
}
