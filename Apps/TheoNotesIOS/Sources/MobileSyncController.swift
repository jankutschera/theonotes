// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import BackgroundTasks
import TheoNotesCore
import CryptoKit
import Foundation
import Observation
import UIKit

@MainActor @Observable
final class MobileSyncController {
    struct Device: Identifiable {
        let id: String
        let name: String
        let lastSeen: Date
        let current: Bool
    }
    static let endpoint = ReleaseFeatures.privateSyncEndpoint()
    private(set) var busy = false
    private(set) var syncing = false
    private(set) var connected = false
    private(set) var needsRecovery = false
    private(set) var waitingForNotePassword = false
    private(set) var recoveryWords: String?
    private(set) var pendingPairing: PendingSyncTransfer?
    private(set) var receivingInvitation: SyncTransferInvitation?
    private(set) var senderVerificationWords: String?
    private(set) var senderAwaitingConfirmation = false
    private(set) var receivingVerificationWords: String?
    @ObservationIgnored private var receivingChallenge: AccountKeys.TransferChallenge?
    @ObservationIgnored private var receivingWords: String?
    private(set) var pendingDeviceRequests: [SyncPendingTransferRequest] = []
    private(set) var pairingRequestError: String?
    @ObservationIgnored private var pairingRefreshRunning = false
    private(set) var ready = false
    private(set) var paused = false
    private(set) var status = "Sync is not connected"
    private(set) var lastSync: Date?
    private(set) var devices: [Device] = []
    private(set) var needsSeparateLibrary = false
    private(set) var preparedRecoveryLibrary: PreparedRecoveryLibrary?
    private(set) var isRecoveryLibrary = false
    @ObservationIgnored private var secretsVisible = false
    private(set) var recoveryNotice: String?
    var errorMessage: String?
    var deviceName = UIDevice.current.model
    @ObservationIgnored private weak var library: MobileLibrary?
    @ObservationIgnored private let keychain: KeychainSyncStore
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private let web = MobileWebAuthentication()
    @ObservationIgnored private var transport: HTTPSyncTransport?
    @ObservationIgnored private var blobs: SyncBlobTransfer?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var enrollment: SyncEnrollment?
    @ObservationIgnored private var scheduler: MobileSyncScheduler?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var automaticRunning = false
    @ObservationIgnored private var backgroundGrace: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var shouldContinueSoon = false
    @ObservationIgnored private var sendingTransfer: (code: String, package: AccountKeys.Transfer, words: String)?
    @ObservationIgnored private var receivingTask: Task<Void, Never>?

    init(library: MobileLibrary) {
        self.library = library
        isRecoveryLibrary = (try? SyncRecoveryLibrary.identity(paths: library.paths)) != nil
        preparedRecoveryLibrary = try? SyncRecoveryLibrary.preparedCopy(source: library.paths)
        namespace = Self.namespace(paths: library.paths)
        keychain = KeychainSyncStore(namespace: namespace)
        paused = UserDefaults.standard.bool(forKey: namespace + ".paused")
        recoveryNotice = UserDefaults.standard.string(forKey: namespace + ".recoveryNotice")
        // Reconnect the system session before authentication/network work on a background launch.
        _ = try? MobileBlobFiles.connect(directory: library.paths.root.appendingPathComponent("BackgroundCiphertext"))
        if paused { MobileBlobFiles.cancelAll() }
        scheduler = MobileSyncScheduler(controller: self, library: library)
    }
    private static func namespace(paths: AppPaths) -> String {
        if let id = try? SyncRecoveryLibrary.identity(paths: paths) { return "mobile.recovery." + id }
        return paths.root == AppPaths.production.root ? "mobile.production.v1" : "mobile.test." + SyncWire.hash(Data(paths.root.path.utf8))
    }
    static func hasSavedConnection(paths: AppPaths) -> Bool {
        UserDefaults.standard.bool(forKey: namespace(paths: paths) + ".connected")
    }

