// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
@preconcurrency import WatchConnectivity

/// The outbox alone persists command text. Read authorization and snapshots stay in memory.
@MainActor final class TheoNotesWatchTransport: NSObject, WatchLibraryActions, WCSessionDelegate {
    let presentation = WatchLibraryPresentation()
    private(set) var outbox: WatchCommandOutbox?
    private var outboxURL: URL?
    private var foreground = false
    private var started = false
    private var hello: WatchWireHello?
    private var helloDeadline: ContinuousClock.Instant?
    private var authorization = WatchSnapshotAuthorization()
    private var expiryTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    init(outboxURL: URL? = nil) {
        super.init()
        do {
            let url: URL
            if let outboxURL { url = outboxURL }
            else {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                url = root.appendingPathComponent("WatchCommands/outbox.json")
            }
            self.outboxURL = url
            outbox = try WatchCommandOutbox(url: url)
            updateOperations()
        } catch { presentation.notice = .queueFailed }
    }
    func start() {
        guard !started else { return }
        started = true
        guard WCSession.isSupported() else { presentation.notice = .unavailable; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        deliveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self else { return }
                self.updateOperations()
                if self.foreground, WCSession.default.activationState == .activated, WCSession.default.isReachable { self.refresh() }
                else { self.retryPending() }
            }
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            if outbox == nil, let outboxURL {
                do { outbox = try WatchCommandOutbox(url: outboxURL); updateOperations() }
                catch { presentation.notice = .queueFailed }
            }
            refresh()
        }
        else { invalidate() }
    }
    private func invalidate() {
        hello = nil; helloDeadline = nil; authorization.invalidate()
        expiryTask?.cancel(); expiryTask = nil
        presentation.notes = []; presentation.isAuthorized = false; presentation.authorizationDeadline = nil
    }
    func refresh() {
        guard started, foreground, WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            invalidate()
            presentation.notice = .unavailable; return
        }
        let existingDeadline = presentation.canReadContent ? presentation.authorizationDeadline : nil
        let now = Date(), id = UUID()
        let hello = WatchWireHello(id: id, issuedAt: now, expiresAt: now.addingTimeInterval(WatchWireHello.lifetime))
        do {
            try authorization.authorize(hello, now: now)
            self.hello = hello
            let deadline = ContinuousClock.now.advanced(by: .seconds(WatchWireHello.lifetime))
            helloDeadline = deadline
            scheduleExpiry(deadline: existingDeadline ?? deadline, authorizationID: id)
            let data = try WatchWirePacket.hello(hello).encoded()
            let handlers = helloHandlers(id: id)
            WCSession.default.sendMessage(["wire": data], replyHandler: handlers.reply, errorHandler: handlers.error)
            retryPending()
        } catch { invalidate(); presentation.notice = .unavailable }
    }
    /// WatchConnectivity calls these on a background queue. Written inline in a main-actor method they carry a main-thread
    /// check and trap there (1.0.0 build 1 on a real Watch), so they are nonisolated and hop themselves.
    nonisolated func helloHandlers(id: UUID) -> (reply: @Sendable ([String: Any]) -> Void, error: @Sendable (any Error) -> Void) {
        ({ [weak self] reply in
            guard let data = reply["wire"] as? Data else { return }
            Task { @MainActor in
                guard self?.hello?.id == id else { return }
                self?.receiveData(data)
            }
        }, { [weak self] _ in
            Task { @MainActor in
                guard self?.hello?.id == id else { return }
                self?.invalidate(); self?.presentation.notice = .unavailable
            }
        })
    }
    private func scheduleExpiry(deadline: ContinuousClock.Instant, authorizationID: UUID) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard self?.hello?.id == authorizationID else { return }
            self?.invalidate(); self?.presentation.notice = .unavailable
        }
    }
    func create(text: String) throws -> UUID { try enqueue(.create(text: text)) }
    func append(noteID: UUID, revision: Int, text: String) throws -> UUID {
        try enqueue(.append(noteID: noteID.uuidString.lowercased(), revision: revision, text: text))
    }
    func setTask(_ target: WatchTaskTarget, checked: Bool) throws -> UUID {
        try enqueue(.setTask(noteID: target.noteID.uuidString.lowercased(), revision: target.revision,
                             sourceSHA256: target.sourceSHA256, utf16Offset: target.utf16Offset,
                             expectedMarker: target.expectedMarker, checked: checked))
    }
    func draftText(id: UUID) throws -> String {
        guard foreground, presentation.canReadContent, let draft = outbox?.drafts.first(where: { $0.id == id }) else {
            throw WatchWireError.unauthorized
        }
        return draft.text
    }
    func recoverDraft(id: UUID, text: String) throws -> UUID {
        guard foreground, presentation.canReadContent, let outbox, let binding = outbox.binding else { throw WatchWireError.unauthorized }
        let command = WatchWireCommand(id: UUID(), libraryID: binding.libraryID, epoch: binding.epoch, action: .create(text: text))
        do { try outbox.recoverDraft(id: id, command: command) }
        catch {
            guard outbox.pending.contains(where: { $0.id == command.id }) else { throw error }
            presentation.notice = .storagePending
            updateOperations(checkDeliveryClock: false)
            throw WatchWireError.pendingDurability(command.id)
        }
        updateOperations()
        do { try transfer(command) } catch { presentation.notice = .unavailable }
        return command.id
    }
    func updateDraft(id: UUID, text: String) throws {
        guard foreground, presentation.canReadContent, let outbox else { throw WatchWireError.unauthorized }
        try outbox.updateDraft(id: id, text: text)
    }
    func saveDraft(id: UUID, text: String) throws {
        guard let outbox else { throw WatchWireError.storage }
        try outbox.saveDraft(id: id, text: text)
        updateOperations(checkDeliveryClock: false)
    }
    func confirmSubmission(id: UUID) throws -> UUID {
        guard let outbox else { throw WatchWireError.storage }
        do { try outbox.retryDurability() }
        catch { presentation.notice = .storagePending; throw WatchWireError.pendingDurability(id) }
        updateOperations(checkDeliveryClock: false)
        if presentation.notice == .storagePending { presentation.notice = nil }
        if let command = outbox.pending.first(where: { $0.id == id }) {
            do { try transfer(command) } catch { presentation.notice = .unavailable }
            return id
        }
        guard outbox.completed.contains(where: { $0.ack.commandID == id }) || outbox.drafts.contains(where: { $0.id == id }) else { throw WatchWireError.invalid }
        return id
    }
    func retryRequest(id: UUID) throws {
        guard let outbox, let command = outbox.pending.first(where: { $0.id == id }),
              outbox.binding?.libraryID == command.libraryID else { throw WatchWireError.binding }
        try outbox.renewDelivery(id: id)
        updateOperations()
        do { try transfer(command, explicitRetry: true) } catch { presentation.notice = .unavailable }
    }
    func keepDictation(id: UUID) throws {
        guard let outbox else { throw WatchWireError.storage }
        if let command = outbox.pending.first(where: { $0.id == id }) {
            let waiting = outbox.binding?.libraryID != command.libraryID
            let expired = outbox.delivery(for: id)?.expired != false ||
                outbox.delivery(for: id).map { Date() >= $0.expiresAt } == true
            guard waiting || expired else { throw WatchWireError.invalid }
            _ = try outbox.keepPendingDictation(id: id)
        } else {
            guard outbox.drafts.contains(where: { $0.id == id }) else { throw WatchWireError.invalid }
            try outbox.retryDurability()
        }
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            for transfer in WCSession.default.outstandingUserInfoTransfers {
                guard let data = transfer.userInfo["wire"] as? Data,
                      case .command(let command)? = try? WatchWirePacket.decode(data), command.id == id else { continue }
                transfer.cancel()
            }
        }
        updateOperations()
    }
    private func enqueue(_ action: WatchWireAction) throws -> UUID {
        guard let outbox, let binding = outbox.binding else { throw WatchWireError.binding }
        let command = WatchWireCommand(id: UUID(), libraryID: binding.libraryID, epoch: binding.epoch, action: action)
        do { try outbox.enqueue(command) }
        catch {
            guard outbox.pending.contains(where: { $0.id == command.id }) else { throw error }
            presentation.notice = .storagePending
            updateOperations(checkDeliveryClock: false)
            throw WatchWireError.pendingDurability(command.id)
        }
        updateOperations()
        // OS delivery is never an application ACK. A send failure leaves this same UUID pending.
        do { try transfer(command) } catch { presentation.notice = .unavailable }
        return command.id
    }
    private func transfer(_ command: WatchWireCommand, explicitRetry: Bool = false) throws {
        guard let outbox else { return }
        if explicitRetry {
            guard !outbox.requiresDurabilityRetry, outbox.binding?.libraryID == command.libraryID else { return }
        } else { guard outbox.mayDeliver(command, now: .now) else { return } }
        guard started, WCSession.default.activationState == .activated else { throw WatchWireError.unauthorized }
        let session = WCSession.default
        let key = "\(command.libraryID):\(command.epoch.uuidString):\(command.id.uuidString)"
        if session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["commandKey"] as? String == key }) { return }
        guard session.outstandingUserInfoTransfers.count < 256 else { throw WatchWireError.capacity }
        session.transferUserInfo(["wire": try WatchWirePacket.command(command).encoded(), "commandKey": key])
    }
    private func retryPending() {
        updateOperations()
        for command in outbox?.pending ?? [] {
            guard outbox?.mayDeliver(command, now: .now) == true else { continue }
            do { try transfer(command) } catch { presentation.notice = .unavailable; return }
        }
    }
    private func updateOperations(checkDeliveryClock: Bool = true) {
        guard let outbox else { return }
        if checkDeliveryClock {
            do { try outbox.updateDeliveryClock() }
            catch { presentation.notice = outbox.requiresDurabilityRetry ? .storagePending : .queueFailed }
        }
        presentation.drafts = outbox.drafts.map { WatchPresentedDraft(id: $0.id) }
        func kind(_ kind: WatchWireOperationKind) -> WatchPresentedOperation.Kind {
            switch kind { case .create: .create; case .append: .append; case .task: .task }
        }
        let now = Date()
        presentation.operations = outbox.pending.map { command in
            let delivery = outbox.delivery(for: command.id)
            let state: WatchOperationState
            if outbox.requiresDurabilityRetry { state = .waitingForStorage }
            else if delivery?.expired != false { state = .expired }
            else if outbox.binding?.libraryID != command.libraryID { state = .waitingForLibrary }
            else { state = .queued }
            return WatchPresentedOperation(id: command.id, kind: kind(command.kind), state: state,
                expiresAt: delivery?.expiresAt,
                deliveryDeadline: delivery.map { ContinuousClock.now.advanced(by: .seconds(max(0, $0.expiresAt.timeIntervalSince(now)))) },
                canRetryOriginal: outbox.binding?.libraryID == command.libraryID,
                canKeepDictation: command.kind != .task,
                absoluteExpiresAt: command.createdAt.addingTimeInterval(WatchWireCommand.maximumAge))
        }
        presentation.operations += outbox.completed.reversed().map { completed in
            let state: WatchOperationState
            switch completed.ack.result {
            case .applied: state = .applied
            case .appliedArchived: state = .appliedArchived
            case .appliedTrashed: state = .appliedTrashed
            case .refused(let refusal): state = .refused(Self.reason(refusal))
            }
            return WatchPresentedOperation(id: completed.ack.commandID, kind: kind(completed.kind), state: state)
        }
    }
    private static func reason(_ reason: WatchWireRefusal) -> WatchRefusalReason {
        switch reason {
        case .epochMismatch: .epochMismatch
        case .readOnly: .readOnly
        case .privacy: .privacy
        case .staleTarget: .staleTarget
        case .missingTarget: .missingTarget
        case .wrongLibrary: .wrongLibrary
        case .invalidCommand: .invalidCommand
        case .unavailable: .unavailable
        case .identifierReused: .identifierReused
        case .expired: .expired
        }
    }
    func receive(_ packet: WatchWirePacket, now: Date = .now) {
        do {
            switch packet {
            case .redact: invalidate(); presentation.notice = .privacy
            case .snapshot(let rawSnapshot):
                let snapshot = rawSnapshot.sanitizingTasks()
                if snapshot.redacted { invalidate(); presentation.notice = .privacy; return }
                guard foreground, presentation.isReachable, let helloDeadline, ContinuousClock.now < helloDeadline else {
                    invalidate(); return
                }
                try authorization.accept(snapshot, now: now)
                guard let outbox else { throw WatchWireError.storage }
                try outbox.bind(libraryID: snapshot.libraryID, epoch: snapshot.epoch)
                updateOperations()
                presentation.notes = authorization.visibleNotes(now: now).compactMap { note in
                    guard let id = UUID(uuidString: note.id) else { return nil }
                    return WatchPresentedNote(id: id, revision: note.revision, title: note.title, text: note.text,
                        tasks: note.tasks.map { task in
                            WatchPresentedTask(title: task.title, isChecked: task.isChecked,
                                target: WatchTaskTarget(noteID: id, revision: note.revision, utf16Offset: task.utf16Offset,
                                                        sourceSHA256: task.sourceSHA256, expectedMarker: task.expectedMarker))
                        })
                }
                let deadline = min(helloDeadline, ContinuousClock.now.advanced(by: .seconds(max(0, snapshot.expiresAt.timeIntervalSince(now)))))
                presentation.authorizationDeadline = deadline; presentation.isAuthorized = true; presentation.notice = nil
                scheduleExpiry(deadline: deadline, authorizationID: snapshot.authorizationID)
            case .ack(let ack):
                if let command = outbox?.pending.first(where: { $0.id == ack.commandID }), ack.matches(command),
                   case .refused(.privacy) = ack.result { invalidate(); presentation.notice = .privacy }
                if try outbox?.acknowledge(ack) == true {
                    updateOperations()
                    if case .refused(.privacy) = ack.result { invalidate(); presentation.notice = .privacy }
                }
            case .hello, .command: break
            }
        } catch {
            if case .snapshot = packet { invalidate() }
            presentation.notice = .unavailable
        }
    }
    private func receiveData(_ data: Data) {
        do { receive(try WatchWirePacket.decode(data)) } catch { presentation.notice = .unavailable }
    }
    func receiveEmptyContext() { invalidate(); presentation.notice = .unavailable }
    private func sessionChanged() {
        presentation.isReachable = WCSession.default.isReachable
        if !presentation.isReachable { invalidate() }
        else if foreground { refresh() }
        if WCSession.default.activationState == .activated { retryPending() }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor [weak self] in self?.sessionChanged() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.sessionChanged() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["transportReceived": true])
        guard let data = message["wire"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receiveData(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message["wire"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receiveData(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["wire"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receiveData(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if applicationContext.isEmpty {
            Task { @MainActor [weak self] in self?.receiveEmptyContext() }
        } else if let data = applicationContext["wire"] as? Data {
            Task { @MainActor [weak self] in self?.receiveData(data) }
        }
    }
}
