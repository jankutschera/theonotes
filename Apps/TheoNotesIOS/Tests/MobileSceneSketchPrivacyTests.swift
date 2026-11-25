// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import PencilKit
import Testing
import UIKit
import WebKit
import TheoNotesCore
@testable import BaerchenIOS

private actor SceneSketchCheckpointGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func arm() { armed = true }
    func run() async throws {
        guard armed else { return }
        entered = true
        if fails { throw CocoaError(.fileWriteNoPermission) }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { armed = false; continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct MobileSceneSketchPrivacyTests {
    private func drawing(_ two: Bool) -> PKDrawing {
        PKDrawing(strokes: (two ? [20.0, 70.0] : [20.0]).map { x in
            let points = [CGPoint(x: x, y: 20), CGPoint(x: x + 10, y: 40)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: .init(width: 4, height: 4),
                    opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .blue),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
        })
    }
    @Test(arguments: [false, true])
    func sharedCloseWaitsOtherSceneFinalStrokeAndBoundsHeldCheckpoint(failedSibling: Bool) async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        try await library.unlockNotes(password: "fixture password", createPassword: true)
        let access = try #require(library.privateAccess)
        let first = MobileSceneNavigation(), second = MobileSceneNavigation()
        let a = MobileEditor(library: library), b = MobileEditor(library: library)
        try library.registerScene(id: first.id, editor: a, navigation: first, observation: nil, activity: .active)
        try library.registerScene(id: second.id, editor: b, navigation: second, observation: nil, activity: .active)
        let notes = [try library.store.create(text: ""), try library.store.create(text: "")]
        for note in notes { try access.lock(noteId: note.id) }
        let failure = SceneSketchCheckpointGate(fails: true), held = SceneSketchCheckpointGate()
        defer { Task { await held.release() } }
        let stores = [MobileSketchDraftStore(root: paths.root, libraryID: MobileCardPublication.libraryID(for: paths),
                          beforeCheckpoint: { try await failure.run() }),
                      MobileSketchDraftStore(root: paths.root, libraryID: MobileCardPublication.libraryID(for: paths),
                          beforeCheckpoint: { try await held.run() })]
        let ids = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!]
        let navigation = [first, second], generation = library.libraryGeneration
        var hosts: [MobileSketchDraftHost] = [], sessions: [MobileSketchSession] = []
        for index in 0..<2 {
            let noteID = notes[index].id
            let host = MobileSketchDraftHost(store: stores[index], owner: UUID(), id: ids[index], originalNoteID: noteID,
                boundary: { MobileSketchDraftPersistenceBoundary.isCurrent(library, root: paths.root, generation: generation) },
                protection: { MobileSketchDraftProtectionPolicy.resolve(requiresProtection: true, access: library.privateAccess) {
                    try library.store.note(id: noteID)
                } })
            library.registerSceneSketchHost(host, sceneID: navigation[index].id)
            #expect(try await host.reserveFresh())
            let session = try MobileSketchSession(drawing: drawing(false), canvasSize: .init(width: 256, height: 256),
                draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
                checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
            session.activateDraftHooks(); session.canvas.delegate = nil
            _ = host.control.checkpointNow(); #expect(try await host.waitForCheckpoint())
            session.canvas.drawing = drawing(true); session.canvasViewDrawingDidChange(session.canvas)
            hosts.append(host); sessions.append(session)
        }
        let latest = sessions[1].canvas.drawing.dataRepresentation()
        await held.arm()
        if failedSibling { await failure.arm() }
        let token = try #require(library.beginScenePrivacyClose()) // Captures/suspends BOTH scenes, not only caller.
        sessions.forEach { $0.teardown() }
        for _ in 0..<200 { if await held.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(await held.entered)
        var finished = false, sawFailure = false
        let completion = Task {
            let completed = await MobileSketchPrivacyCloseBudget.wait(timeout: failedSibling ? .seconds(2) : .milliseconds(40)) {
                do { try await library.prepareScenePrivacyClose(); try await library.completeScenePrivacyCheckpoints() }
                catch { sawFailure = true }
            }
            finished = true
            return completed
        }
        if failedSibling {
            // A failed first host must not skip the other scene's held final checkpoint.
            _ = try? await hosts[0].waitForCheckpoint()
            try await Task.sleep(for: .milliseconds(30))
            #expect(!finished)
            await held.release()
        }
        let completed = await completion.value
        #expect(completed == failedSibling)
        if !completed { library.revokePrivateAccessForExpiredPrivacyClose() }
        try library.lockVault()
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        library.finishScenePrivacyClose(token)
        if !failedSibling { await held.release(); _ = try? await hosts[1].waitForCheckpoint() }
        let reopened = try NotePrivacy(store: library.store).unlock(password: "fixture password")
        defer { reopened.revoke() }
        let durable = try #require(try await stores[1].load(hosts[1].id, access: reopened))
        if failedSibling {
            #expect(sawFailure && durable.drawingData == latest)
            #expect(try PKDrawing(data: durable.drawingData).strokes.count == 2)
        } else { #expect(try PKDrawing(data: durable.drawingData).strokes.count == 1) }
        #expect(try await stores[1].discover().allSatisfy(\.isProtected))
        try await library.detachScene(id: first.id); try await library.detachScene(id: second.id)
        try await library.closeAfterStopping()
    }
    @Test func slowOpenPageCannotStarveOtherScenesProtectedFinalStroke() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        try await library.unlockNotes(password: "slow page fixture", createPassword: true)
        let access = try #require(library.privateAccess)
        let note = try library.store.create(text: "# Actual open protected page")
        try access.lock(noteId: note.id)
        let navigation = MobileSceneNavigation(); navigation.selectedID = note.id
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller
        controller.view.addSubview(editor.webView); editor.webView.frame = controller.view.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try library.registerScene(id: navigation.id, editor: editor, navigation: navigation, observation: nil, activity: .active)
        try editor.open(note.id)
        for _ in 0..<400 { if editor.ready { break }; try await Task.sleep(for: .milliseconds(20)) }
        try #require(editor.ready && editor.session?.noteId == note.id)
        // Settle the host's loadNote send first: a freeze is sent only when nothing is pending.
        let settle = try await editor.prepareCaptureClose(note.id)
        editor.endCaptureClose(settle)
        let held = SlowPrivacyPage(editor)
        let messages = editor.webView.configuration.userContentController
        messages.removeScriptMessageHandler(forName: "bridge", contentWorld: .page)
        messages.addScriptMessageHandler(held, contentWorld: .page, name: "bridge")
        defer { held.deliver() }
        let sketchNavigation = MobileSceneNavigation(), sketchEditor = MobileEditor(library: library)
        try library.registerScene(id: sketchNavigation.id, editor: sketchEditor, navigation: sketchNavigation, observation: nil, activity: .active)
        let store = library.sketchDraftStore, generation = library.libraryGeneration
        let host = MobileSketchDraftHost(store: store, owner: UUID(), originalNoteID: note.id,
            boundary: { MobileSketchDraftPersistenceBoundary.isCurrent(library, root: paths.root, generation: generation) },
            protection: { MobileSketchDraftProtectionPolicy.resolve(requiresProtection: true, access: library.privateAccess) {
                try library.store.note(id: note.id)
            } })
        library.registerSceneSketchHost(host, sceneID: sketchNavigation.id)
        #expect(try await host.reserveFresh())
        let session = try MobileSketchSession(drawing: drawing(false), canvasSize: .init(width: 256, height: 256),
            draftControl: host.control, onCheckpoint: { host.checkpoint($0) },
            checkpointPause: { try await Task.sleep(for: .seconds(3600)) })
        session.activateDraftHooks(); session.canvas.delegate = nil
        _ = host.control.checkpointNow(); #expect(try await host.waitForCheckpoint())
        session.canvas.drawing = drawing(true); session.canvasViewDrawingDidChange(session.canvas)
        let latest = session.canvas.drawing.dataRepresentation()
        let token = try #require(library.beginScenePrivacyClose())
        session.teardown()
        var durableBeforePage = false, pageTimedOut = false
        let deadline = Date().addingTimeInterval(1)
        let completed = await MobileSketchPrivacyCloseBudget.wait(timeout: .seconds(2)) {
            await MobileSketchPrivacyCloseBudget.checkpointBeforePages(deadline: deadline, checkpoints: {
                do {
                    try await library.completeScenePrivacyCheckpoints()
                    durableBeforePage = try await store.load(host.id, access: access)?.drawingData == latest
                } catch { Issue.record(error) }
            }, pages: { deadline in
                #expect(durableBeforePage)
                do { try await library.prepareScenePrivacyClose(deadline: deadline) }
                catch { pageTimedOut = (error as? MobileEditorDrainError) == .timeout }
            })
        }
        #expect(completed && durableBeforePage && pageTimedOut && held.isHolding)
        try library.lockVault(); library.finishScenePrivacyClose(token)
        #expect(editor.isClosedForPrivacy && editor.session == nil)
        #expect(throws: NotePrivacyError.accessRevoked) { try access.journalKey() }
        held.deliver() // A late page acknowledgement cannot reopen the protected editor.
        #expect(editor.isClosedForPrivacy && editor.session == nil)
        let reopened = try NotePrivacy(store: library.store).unlock(password: "slow page fixture")
        let draft = try #require(try await store.load(host.id, access: reopened))
        #expect(draft.drawingData == latest)
        #expect(try PKDrawing(data: draft.drawingData).strokes.count == 2)
        reopened.revoke()
        try await library.detachScene(id: navigation.id)
        try await library.detachScene(id: sketchNavigation.id)
        try await library.closeAfterStopping()
        try FileManager.default.removeItem(at: paths.root)
    }

}


@MainActor private final class SlowPrivacyPage: NSObject, WKScriptMessageHandlerWithReply {
    let editor: MobileEditor
    var pending: (() -> Void)?
    var isHolding: Bool { pending != nil }
    init(_ editor: MobileEditor) { self.editor = editor }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        if (message.body as? [String: Any])?["type"] as? String == "frozenForClose" {
            pending = { self.editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
        } else { editor.userContentController(controller, didReceive: message, replyHandler: replyHandler) }
    }
    func deliver() { let reply = pending; pending = nil; reply?() }
}