    func setActive(_ active: Bool) {
        setSensitivePresentation(active)
        guard !stopping else { return }
        if scheduler == nil, let library { scheduler = MobileSyncScheduler(controller: self, library: library) }
        scheduler?.setActive(active)
        if active { endBackgroundGrace() }
        else if automaticRunning, backgroundGrace == .invalid {
            backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "Finish encrypted sync") { [weak self] in
                Task { @MainActor in await self?.cancelAutomaticRun(); self?.endBackgroundGrace() }
            }
        }
    }

    func refreshAutomatically() async -> MobileSyncScheduler.Outcome {
        guard !stopping, !paused, !busy, receivingTask == nil, let library,
              !library.isClosed, !library.libraryOperationBusy else { return .deferred }
        busy = true; automaticRunning = true
        defer { busy = false; automaticRunning = false; endBackgroundGrace() }
        do {
            guard try await keychain.load() != nil else { return .needsUser }
            try await prepareTransport()
            if !ready { try await loadAccount() }
            guard ready else { return .needsUser }
            try await syncNow(automatic: true)
            if waitingForNotePassword { return .needsUser }
            errorMessage = nil
            return .success(pending: shouldContinueSoon && !waitingForNotePassword)
        } catch is CancellationError { return .deferred }
        catch SyncHTTPError.authenticationRequired {
            await discardBackgroundTransfers()
            ready = false; status = "Sign in again to reconnect sync"
            return .needsUser
        } catch SyncHTTPError.server(let statusCode, _, let retryAfter) {
            if statusCode == 401 { await discardBackgroundTransfers(); ready = false; status = "Sign in again to reconnect sync"; return .needsUser }
            status = statusCode == 429 ? "Sync will retry when the service is ready" : "Sync will retry automatically"
            return .failed(retryAfter: retryAfter)
        } catch {
            status = "Changes are saved here. Sync will retry automatically."
            return .failed(retryAfter: nil)
        }
    }

    func backgroundRefresh() async {
        defer { scheduler?.scheduleBackgroundRefresh() }
        await withTaskCancellationHandler {
            _ = await refreshAutomatically()
        } onCancel: { Task { @MainActor [weak self] in await self?.cancelAutomaticRun() } }
    }

    func cancelAutomaticRun() async {
        guard automaticRunning else { return }
        await engine?.cancelCurrentRun()
    }

    private func endBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace); backgroundGrace = .invalid
    }

    private func discardBackgroundTransfers() async {
        MobileBlobFiles.cancelAll()
        await engine?.shutdown(); engine = nil
        await blobs?.shutdown(); blobs = nil
    }

    func stopScheduling() { scheduler?.cancelScheduledWork() }

    /// Asks the system again for this sync's own background refresh (it shares the identifier with the iCloud sync, which withdraws
    /// the pending request when it is switched off). `scheduleBackgroundRefresh` itself checks that this sync is ready and not paused.
    func restoreBackgroundRefresh() { scheduler?.scheduleBackgroundRefresh() }

    func shutdown() async {
        stopping = true
        MobileBlobFiles.cancelAll()
        await scheduler?.stop(); scheduler = nil
        web.cancel()
        receivingTask?.cancel(); await receivingTask?.value; receivingTask = nil
        await enrollment?.shutdown(); enrollment = nil
        await engine?.shutdown(); engine = nil
        await blobs?.shutdown(); blobs = nil
        await transport?.shutdown(); transport = nil
        // Manual setup/recovery may still be unwinding its serialized operation.
        while busy { try? await Task.sleep(for: .milliseconds(10)) }
        endBackgroundGrace()
    }

    func resumeIfNeeded() async {
        guard !stopping, !busy, !paused, receivingTask == nil else { return }
        await perform {
            if self.ready { try await self.syncNow(automatic: true); return }
            guard try await self.keychain.load() != nil else { return }
            try await self.prepareTransport()
            try await self.loadAccount()
            if self.ready { try await self.syncNow(automatic: true) }
        }
    }

    func load() async {
        guard !busy, receivingTask == nil else { return }
        await perform {
            guard try await self.keychain.load() != nil else { return }
            try await self.prepareTransport()
            try await self.loadAccount()
            if self.ready { try await self.refreshDevices() }
        }
        // Existing-account devices request approval instead of presenting recovery entry.
        if needsRecovery && errorMessage == nil && receivingInvitation == nil && pendingPairing == nil {
            await beginReceiving()
        }
    }

    func signIn(create: Bool, setupCode: String) async {
        await perform {
            let identity = try await self.keychain.identity()
            let client = try SyncEnrollment(endpoint: Self.endpoint, deviceID: identity.id, signingKey: identity.signingKey,
                transferPublicKey: identity.transferKey.publicKey, credentials: self.keychain)
            self.enrollment = client
            self.status = "Waiting for passkey authentication"
            let flow = try await client.begin(create ? .register : .login, provisioningToken: create ? setupCode : nil)
            let callback = try await self.web.authenticate(at: flow.url)
            _ = try await client.finish(flow, callback: callback)
            await client.shutdown(); self.enrollment = nil
            try await self.prepareTransport()
            try await self.loadAccount()
            if self.ready { try await self.syncNow() }
        }
        // Existing-account devices request approval instead of presenting recovery entry.
        if needsRecovery && errorMessage == nil && receivingInvitation == nil && pendingPairing == nil {
            await beginReceiving()
        }
    }

    func recover(words: String) async {
        guard !busy, !stopping else { return }
        // Reject a mistyped backup before cancelling a usable connection request.
        do { _ = try RecoveryKey(words: words) }
        catch { errorMessage = "Check all 24 recovery words and their order."; return }
        if receivingTask != nil || receivingInvitation != nil || pendingPairing != nil {
            await cancelPairing()
            guard receivingTask == nil, receivingInvitation == nil, pendingPairing == nil else { return }
        }
        await perform {
            let recovery = try RecoveryKey(words: words)
            if try await self.keychain.load() == nil {
                let identity = try await self.keychain.identity()
                let client = try SyncEnrollment(endpoint: Self.endpoint, deviceID: identity.id, signingKey: identity.signingKey,
                    transferPublicKey: identity.transferKey.publicKey, credentials: self.keychain)
                self.enrollment = client
                let recovered = try await client.recover(words: words)
                try await self.keychain.saveAccount(recovered.keys, envelope: recovered.envelope)
                await client.shutdown(); self.enrollment = nil
                try await self.prepareTransport()
            } else {
                try await self.prepareTransport()
                guard let transport = self.transport else { throw SyncHTTPError.authenticationRequired }
                let envelope = try await transport.keyBundle().envelope
                let keys = try AccountKeys(recovery: recovery, envelope: envelope)
                if let old = try await self.keychain.account(),
                   old.keys.vaultKey.withUnsafeBytes({ Data($0) }) != keys.vaultKey.withUnsafeBytes({ Data($0) }),
                   let library = self.library,
                   try SyncQueue(database: library.database).isEnabled() || SyncQueue(database: library.database).hasRemoteState() {
                    throw SyncKeychainError.accountMismatch
                }
                try await self.keychain.saveAccount(keys, envelope: envelope)
            }
            try await self.loadAccount()
            try await self.syncNow()
        }
    }

    func setSensitivePresentation(_ visible: Bool) {
        secretsVisible = visible
        if !visible { recoveryWords = nil; senderVerificationWords = nil; receivingVerificationWords = nil }
        else { senderVerificationWords = sendingTransfer?.words; receivingVerificationWords = receivingWords }
    }

    func prepareRecoveryCopy() async {
        guard !busy else { return }
        await setPaused(true)
        await perform {
            guard let library = self.library else { throw CancellationError() }
            let archive = try await library.makeBackup()
            let source = library.paths
            let prepared = try await Task.detached(priority: .userInitiated) {
                try SyncRecoveryLibrary.prepare(source: source, archive: archive)
            }.value
            self.preparedRecoveryLibrary = prepared
            self.status = "Verified recovery library is ready. The original is kept and sync is paused."
        }
    }

    func openRecoveryCopy() async {
        guard !busy, let preparedRecoveryLibrary else { return }
        guard let library, !library.libraryOperationBusy, !library.isClosing, !library.voiceCaptureBusy else {
            errorMessage = BackupError.pendingFiles.localizedDescription
            return
        }
        do {
            try SyncRecoveryLibrary.select(preparedRecoveryLibrary)
            try await reopenSelectedLibrary(base: preparedRecoveryLibrary.base)
        } catch { errorMessage = error.localizedDescription }
    }

    private func reopenSelectedLibrary(base: AppPaths) async throws {
        NotificationCenter.default.post(name: SyncRecoveryLibrary.selectionDidChange, object: nil)
    }

    func returnToOriginalLibrary() async {
        guard !busy, let library else { return }
        guard !library.libraryOperationBusy, !library.isClosing, !library.voiceCaptureBusy else {
            errorMessage = BackupError.pendingFiles.localizedDescription
            return
        }
        await setPaused(true)
        // Pausing awaits active sync shutdown; recheck before changing persistent selection.
        guard !library.libraryOperationBusy, !library.isClosing, !library.voiceCaptureBusy else {
            errorMessage = BackupError.pendingFiles.localizedDescription
            return
        }
        do {
            let base = try SyncRecoveryLibrary.originalPaths(for: library.paths)
            try SyncRecoveryLibrary.selectOriginal(for: library.paths)
            try await reopenSelectedLibrary(base: base)
        } catch { errorMessage = error.localizedDescription }
    }

    private func setRecoveryNotice(_ message: String?) {
        recoveryNotice = message
        UserDefaults.standard.set(message, forKey: namespace + ".recoveryNotice")
    }

    func rotateRecoveryKey() async {
        await perform {
            guard self.ready, let transport = self.transport, let account = try await self.keychain.account() else {
                throw SyncHTTPError.authenticationRequired
            }
            let remote = try await transport.keyBundle()
            try await self.keychain.adoptRecoveryEnvelope(remote.envelope)
            let proposal = try PendingRecoveryRotation(keys: account.keys, previous: remote)
            try await self.keychain.stageRecoveryRotation(proposal)
            self.recoveryWords = self.secretsVisible ? proposal.words : nil
            self.ready = false
            self.status = "Save your new recovery key before activating it"
        }
    }

    static let movedStatus = "This library moved to iCloud"

    /// "Move This Library to iCloud" (MOVE-R1 to MOVE-R3): one final sync with the server, the check that nothing is left in either
    /// direction, a verified backup and the detach, all in `PrivateServerMove.run`; then this device signs out of the private server
    /// for this library (the sign-in and the account keys go from the Keychain, the device identity stays, the server's copy stays),
    /// so nothing reconnects or binds it again. Throws the reason when it cannot move; nothing has changed then. Mac twin:
    /// `MacSyncController.leaveForICloud`.
    /// `withoutMissingFiles`: the owner chose "Move to iCloud Without These Files…" after the refusal offered it (MOVE-R10).
    func leaveForICloud(withoutMissingFiles: Bool = false) async throws {
        guard !paused else { throw PrivateServerMoveRefusal.syncPaused }
        guard !busy, !stopping, receivingTask == nil else { throw PrivateServerMoveRefusal.syncRunning }
        busy = true
        do {
            scheduler?.setActive(false)    // no scheduled run during the move, as on the Mac
            if !ready, try await keychain.load() != nil { try await prepareTransport(); try await loadAccount() }
            guard ready, let engine, let library else { throw PrivateServerMoveRefusal.notConnected }
            status = "Syncing one last time before the move"
            try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: {
                try PrivateServerMove.requireFinished(try await library.synchronize(using: engine, notePassword: nil, remoteNotePassword: nil, exclusive: true))
            }, makeBackup: { try await MobileCloudSyncLibrary(library: library).makeBackup() }, withoutMissingFiles: withoutMissingFiles)
        } catch {
            busy = false
            if ready { status = "Ready to sync" }
            scheduler?.setActive(true)
            throw error
        }
        busy = false
        await signOut()
        status = Self.movedStatus
    }

    /// Preserve notes, encrypted ancestors and pending uploads. Reconnect must recover the
    /// same account keys; signing out is never a library reset or remote deletion.
    func signOut() async {
        guard !busy else { return }
        paused = true
        UserDefaults.standard.set(true, forKey: namespace + ".paused")
        await shutdown()
        do {
            try await keychain.clearAuthentication()
            connected = false; ready = false; needsRecovery = false; waitingForNotePassword = false
            recoveryWords = nil; pendingPairing = nil; receivingInvitation = nil
            senderVerificationWords = nil; sendingTransfer = nil; devices = []; lastSync = nil
            pendingDeviceRequests = []; pairingRequestError = nil
            senderAwaitingConfirmation = false
            receivingChallenge = nil; receivingWords = nil; receivingVerificationWords = nil
            paused = false
            UserDefaults.standard.set(false, forKey: namespace + ".connected")
            UserDefaults.standard.set(false, forKey: namespace + ".paused")
            status = "Signed out. Your notes remain on this device."
            errorMessage = nil
            setRecoveryNotice(nil)
        } catch { errorMessage = error.localizedDescription; status = "Sync paused. Sign out needs attention." }
        stopping = false
    }

    func confirmRecoverySaved() async {
        await perform {
            if try await self.keychain.pendingRecoveryRotation() != nil {
                guard let transport = self.transport else { throw SyncHTTPError.authenticationRequired }
                let proposal = try await self.keychain.confirmRecoveryRotationSaved()
                try await SyncRecoveryRotation.publish(proposal, using: transport)
                try await self.keychain.adoptRecoveryEnvelope(proposal.envelope)
                self.setRecoveryNotice(nil)
                self.recoveryWords = nil
                try await self.loadAccount()
                try await self.syncNow()
                return
            }
            try await self.keychain.confirmRecoverySaved()
            self.recoveryWords = nil
            try await self.loadAccount()
            try await self.syncNow()
        }
    }

    func restartReceiving() async {
        guard !busy, !stopping else { return }
        await cancelPairing()
        guard receivingInvitation == nil, pendingPairing == nil else { return }
        await beginReceiving()
    }

    func beginReceiving() async {
        guard receivingInvitation == nil, pendingPairing == nil, receivingTask == nil else { return }
        await perform {
            guard !self.ready, self.pendingPairing == nil, let library = self.library,
                  try !SyncQueue(database: library.database).hasRemoteState(),
                  try await self.keychain.account() == nil else { throw SyncKeychainError.invalidState }
            try await self.prepareTransport()
            guard let transport = self.transport else { throw SyncHTTPError.authenticationRequired }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let invitation = try await transport.startTransfer(publicKey: privateKey.publicKey)
            self.receivingInvitation = invitation
            self.receivingChallenge = nil; self.receivingWords = nil; self.receivingVerificationWords = nil
            self.status = "Approve this device in Theo Notes on your connected device"
            self.receivingTask = Task { [weak self] in
                guard let self else { return }
                defer { self.receivingTask = nil }
                do {
                    while !Task.isCancelled {
                        try invitation.validate()
                        if self.receivingChallenge == nil,
                           let challenge = try await transport.receiveTransferChallenge(invitation) {
                            let words = try AccountKeys.verificationWords(for: challenge, privateKey: privateKey)
                            try Task.checkCancellation()
                            self.receivingChallenge = challenge
                            self.receivingWords = words
                            self.receivingVerificationWords = self.secretsVisible ? words : nil
                            self.status = "Compare the six words, then approve on your connected device"
                        }
                        if let package = try await transport.receiveTransfer(invitation) {
                            // Pin the public transcript shown to the user before accepting its keys.
                            if let challenge = self.receivingChallenge, package.challenge != challenge {
                                throw SyncProtocolError.invalidPayload
                            }
                            let envelope = try await transport.keyBundle().envelope
                            let received = try AccountKeys.receive(package, privateKey: privateKey, envelope: envelope)
                            try Task.checkCancellation()
                            try await self.keychain.saveTransferredAccount(received.keys, envelope: envelope,
                                transferID: invitation.transferId, verificationWords: received.verificationWords,
                                expiresAt: package.expiresAt)
                            try Task.checkCancellation()
                            self.pendingPairing = try await self.keychain.pendingTransfer()
                            self.receivingInvitation = nil
                            self.receivingChallenge = nil; self.receivingWords = nil; self.receivingVerificationWords = nil
                            self.needsRecovery = false
                            self.status = "Compare all six words on both devices"
                            // Keys are already durable and inactive. A lost acknowledgment is safe.
                            try? await transport.acknowledgeTransfer(invitation.transferId)
                            return
                        }
                        try await Task.sleep(for: .seconds(3))
                    }
                } catch is CancellationError {} catch {
                    self.errorMessage = "Pairing stopped: " + error.localizedDescription
                    self.status = "Cancel and try pairing again"
                }
            }
        }
    }

    /// Discovery reveals only authenticated, short-lived requests for this account.
    /// It never releases an encryption key; the user must explicitly approve a request.
    func refreshPairingRequests() async {
        guard !stopping, ready, secretsVisible, let transport else {
            pendingDeviceRequests = []
            return
        }
        guard !busy, !pairingRefreshRunning else { return }
        pairingRefreshRunning = true
        defer { pairingRefreshRunning = false }
        do {
            let requests = try await transport.pendingTransferRequests()
            try Task.checkCancellation()
            guard !stopping, ready, secretsVisible, self.transport === transport else { return }
            pendingDeviceRequests = requests
            pairingRequestError = nil
        } catch is CancellationError {
            // The settings view stopped polling; keep any previously verified requests.
        } catch {
            guard !stopping, ready, secretsVisible, self.transport === transport else { return }
            pendingDeviceRequests = []
            pairingRequestError = "Connection requests could not be refreshed. Try again."
        }
    }

    func approvePairingRequest(_ request: SyncPendingTransferRequest) async {
        guard !busy, ready, secretsVisible, sendingTransfer == nil,
              pendingDeviceRequests.contains(where: { $0 == request }) else { return }
        await perform {
            guard let transport = self.transport, let account = try await self.keychain.account() else {
                throw SyncHTTPError.authenticationRequired
            }
            let invitation = request.invitation
            let code = try invitation.qrPayload(endpoint: Self.endpoint)
            guard invitation.accountId == account.keys.accountID else { throw SyncKeychainError.accountMismatch }
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: SyncWire.decode64(invitation.publicKey))
            let transfer = try account.keys.transfer(to: publicKey, transferID: invitation.transferId, expiresAt: invitation.expiration)
            self.sendingTransfer = (code, transfer.package, transfer.verificationWords)
            self.senderAwaitingConfirmation = true
            self.senderVerificationWords = self.secretsVisible ? transfer.verificationWords : nil
            // A discovered key is not trusted. Publish only public parameters until the
            // user authenticates this exact DH transcript by comparing both screens.
            try await transport.prepareTransfer(transfer.package.challenge)
        }
    }

    func confirmSendingTransfer() async {
        guard senderAwaitingConfirmation, secretsVisible, senderVerificationWords != nil else { return }
        await perform {
            guard self.ready, let transport = self.transport, let attempt = self.sendingTransfer else {
                throw SyncKeychainError.invalidState
            }
            self.senderAwaitingConfirmation = false
            try await transport.offerTransfer(attempt.package)
            self.pendingDeviceRequests.removeAll { $0.id == attempt.package.transferId }
        }
    }

    func sendPairingKey(code: String) async {
        // Manual QR transfer cannot bypass an outstanding direct-approval comparison.
        guard !senderAwaitingConfirmation else { return }
        await perform {
            guard self.ready, let transport = self.transport, let account = try await self.keychain.account() else {
                throw SyncHTTPError.authenticationRequired
            }
            let invitation = try SyncTransferInvitation.decodeQR(code.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: Self.endpoint)
            guard invitation.accountId == account.keys.accountID else { throw SyncKeychainError.accountMismatch }
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: SyncWire.decode64(invitation.publicKey))
            let transfer = try account.keys.transfer(to: publicKey, transferID: invitation.transferId, expiresAt: invitation.expiration)
            let attempt: (code: String, package: AccountKeys.Transfer, words: String)
            if let saved = self.sendingTransfer, saved.code == code { attempt = saved }
            else { attempt = (code, transfer.package, transfer.verificationWords); self.sendingTransfer = attempt }
            // Retain the exact transcript and words even if the response is lost.
            self.senderVerificationWords = self.secretsVisible ? attempt.words : nil
            try await transport.offerTransfer(attempt.package)
        }
    }

    func retrySendingTransfer() async {
        await perform {
            guard self.ready, let transport = self.transport, let attempt = self.sendingTransfer else {
                throw SyncKeychainError.invalidState
            }
            if self.senderAwaitingConfirmation {
                try await transport.prepareTransfer(attempt.package.challenge)
            } else {
                // A retry reuses exactly the transcript that the user already approved.
                try await transport.offerTransfer(attempt.package)
            }
        }
    }

    func clearSenderWords() {
        senderVerificationWords = nil; sendingTransfer = nil; senderAwaitingConfirmation = false
    }

    func confirmPairing() async {
        await perform {
            guard let pending = try await self.keychain.pendingTransfer() else { throw SyncKeychainError.invalidState }
            try await self.keychain.confirmTransferredAccount()
            self.pendingPairing = nil
            try? await self.transport?.acknowledgeTransfer(pending.transferID)
            try await self.loadAccount()
            try await self.syncNow()
        }
    }

    func cancelPairing() async {
        guard !busy else { return }
        busy = true
        let invitationID = receivingInvitation?.transferId ?? pendingPairing?.transferID
        let task = receivingTask
        task?.cancel()
        await task?.value
        do {
            try await keychain.discardUnconfirmedTransfer()
            pendingPairing = nil; receivingInvitation = nil; needsRecovery = connected && !ready
            receivingChallenge = nil; receivingWords = nil; receivingVerificationWords = nil
            status = "Pairing cancelled"
            if let invitationID { try? await transport?.acknowledgeTransfer(invitationID) }
        } catch { errorMessage = error.localizedDescription }
        busy = false
    }

    #if DEBUG
    @ObservationIgnored private var pauseFixtureStarted = false

    /// The disposable UI-test library bound to the private server as a finished sync leaves it (account, uploads on), with no sign-in
    /// and no network: Settings ▸ iCloud then shows the move (MOVE-R1). Used for the evidence screenshots only.
    func runPrivateServerUITestFixtureIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--private-server-fixture"), let library,
              library.paths.root.lastPathComponent == "TheoNotesUITests", library.paths.root != AppPaths.production.root else { return }
        stopScheduling()
        do {
            try SyncQueue(database: library.database).enable(accountID: "ui-test-private-server")
            // `--moved-fixture`: the same library right after a finished move (backend none, the notice showing).
            if arguments.contains("--moved-fixture") {
                let backup = LibraryBackup(database: library.database, paths: library.paths)
                let archive = try backup.createRolling()
                guard let id = try backup.catalogID(of: archive) else { throw SyncAccountDetachError.backupNotVerified }
                try PrivateServerMove.leave(database: library.database, verifiedBackupID: id)
            }
        } catch { errorMessage = "The private-server fixture could not start." }
    }

    /// Real exclusive merge and real pause action, with no enrollment or network dependency.
    func runPauseUITestFixtureIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--sync-pause-fixture"),
              !pauseFixtureStarted, !busy, let library,
              library.paths.root.lastPathComponent == "TheoNotesUITests",
              library.paths.root != AppPaths.production.root else { return }
        pauseFixtureStarted = true
        stopScheduling()
        paused = false
        UserDefaults.standard.set(false, forKey: namespace + ".paused")
        busy = true; syncing = true
        defer { busy = false; syncing = false }
        do {
            let accountID = "ui-test-pause-account"
            try SyncQueue(database: library.database).configure(accountID: accountID)
            let fixture = MobilePauseUITestTransport()
            let engine = SyncEngine(database: library.database, paths: library.paths,
                                    accountID: accountID, vaultKey: SymmetricKey(data: Data(repeating: 7, count: 32)),
                                    transport: fixture, blobs: fixture,
                                    coordinator: MobileSyncCommitCoordinator(library: library))
            self.engine = engine
            status = "Initial sync fixture is waiting"
            _ = try await library.synchronize(using: engine, exclusive: true)
        } catch is CancellationError {
            status = paused ? "Sync paused" : "Sync cancelled"
        } catch {
            errorMessage = "The isolated sync fixture could not start."
        }
    }
    #endif

    func synchronize() async {
        await perform { try await self.syncNow() }
    }

    func resolveProtectedChanges(password: String, newPassword: String) async {
        await perform { try await self.syncNow(notePassword: password, remoteNotePassword: newPassword.isEmpty ? password : newPassword) }
    }

    /// Pause an in-flight sync without waiting for the ordinary busy-operation gate.
    func pauseCurrentSync() async {
        guard syncing else { return }
        paused = true
        shouldContinueSoon = false
        UserDefaults.standard.set(true, forKey: namespace + ".paused")
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MobileSyncScheduler.refreshIdentifier)
        status = "Pausing sync safely"
        repeat {
            await engine?.cancelCurrentRun()
            // Exclusive setup can still be awaiting OCR before the engine starts.
            // Keep cancellation armed until that setup or the backup has unwound.
            if syncing { try? await Task.sleep(for: .milliseconds(50)) }
        } while syncing
        status = "Sync paused"
    }

    func setPaused(_ value: Bool) async {
        guard !busy else { return }
        paused = value
        if value {
            MobileBlobFiles.cancelAll()
            await engine?.shutdown(); engine = nil
            await blobs?.shutdown(); blobs = nil
            ready = false
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MobileSyncScheduler.refreshIdentifier)
        }
        UserDefaults.standard.set(value, forKey: namespace + ".paused")
        status = value ? "Sync paused" : "Ready to sync"
        if !value {
            if !ready { await resumeIfNeeded() }
            else { await synchronize() }
            scheduler?.request()
        }
    }

    func renameDevice() async {
        await perform {
            guard let transport = self.transport, let account = try await self.keychain.account() else { throw SyncHTTPError.authenticationRequired }
            let identity = try await self.keychain.identity()
            try await transport.renameDevice(self.deviceName, accountID: account.keys.accountID, deviceID: identity.id, vaultKey: account.keys.vaultKey)
            try await self.refreshDevices()
        }
    }

    func revoke(_ id: String) async {
        await perform {
            guard let transport = self.transport else { throw SyncHTTPError.authenticationRequired }
            let identity = try await self.keychain.identity()
            guard id != identity.id else { throw SyncProtocolError.invalidPayload }
            try await transport.revokeDevice(id)
            try await self.refreshDevices()
        }
    }

    private func prepareTransport() async throws {
        guard !stopping else { throw CancellationError() }
        if transport == nil {
            let identity = try await keychain.identity()
            guard !stopping else { throw CancellationError() }
            transport = try HTTPSyncTransport(endpoint: Self.endpoint, signingKey: identity.signingKey, credentials: keychain)
        }
        connected = try await keychain.load() != nil
        UserDefaults.standard.set(connected, forKey: namespace + ".connected")
    }

    private func loadAccount() async throws {
        guard !stopping else { throw CancellationError() }
        // A move that stopped between the detach and the sign-out finishes here: the library never binds again (MOVE-R3).
        if let library, try PrivateServerMove.hasLeft(library.database) {
            try await keychain.clearAuthentication()
            UserDefaults.standard.set(false, forKey: namespace + ".connected")
            connected = false; ready = false; status = Self.movedStatus
            return
        }
        guard let transport, let credentials = try await keychain.load() else { throw SyncHTTPError.authenticationRequired }
        if let pending = try await keychain.pendingTransfer() {
            if pending.expiresAt <= Int64(Date.now.timeIntervalSince1970 * 1000) {
                try await keychain.discardUnconfirmedTransfer()
                pendingPairing = nil
            } else {
                pendingPairing = pending; ready = false; needsRecovery = false; recoveryWords = nil
                status = "Compare all six words on both devices"
                return
            }
        }
        var remote: SyncKeyBundle?
        do { remote = try await transport.keyBundle() }
        catch SyncHTTPError.server(status: 404, code: "keys_not_initialized", retryAfter: _) {}
        var saved = try await keychain.account()
        if remote == nil {
            // A signed account can resume initialization after a crash between passkey grant
            // persistence and key creation. The server CAS selects one initializer.
            if let library, try SyncQueue(database: library.database).hasRemoteState() { throw SyncKeychainError.invalidState }
            if saved == nil {
                let keys = try AccountKeys(accountID: credentials.accountId), recovery = RecoveryKey()
                let envelope = try keys.envelope(recovery: recovery)
                // Persist the only recoverable key before publishing its envelope.
                try await keychain.saveAccount(keys, envelope: envelope, pendingRecoveryWords: recovery.words())
                saved = try await keychain.account()
            }
            guard let saved else { throw SyncKeychainError.invalidState }
            _ = try await transport.writeKeyEnvelope(saved.envelope, parentRevision: 0)
            remote = try await transport.keyBundle()
        }
        if let fetched = remote, let proposal = try await keychain.pendingRecoveryRotation() {
            if fetched.envelope == proposal.envelope {
                try await keychain.adoptRecoveryEnvelope(fetched.envelope)
                setRecoveryNotice(nil)
            } else if fetched.revision != proposal.parentRevision || fetched.envelope != proposal.previousEnvelope {
                try await keychain.discardRecoveryRotation()
                setRecoveryNotice(RecoveryRotationError.superseded.localizedDescription)
            } else if proposal.confirmed {
                try await SyncRecoveryRotation.publish(proposal, using: transport)
                try await keychain.adoptRecoveryEnvelope(proposal.envelope)
                setRecoveryNotice(nil)
                remote = try await transport.keyBundle()
            } else {
                recoveryWords = secretsVisible ? proposal.words : nil; ready = false; needsRecovery = false
                status = "Save your new recovery key before activating it"
                return
            }
            saved = try await keychain.account()
        }
        if let current = saved, let fetched = remote, current.envelope != fetched.envelope {
            // Recovery-phrase rotation keeps the account master and content key. A different
            // master/vault fails authentication here and still requires explicit recovery.
            if (try? await keychain.adoptRecoveryEnvelope(fetched.envelope)) != nil {
                if recoveryNotice == nil { setRecoveryNotice("The recovery key was replaced on another device. Use the newest 24 words for account recovery.") }
                saved = try await keychain.account()
            }
        }
        guard let saved, saved.envelope == remote?.envelope else {
            needsRecovery = true; ready = false; recoveryWords = nil
            status = "Approve this device from a connected device to start sync"
            return
        }
        needsRecovery = false; recoveryWords = secretsVisible ? saved.pendingRecoveryWords : nil
        guard saved.pendingRecoveryWords == nil else { ready = false; status = "Save your recovery key"; return }
        guard !stopping, let library, !library.isClosed else { throw CancellationError() }
        try SyncQueue(database: library.database).configure(accountID: saved.keys.accountID)
        if engine == nil {
            let identity = try await keychain.identity()
            let files = try MobileBlobFiles.connect(directory: library.paths.root.appendingPathComponent("BackgroundCiphertext"),
                identity: saved.keys.accountID + ":" + identity.id)
            let transfer = SyncBlobTransfer(database: library.database, paths: library.paths, transport: transport, files: files)
            blobs = transfer
            engine = SyncEngine(database: library.database, paths: library.paths, accountID: saved.keys.accountID,
                                vaultKey: saved.keys.vaultKey, transport: transport, blobs: transfer,
                                coordinator: MobileSyncCommitCoordinator(library: library))
        }
        ready = true
        status = paused ? "Sync paused" : "Ready to sync"
        if scheduler == nil { scheduler = MobileSyncScheduler(controller: self, library: library) }
        scheduler?.scheduleBackgroundRefresh()
    }

    private func syncNow(notePassword: String? = nil, remoteNotePassword: String? = nil, automatic: Bool = false) async throws {
        guard !paused else { status = "Sync paused"; return }
        guard ready, let engine, let library, let account = try await keychain.account() else { return }
        syncing = true
        defer {
            syncing = false
            if paused { status = "Sync paused" }
        }
        func runSync() async throws {
            let queue = SyncQueue(database: library.database)
            var recoveredPendingVault = false
            var unopenableLockedNotes = 0
            if library.awaitsMissingJournalSyncKey {
                guard let password = notePassword, !password.isEmpty else {
                    if try await engine.pendingNoteVaultIsAbsent() {
                        try library.offerSealedJournalMoveAside()
                        waitingForNotePassword = false
                        status = "The notes key is not available yet. Keep sync on, or use the recovery notice to move the files aside unchanged."
                    } else {
                        waitingForNotePassword = true
                        status = "A recovered edit needs the notes key from sync. Enter your notes password to continue."
                    }
                    return
                }
                status = "Fetching the notes key without changing your notes"
                var vaultMissing = false
                let installed = try await library.recoverPendingSyncKey(
                    scan: {
                        let found = try await engine.scanPendingNoteVault(password: password)
                        vaultMissing = found == nil
                        return found
                    },
                    install: { found in
                        let installed = try await engine.installPendingNoteVault(found)
                        if installed { unopenableLockedNotes = try await engine.unopenableLockedNoteCount(for: found) }
                        return installed
                    })
                guard installed else {
                    if vaultMissing { try library.offerSealedJournalMoveAside() }
                    waitingForNotePassword = !vaultMissing
                    status = vaultMissing
                        ? "The notes key is not available yet. Keep sync on, or use the recovery notice to move the files aside unchanged."
                        : "The notes key is not available yet. Try again when the other device has synced."
                    return
                }
                try await library.unlockNotes(password: password)
                recoveredPendingVault = true
                waitingForNotePassword = false
                if try queue.isEnabled() {
                    status = unopenableLockedNotes > 0 ? VaultIntakeLockedNotesMismatch.partialMessage(count: unopenableLockedNotes) : (library.recoveredJournalNotices.isEmpty
                        ? "Review the recovery notice before syncing again."
                        : "A recovery note is saved. Review the recovery notice before syncing again.")
                    return
                }
            }
            if try !queue.isEnabled() {
                // Recover protected journals before the first-sync safety snapshot as well.
                if let notePassword, !recoveredPendingVault { try await library.unlockNotes(password: notePassword) }
                status = "Saving a backup before the first sync"
                _ = try await library.makeBackup()
            }
            guard !paused else { status = "Sync paused"; return }
            status = "Syncing your notes"
            let requiresExclusive = try !queue.isEnabled() || notePassword != nil || remoteNotePassword != nil
            var summary = try await library.synchronize(using: engine, notePassword: notePassword, remoteNotePassword: remoteNotePassword, exclusive: requiresExclusive)
            guard !paused else { status = "Sync paused"; return }
            if summary.passwordRefreshRequired {
                guard let password = remoteNotePassword ?? notePassword else { throw NotePrivacyError.accessRevoked }
                summary = try await library.synchronize(using: engine, notePassword: password, remoteNotePassword: password, exclusive: true)
                guard !paused else { status = "Sync paused"; return }
            }
            if try !queue.isEnabled(), try queue.canEnableAfterInitialDownload(summary) {
                try queue.enable(accountID: account.keys.accountID)
                guard !paused else { status = "Sync paused"; return }
                summary = try await library.synchronize(using: engine, notePassword: notePassword, remoteNotePassword: remoteNotePassword,
                                                        exclusive: notePassword != nil || remoteNotePassword != nil)
                guard !paused else { status = "Sync paused"; return }
            }
            shouldContinueSoon = summary.shouldContinueSoon
            lastSync = .now
            waitingForNotePassword = summary.waitingForUnlock > 0
            status = Self.statusText(for: summary)
            if unopenableLockedNotes > 0 { status += " " + VaultIntakeLockedNotesMismatch.partialMessage(count: unopenableLockedNotes) }
            try await refreshDevices()
        }
        do { try await runSync() }
        catch {
            if notePassword != nil { try? await library.lockVaultAfterDraining() }
            throw error
        }
        if notePassword != nil { try await library.lockVaultAfterDraining() }
    }

    static func statusText(for summary: SyncRunSummary) -> String {
        var messages: [String] = []
        if summary.waitingForUnlock > 0 {
            messages.append(summary.waitingForUnlock == 1
                ? "1 encrypted change needs your note password"
                : "\(summary.waitingForUnlock) encrypted changes need your note password")
        } else if summary.pendingDownloads > 0 || summary.pendingUploads > 0 {
            messages.append("\(summary.pendingUploads) uploads and \(summary.pendingDownloads) downloads waiting")
        }
        if summary.deferredConflicts > 0 {
            let count = summary.deferredConflicts
            messages.append(count == 1
                ? "1 edit waiting to merge"
                : "\(count) edits waiting to merge")
        }
        if summary.unavailableAttachments > 0 {
            let count = summary.unavailableAttachments
            messages.append(count == 1
                ? "1 attachment is unavailable on this device"
                : "\(count) attachments are unavailable on this device")
        }
        return messages.isEmpty ? "All notes are up to date" : messages.joined(separator: ". ")
    }

    private func refreshDevices() async throws {
        guard let transport, let account = try await keychain.account() else { return }
        let identity = try await keychain.identity()
        let fetched = try await transport.devices()
        devices = try fetched.filter { $0.revokedAt == nil }.map {
            Device(id: $0.id, name: try $0.name(accountID: account.keys.accountID, vaultKey: account.keys.vaultKey) ?? "Unnamed device",
                   lastSeen: Date(timeIntervalSince1970: Double($0.lastSeen) / 1000), current: $0.id == identity.id)
        }
        if let own = devices.first(where: \.current), own.name != "Unnamed device" { deviceName = own.name }
        else {
            try await transport.renameDevice(deviceName, accountID: account.keys.accountID, deviceID: identity.id, vaultKey: account.keys.vaultKey)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !stopping, !busy, receivingTask == nil else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError { status = paused ? "Sync paused" : "Sync cancelled" }
        catch {
            if let enrollment { await enrollment.shutdown(); self.enrollment = nil }
            switch error {
            case SyncNotePasswordError.differentVaults:
                needsSeparateLibrary = true
                errorMessage = "The published libraries use different note-password encryption keys. Create a separate recovery library to reconcile safely; the original and pending changes are kept."
            case SyncHTTPError.server(let code, _, _) where code == 429:
                errorMessage = "The sync service is busy. Your changes are saved here; try again shortly."
            case SyncHTTPError.authenticationRequired:
                await discardBackgroundTransfers()
                ready = false; errorMessage = "Sign in again with your passkey to reconnect this device."
            case AccountKeyError.invalidRecoveryKey, AccountKeyError.invalidEnvelope:
                errorMessage = "That recovery key does not unlock this account. Check all 24 words."
            case CryptoError.wrongPassword:
                errorMessage = "That note password did not unlock the protected notes. Please try again."
            case NotePrivacyError.accessRevoked:
                errorMessage = "Protected-note access ended. Enter your note password again to continue."
            default: errorMessage = error.localizedDescription
            }
            status = "Sync needs attention"
        }
    }
}

#if DEBUG
/// An indefinitely gated pull that only the actual engine cancellation can release.
/// Constructed solely by the explicitly opted-in isolated UI fixture above.
private actor MobilePauseUITestTransport: SyncTransport, SyncBlobTransport {
    private var waiter: CheckedContinuation<SyncPullResult, any Error>?
    private var cancelled = false

    func pull(after cursor: Int64) async throws -> SyncPullResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: {
            Task { await self.cancelPull() }
        }
    }

    private func cancelPull() {
        cancelled = true
        let pending = waiter
        waiter = nil
        pending?.resume(throwing: CancellationError())
    }

    func push(_ mutations: [SyncMutation]) async throws -> SyncPushResult { throw CancellationError() }
    func acknowledge(_ cursor: Int64) async throws { throw CancellationError() }
    func ensureUploaded(_ hashes: [String]) async throws { throw CancellationError() }
    func download(hash: String) async throws -> URL { throw CancellationError() }
}
#endif
