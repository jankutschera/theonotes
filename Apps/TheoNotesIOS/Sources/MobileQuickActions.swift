// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CoreSpotlight
import Foundation
import TheoNotesCore
import UIKit

@MainActor enum MobileQuickActions {
    enum Action: String, CaseIterable {
        case newNote = "theonotes.capture.new-note"
        case scan = "theonotes.capture.scan"
        case search = "theonotes.capture.search"
        var route: MobileCaptureRouter.Action {
            switch self { case .newNote: .newNote; case .scan: .scan; case .search: .search }
        }
    }
    @discardableResult static func receive(type: String, deliveryID: UUID = UUID(),
                                           router: MobileCaptureRouter = MobileShortcutRuntime.captureRouter) -> Bool {
        guard let action = Action(rawValue: type) else { return false }
        router.enqueue(action.route, deliveryID: deliveryID)
        Task {
            do { try await router.drain() }
            catch is CancellationError {}
            catch { MobileSystemNavigation.library?.errorMessage = error.localizedDescription }
        }
        return true
    }
}

/// The scene delegate owns quick-action callbacks only; SwiftUI continues to own its scenes.
@MainActor final class MobileQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    private let coldDeliveryID = UUID()
    private let receive: (String, UUID) -> Bool

    override convenience init() {
        self.init(receive: { type, id in MobileQuickActions.receive(type: type, deliveryID: id) })
    }
    init(receive: @escaping (String, UUID) -> Bool) {
        self.receive = receive
        super.init()
    }
    @discardableResult func receiveColdShortcut(_ item: UIApplicationShortcutItem?) -> Bool {
        guard let item else { return false }
        return receive(item.type, coldDeliveryID)
    }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        receiveColdShortcut(connectionOptions.shortcutItem)
    }
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(receive(shortcutItem.type, UUID()))
    }
}

/// One pending note-navigation slot across system sources: the latest received user intent wins.
@MainActor final class MobileSpotlightNavigation {
    private enum Target {
        case spotlight(String)
        case widget(noteID: String, libraryID: String)
    }
    private weak var library: MobileLibrary?
    private var pendingTarget: Target?
    func connect(_ library: MobileLibrary?) { self.library = library }
    func receive(_ identifier: String) { pendingTarget = .spotlight(identifier) }
    func receiveWidget(noteID: String, libraryID: String) { pendingTarget = .widget(noteID: noteID, libraryID: libraryID) }
    func drain(ready: Bool) throws {
        guard ready, let library, !library.appLocked, !library.libraryOperationBusy,
              !library.isClosed, !library.isClosing, let target = pendingTarget else { return }
        pendingTarget = nil
        let id: String
        switch target {
        case .spotlight(let identifier):
            guard !library.appLockEnabled,
                  let noteID = MobileSpotlight.noteID(from: identifier, paths: library.paths) else { return }
            id = noteID
        case .widget(let noteID, let libraryID):
            guard libraryID == MobileCardPublication.libraryID(for: library.paths) else { return }
            id = noteID
        }
        guard let note = try library.store.note(id: id), !note.isLocked, note.deletedAt == nil,
              note.location != .trash else { return }
        // Widget cards only publish active notes; Spotlight also supports the archive.
        if case .widget = target, note.location != .notes { return }
        try library.reveal(id)
    }
}

/// A switch is claimed synchronously, before its first shutdown await. Lifecycle callbacks
/// cannot reconnect the outgoing store while shutdown, recovery or inbox draining is suspended.
@MainActor final class MobileLibraryRuntimeConnection {
    private let captureRouter: MobileCaptureRouter
    private let connectServices: (MobileLibrary?) -> Void
    private weak var library: MobileLibrary?
    private(set) var isSwitching = false
    init(captureRouter: MobileCaptureRouter, connectServices: @escaping (MobileLibrary?) -> Void) {
        self.captureRouter = captureRouter
        self.connectServices = connectServices
    }
    @discardableResult func connect(_ library: MobileLibrary?) -> Bool {
        guard !isSwitching else { return false }
        self.library = library
        captureRouter.connect(library, ready: false)
        connectServices(library)
        return true
    }
    @discardableResult func beginSwitch() -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true
        library = nil
        captureRouter.connect(nil, ready: false)
        connectServices(nil)
        return true
    }
    func finishSwitch(_ library: MobileLibrary?) {
        isSwitching = false
        connect(library)
    }
    func drainCaptures(_ library: MobileLibrary, ready: Bool) async throws {
        guard prepareToDrain(library, ready: ready) else { return }
        while true {
            let previousCount = captureRouter.pendingCount
            do { try await captureRouter.drain(); return }
            catch MobileCaptureRouter.Failure.libraryChanged {
                // Requests bound before the switch are terminal. Report them, then let newer
                // unbound requests reach the completed destination instead of remaining stuck.
                library.errorMessage = MobileCaptureRouter.Failure.libraryChanged.localizedDescription
                guard captureRouter.pendingCount < previousCount,
                      prepareToDrain(library, ready: ready) else { return }
            }
        }
    }

    @discardableResult func prepareToDrain(_ library: MobileLibrary, ready: Bool) -> Bool {
        guard !isSwitching, self.library === library, !library.isClosed, !library.isClosing else { return false }
        captureRouter.connect(library, ready: ready)
        return true
    }
}

@MainActor enum MobileSystemNavigation {
    static let spotlight = MobileSpotlight(index: MobileSystemSpotlightIndex())
    static let navigation = MobileSpotlightNavigation()
    static let connection = MobileLibraryRuntimeConnection(captureRouter: MobileShortcutRuntime.captureRouter) { library in
        connect(library)
        MobileShortcutRuntime.connect(library)
    }
    private(set) static weak var library: MobileLibrary?
    static func connect(_ library: MobileLibrary?) {
        self.library = library
        spotlight.connect(library)
        navigation.connect(library)
    }
    static func receiveSpotlight(_ identifier: String) { navigation.receive(identifier) }
    static func receiveWidget(noteID: String, libraryID: String) { navigation.receiveWidget(noteID: noteID, libraryID: libraryID) }
    static func drain(ready: Bool) throws { try navigation.drain(ready: ready) }
}
