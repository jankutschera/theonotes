// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Testing
@testable import TheoNotes

@MainActor
@Suite struct CaptureFromAnywhereTests {
    typealias Env = AppSocketServerTests.Env

    final class FakeWorkspace: FrontmostAppProviding {
        var frontmostAppID: String?
        var isActive = true
        var activated: [String] = []
        var selfActivations = 0
        init(frontmost: String?) { frontmostAppID = frontmost }
        func activate(appID: String) -> Bool { activated.append(appID); return true }
        func activateSelf() { selfActivations += 1 }
    }

    private func make(frontmost: String?) throws -> (Env, FakeWorkspace, CaptureFromAnywhere) {
        let env = try Env()
        env.app.openWindowRequest = { [unowned env] in env.requests.append($0) }
        let workspace = FakeWorkspace(frontmost: frontmost)
        return (env, workspace, CaptureFromAnywhere(app: env.app, workspace: workspace))
    }

    @Test func captureCreatesAnInboxNoteAndActivates() throws {
        let (env, workspace, capture) = try make(frontmost: "com.apple.Safari")
        capture.capture()
        let notes = try env.store.allNotes()
        #expect(notes.count == 1)
        #expect(notes.first?.text == "")  // Inbox: no tag, so no type
        #expect(workspace.selfActivations == 1)
    }

    @Test func closingReturnsFocusToThePreviousApp() throws {
        let (env, workspace, capture) = try make(frontmost: "com.apple.Safari")
        capture.capture()
        capture.captureWindowClosed(noteId: try #require(try env.store.allNotes().first).id)
        #expect(workspace.activated == ["com.apple.Safari"])
    }

    @Test func closingDoesNotHandBackWhenTheoNotesIsNoLongerActive() throws {
        let (env, workspace, capture) = try make(frontmost: "com.apple.Safari")
        capture.capture()
        workspace.isActive = false  // the user moved on while the editor drained
        capture.captureWindowClosed(noteId: try #require(try env.store.allNotes().first).id)
        #expect(workspace.activated.isEmpty)
    }

    @Test func closingDoesNothingWhenTheoNotesWasFrontmost() throws {
        let (env, workspace, capture) = try make(frontmost: nil)
        capture.capture()
        capture.captureWindowClosed(noteId: try #require(try env.store.allNotes().first).id)
        #expect(workspace.activated.isEmpty)
    }

    @Test func lockedAppCreatesNothing() async throws {
        let (env, workspace, capture) = try make(frontmost: "com.apple.Safari")
        await env.engageAppLock()
        capture.capture()
        #expect(try env.store.allNotes().isEmpty)
        #expect(workspace.selfActivations == 1)
        #expect(env.requests == [.main], "the lock screen lives in a window, so one main window is requested")
    }

    @Test func secondPressFocusesTheOpenCaptureWindow() throws {
        let (env, workspace, capture) = try make(frontmost: "com.apple.Safari")
        capture.capture()
        capture.capture()
        #expect(try env.store.allNotes().count == 1)
        #expect(env.requests.count == 1)
        #expect(workspace.selfActivations == 2)
        // After the close a new press makes a new note.
        capture.captureWindowClosed(noteId: try #require(try env.store.allNotes().first).id)
        capture.capture()
        #expect(try env.store.allNotes().count == 2)
    }

    @Test func aCaptureTheLockCancelledIsForgotten() async throws {
        let (env, _, capture) = try make(frontmost: "com.apple.Safari")
        capture.capture()
        await env.engageAppLock()
        await env.unlockApp()
        capture.capture()
        #expect(try env.store.allNotes().count == 1)
        #expect(env.requests.count == 2)
    }
}
