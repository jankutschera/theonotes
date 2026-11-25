// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import TheoNotesCore
import WatchConnectivity

/// A transport reply is not a committed-command ACK. Snapshots never enter applicationContext.
@MainActor final class MobileWatchConnectivity: NSObject, WCSessionDelegate {
    static let shared = MobileWatchConnectivity()
    private weak var library: MobileLibrary?
    private var generation: UInt64 = 0
    private var expiry: Task<Void, Never>?
    private var snapshotObservation: (any DatabaseCancellable)?
    private var snapshotObservationID: UUID?
    private var authorizedNoteIDs: Set<String> = []
    private var disclosureExpirations: [String: Date] = [:]
    private var disclosedUntil: Date?

    func connect(_ library: MobileLibrary?) {
        if self.library !== library { redact() }
        self.library = library
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func privacyChanged() {
        guard let library, !library.appLockEnabled, !library.appLocked,
              !library.isClosing, !library.isClosed else { redact(); return }
        if library.libraryOperationBusy { clearReadAuthorization(); return }
        Self.redactIfSnapshotRestricted(authorizedNoteIDs, lookup: { try library.store.note(id: $0) }, redact: { redact() })
    }
    /// Background and expiry clear OS-persisted context without claiming that App Lock is enabled.
    func clearReadAuthorization() {
        expiry?.cancel(); expiry = nil
        stopSnapshotObservation()
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        if !Self.submitRedaction(isPaired: session.isPaired, isWatchAppInstalled: session.isWatchAppInstalled,
                                 context: { try session.updateApplicationContext([:]) }, interactive: {}) {
            library?.errorMessage = "Watch privacy update is pending. Open the Watch app to reconnect."
        }
    }
    func redact() {
        expiry?.cancel(); expiry = nil
        stopSnapshotObservation()
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        let sent = Self.submitRedaction(isPaired: session.isPaired, isWatchAppInstalled: session.isWatchAppInstalled,
                                        context: { try session.updateApplicationContext([:]) }, interactive: {
            if WCSession.default.isReachable, let data = try? WatchWirePacket.redact.encoded() {
                WCSession.default.sendMessage(["wire": data], replyHandler: nil, errorHandler: nil)
            }
        })
        if !sent { library?.errorMessage = "Watch privacy update is pending. Open the Watch app to reconnect." }
    }
    static func submitRedaction(isPaired: Bool, isWatchAppInstalled: Bool, context: () throws -> Void, interactive: () -> Void) -> Bool {
        guard isPaired, isWatchAppInstalled else { return true }
        let succeeded: Bool
        do { try context(); succeeded = true } catch { succeeded = false }
        interactive()
        return succeeded
    }
    private func stopSnapshotObservation() {
        snapshotObservationID = nil
        authorizedNoteIDs = []
        disclosureExpirations = [:]
        disclosedUntil = nil
        snapshotObservation?.cancel(); snapshotObservation = nil
    }
    /// Observe exactly the notes already disclosed, independent of the visible iOS sidebar scope.
    static func observeSnapshotRestrictions(_ ids: Set<String>, database: AppDatabase,
                                            onRestriction: @escaping @MainActor () -> Void) -> any DatabaseCancellable {
        ValueObservation.tracking { db in
            try ids.contains { id in
                guard let note = try Note.fetchOne(db, key: id) else { return true }
                return note.isLocked || note.deletedAt != nil || note.location != .notes
            }
        }.removeDuplicates().start(in: database.pool, scheduling: .immediate,
            onError: { _ in onRestriction() }, onChange: { if $0 { onRestriction() } })
    }
    static func redactIfSnapshotRestricted(_ ids: Set<String>, lookup: (String) throws -> Note?, redact: () -> Void) {
        do {
            if try ids.contains(where: { id in
                guard let note = try lookup(id) else { return true }
                return note.isLocked || note.deletedAt != nil || note.location != .notes
            }) { redact() }
        } catch { redact() }
    }
    static func retainedDisclosures(previous: [String: Date], next: Set<String>, expiresAt: Date, now: Date) -> [String: Date] {
        var retained = previous.filter { $0.value > now }
        for id in next { retained[id] = max(retained[id] ?? expiresAt, expiresAt) }
        return retained
    }
    static func makeHelloSnapshot(_ hello: WatchWireHello, library: MobileLibrary, generation: UInt64, now: Date) throws -> WatchWireSnapshot {
        try hello.validate(now: now)
        guard !library.appLockEnabled, !library.appLocked, !library.isClosed, !library.isClosing,
              !library.libraryOperationBusy else { throw WatchWireError.unauthorized }
        let snapshot = WatchWireSnapshot(libraryID: try library.store.watchLibraryID(), epoch: try library.store.watchEpoch(),
            generation: generation, authorizationID: hello.id, issuedAt: hello.issuedAt, expiresAt: hello.expiresAt,
            redacted: false, notes: try MobileWatchProjection.notes(library: library))
        try snapshot.validate(now: now)
        return snapshot
    }
    private func helloReply(_ data: Data) -> [String: Any] {
        guard let packet = try? WatchWirePacket.decode(data), case .hello(let hello) = packet,
              let library else { return [:] }
        guard !library.appLockEnabled, !library.appLocked, !library.isClosing, !library.isClosed else {
            guard let data = try? WatchWirePacket.redact.encoded() else { return [:] }
            return ["wire": data]
        }
        guard !library.libraryOperationBusy else { clearReadAuthorization(); return [:] }
        do {
            guard generation < .max else { return [:] }
            generation += 1
            let now = Date.now
            let snapshot = try Self.makeHelloSnapshot(hello, library: library, generation: generation, now: now)
            let encoded = try WatchWirePacket.snapshot(snapshot).encoded()
            let retained = Self.retainedDisclosures(previous: disclosureExpirations, next: Set(snapshot.notes.map(\.id)), expiresAt: hello.expiresAt, now: now)
            guard retained.count <= 1024 else { redact(); return [:] }
            let deadline = max(disclosedUntil ?? hello.expiresAt, hello.expiresAt)
            stopSnapshotObservation()
            let observationID = UUID()
            snapshotObservationID = observationID
            disclosureExpirations = retained
            authorizedNoteIDs = Set(retained.keys)
            disclosedUntil = deadline
            let observation = Self.observeSnapshotRestrictions(authorizedNoteIDs, database: library.database) { [weak self] in
                guard let self, self.snapshotObservationID == observationID else { return }
                self.redact()
            }
            guard snapshotObservationID == observationID else { observation.cancel(); return [:] }
            snapshotObservation = observation
            expiry?.cancel()
            let delay = max(0, deadline.timeIntervalSince(now))
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.clearReadAuthorization()
            }
            return ["wire": encoded]
        } catch { return [:] }
    }
    private func receiveQueued(_ data: Data) async {
        guard let packet = try? WatchWirePacket.decode(data), case .command(let command) = packet, let library else { return }
        do {
            let ack = try await MobileWatchCommandHandler.handle(command, library: library)
            guard WCSession.default.activationState == .activated else { return }
            let transferID = "ack:" + ack.epoch.uuidString + ":" + ack.commandID.uuidString
            let pending = WCSession.default.outstandingUserInfoTransfers
            guard pending.count < 256, !pending.contains(where: { $0.userInfo["transferID"] as? String == transferID }) else { return }
            _ = WCSession.default.transferUserInfo(["wire": try WatchWirePacket.ack(ack).encoded(), "transferID": transferID])
        } catch { /* Leave the original command pending for a safe retry. */ }
    }
    private struct Reply: @unchecked Sendable { let send: ([String: Any]) -> Void }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in if activationState == .activated { self?.clearReadAuthorization(); self?.privacyChanged() } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message["wire"] as? Data else { replyHandler([:]); return }
        let reply = Reply(send: replyHandler)
        Task { @MainActor [weak self] in reply.send(self?.helloReply(data) ?? [:]) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["wire"] as? Data else { return }
        Task { @MainActor [weak self] in await self?.receiveQueued(data) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.redact() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { Task { @MainActor [weak self] in self?.clearReadAuthorization() } }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.clearReadAuthorization(); WCSession.default.activate() }
    }
}
