// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// W1: `EditorBridgeController.freezeForClose(noteId:)`, the host's side of the capture-close
/// barrier (FOC-R343 … FOC-R349). The page is a recorder; its answers are played by the tests.
@MainActor
@Suite struct EditorFreezeForCloseTests {
    @MainActor
    private struct Fixture {
        let env: CaptureThoughtTests.Env
        let editor: EditorBridgeController
        let page: FakeEditorPage
        let noteId: String

        init() throws {
            env = try CaptureThoughtTests.Env()
            noteId = try env.store.create(text: "").id
            (editor, page) = env.editor()
            try editor.open(noteId: noteId)
        }

        func reply(
            _ question: (requestId: String, noteId: String)? = nil, ok: Bool = true, noteId: String? = nil,
            requestId: String? = nil, sha256: String? = sha256Hex("")
        ) throws {
            let asked = try #require(question ?? page.freezeRequests.last)
            _ = editor.handle(.frozenForClose(FrozenForClose(
                requestId: requestId ?? asked.requestId, noteId: noteId ?? asked.noteId, ok: ok, editedSinceLoad: false,
                sha256: ok ? sha256 : nil, reason: ok ? nil : .timeout)))
        }

        /// How long `body` takes; the question's own timeout is made long, so a question that ends in
        /// well under it ended because of the event the test is about, not because it ran out.
        func elapsed(_ body: () async -> Void) async -> Duration {
            editor.freezeTimeout = .seconds(30)
            return await ContinuousClock().measure { await body() }
        }

        func waitForQuestion(count: Int = 1) async {
            for _ in 0..<2000 where page.freezeRequests.count < count { await Task.yield() }
        }
    }

    @Test func asksThePageAboutTheShownNoteAndReturnsItsOkAnswer() async throws {
        let f = try Fixture()
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        #expect(f.page.freezeRequests.count == 1)
        #expect(f.page.freezeRequests.last?.noteId == f.noteId)

        try f.reply()
        let frozen = await answer.value
        #expect(frozen?.ok == true)
        #expect(frozen?.sha256 == sha256Hex(""))
    }

    @Test func aNotOkAnswerIsNoAnswer() async throws {
        let f = try Fixture()
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        try f.reply(ok: false)
        #expect(await answer.value == nil)
    }

    @Test func anAnswerWithoutAHashIsNoAnswer() async throws {
        let f = try Fixture()
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        try f.reply(sha256: nil)
        #expect(await answer.value == nil)
    }

    @Test func anUnknownOrLateRequestIdIsIgnored() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .milliseconds(150)
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        try f.reply(requestId: "someone-elses") // ignored: the question stays open
        try f.reply(requestId: UUID().uuidString)
        #expect(await answer.value == nil, "it ran into the timeout instead of being answered")

        // An answer to the question that already timed out changes nothing and does not crash.
        try f.reply()
    }

    @Test func aReplyForAnotherNoteIsAnError() async throws {
        let f = try Fixture()
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        try f.reply(noteId: "another-note")
        #expect(await answer.value == nil)
    }

    @Test func noAnswerInTimeIsNoAnswer() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .milliseconds(50)
        #expect(await f.editor.freezeForClose(noteId: f.noteId) == nil)
        #expect(f.page.freezeRequests.count == 1)
    }

    @Test func aFailedDeliveryIsNoAnswer() async throws {
        let f = try Fixture()
        f.page.deliveryError = CocoaError(.fileReadUnknown)
        #expect(await f.editor.freezeForClose(noteId: f.noteId) == nil)
    }

    @Test func doesNotAskAnEditorThatIsNotReadyOrShowsAnotherNote() async throws {
        let f = try Fixture()
        #expect(await f.editor.freezeForClose(noteId: "another-note") == nil)

        let page = FakeEditorPage()
        let cold = EditorBridgeController(
            environment: f.env.environment, page: page, openExternally: { _ in }, checksumInterval: nil)
        try cold.open(noteId: f.noteId) // no `ready` yet
        #expect(await cold.freezeForClose(noteId: f.noteId) == nil)
        #expect(page.freezeRequests.isEmpty && f.page.freezeRequests.isEmpty)
    }

    @Test func aNewLoadOfTheNoteEndsTheQuestionWithNoAnswer() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .seconds(30)
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        let took = await f.elapsed {
            f.editor.reloadShownNote()
            #expect(await answer.value == nil)
        }
        #expect(took < .seconds(5), "the load ended the question, not its timeout")
        try f.reply() // the old question's late answer does nothing
    }

    @Test func detachingTheEditorEndsTheQuestionWithNoAnswer() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .seconds(30)
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        let took = await f.elapsed {
            f.editor.showNoNote()
            #expect(await answer.value == nil)
        }
        #expect(took < .seconds(5), "detaching ended the question, not its timeout")
    }

    @Test func aTerminatedWebProcessEndsTheQuestionWithNoAnswer() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .seconds(30)
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        let took = await f.elapsed {
            f.editor.simulateWebContentTermination()
            #expect(await answer.value == nil)
        }
        #expect(took < .seconds(5), "the termination ended the question, not its timeout")
    }

    @Test func aNewQuestionReplacesTheOpenOne() async throws {
        let f = try Fixture()
        f.editor.freezeTimeout = .seconds(30)
        let first = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        let firstQuestion = try #require(f.page.freezeRequests.last)
        let second = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion(count: 2)
        let took = await ContinuousClock().measure { #expect(await first.value == nil) }
        #expect(took < .seconds(5), "the newer question ended the older one, not its timeout")

        try f.reply(firstQuestion, ok: false) // the first question's answer no longer counts for the second
        try f.reply()
        #expect(await second.value?.ok == true)
    }

    @Test func aChangeTheEditorSentBeforeTheAnswerIsApplied() async throws {
        let f = try Fixture()
        let answer = Task { await f.editor.freezeForClose(noteId: f.noteId) }
        await f.waitForQuestion()
        // The bridge delivers in order: the transaction reaches the session before the answer does.
        let reply = f.editor.handle(.changes(
            noteId: f.noteId, txId: UUID().uuidString, baseRevision: 0, revision: 1,
            changeSet: ChangeSet(sections: [.replace(deleteLength: 0, insert: "late")])))
        #expect(reply == .acked(revision: 1))
        try f.reply(sha256: sha256Hex("late"))
        let frozen = await answer.value
        #expect(frozen?.sha256 == sha256Hex("late"))
        #expect(f.editor.session?.text == "late")
    }
}
