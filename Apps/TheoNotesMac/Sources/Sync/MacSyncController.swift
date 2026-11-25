// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import CryptoKit
import Foundation
import Observation
import AppKit

/// Everything through which sync reaches the Keychain, the network, the scheduler or the shared
/// defaults. The app uses `live`; tests inject spies. A local-only controller calls none of them.
struct MacSyncServices {
    var defaults: UserDefaults
    var credentials: @MainActor (_ namespace: String) throws -> KeychainSyncStore
    var transport: @MainActor (_ identity: SyncDeviceIdentity, _ credentials: KeychainSyncStore) throws -> HTTPSyncTransport
    var enrollment: @MainActor (_ identity: SyncDeviceIdentity, _ credentials: KeychainSyncStore) throws -> SyncEnrollment
    var engine: @MainActor (_ library: AppEnvironment, _ account: StoredSyncAccount, _ transport: HTTPSyncTransport) throws
        -> (blobs: SyncBlobTransfer, engine: SyncEngine)
    var scheduler: @MainActor (_ controller: MacSyncController, _ library: AppEnvironment) -> MacSyncScheduler?

    static var live: MacSyncServices {
        MacSyncServices(
            defaults: .standard,
            credentials: { KeychainSyncStore(namespace: $0) },
            transport: { identity, credentials in
                try HTTPSyncTransport(endpoint: MacSyncController.endpoint, signingKey: identity.signingKey, credentials: credentials)
            },
            enrollment: { identity, credentials in
                try SyncEnrollment(endpoint: MacSyncController.endpoint, deviceID: identity.id, signingKey: identity.signingKey,
                                   transferPublicKey: identity.transferKey.publicKey, credentials: credentials)
            },
            engine: { library, account, transport in
                let blobs = SyncBlobTransfer(database: library.database, paths: library.paths, transport: transport)
                let engine = SyncEngine(database: library.database, paths: library.paths, accountID: account.keys.accountID,
                                        vaultKey: account.keys.vaultKey, transport: transport, blobs: blobs,
                                        coordinator: MacSyncCommitCoordinator(environment: library))
                return (blobs, engine)
            },
            scheduler: { MacSyncScheduler(controller: $0, library: $1) })
    }
}

/// Thrown by every credential or transport path of a local-only library (INT-R14).
struct SyncOffForLibraryCopy: Error {}

@MainActor @Observable
final class MacSyncController {
    struct Device: Identifiable {
        let id: String
        let name: String
        let lastSeen: Date
        let current: Bool
    }
    static let endpoint = ReleaseFeatures.privateSyncEndpoint()
    private(set) var busy = false
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
    var deviceName = Host.current().localizedName ?? "Mac"
    @ObservationIgnored private weak var library: AppEnvironment?
    /// Fixed for the process at launch (INT-R14); a `localOnly` library never syncs.
    let policy: SyncLaunchPolicy
    /// False in a build made for the public (REL-R4): the controller then behaves like a local-only one,
    /// never reaching the Keychain, the network or the scheduler, and says so in `status`.
    let available: Bool
    var isUnavailable: Bool { !available }
    var isLocalOnly: Bool { policy == .localOnly || !available }
    @ObservationIgnored private let services: MacSyncServices
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var credentialStore: KeychainSyncStore?
    @ObservationIgnored private var web: MacWebAuthentication?
    @ObservationIgnored private var transport: HTTPSyncTransport?
    @ObservationIgnored private var blobs: SyncBlobTransfer?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var enrollment: SyncEnrollment?
    @ObservationIgnored private var scheduler: MacSyncScheduler?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var automaticRunning = false
    @ObservationIgnored private var shouldContinueSoon = false
    @ObservationIgnored private var sendingTransfer: (code: String, package: AccountKeys.Transfer, words: String)?
    @ObservationIgnored private var receivingTask: Task<Void, Never>?
    /// Above 0, no run starts (M9M-R77): the Note Password reset holds the barrier while it works.
    @ObservationIgnored private var quiesceDepth = 0

    init(library: AppEnvironment, policy: SyncLaunchPolicy, available: Bool = true, services: MacSyncServices = .live) {
        self.library = library
        self.policy = policy
        self.available = available
        self.services = services
        // A build without the sync setup reads nothing either: the saved connection stays where it is.
        guard available else {
            namespace = ""
            status = Self.unavailableStatus
            return
        }
        // A library copy reads no recovery marker, saved connection or pause flag: nothing in
        // its folder or in the shared defaults can turn sync back on.
        guard policy == .enabled else {
            namespace = ""
            status = Self.localOnlyStatus
            return
        }
        isRecoveryLibrary = (try? SyncRecoveryLibrary.identity(paths: library.paths)) != nil
        preparedRecoveryLibrary = try? SyncRecoveryLibrary.preparedCopy(source: library.paths)
        namespace = Self.namespace(paths: library.paths)
        paused = services.defaults.bool(forKey: namespace + ".paused")
        recoveryNotice = services.defaults.string(forKey: namespace + ".recoveryNotice")
    }

    static let localOnlyStatus = "Sync is off for this library copy"
    /// What any remaining sync entry point answers in a build without the sync setup (REL-R6).
    static let unavailableStatus = "Sync is not available in this version"

    /// The credential store, made on first use.
    private var keychain: KeychainSyncStore {
        get throws {
            guard !isLocalOnly else { throw SyncOffForLibraryCopy() }
            if let credentialStore { return credentialStore }
            let store = try services.credentials(namespace)
            credentialStore = store
            return store
        }
    }
    private static func namespace(paths: AppPaths) -> String {
        if let id = try? SyncRecoveryLibrary.identity(paths: paths) { return "mac.recovery." + id }
        return AppPaths.isRealLibrary(paths.root) ? "mac.production.v1" : "mac.test." + SyncWire.hash(Data(paths.root.path.utf8))
    }

    func setActive(_ active: Bool) {
        guard !isLocalOnly else { return }
        setSensitivePresentation(active && NSApp.isActive)
        guard !stopping else { return }
        if scheduler == nil, let library { scheduler = services.scheduler(self, library) }
        scheduler?.setActive(active)
    }

    /// Blocks new runs, cancels the one that is going and waits until nothing is running (M9M-R77).
    /// False when something still runs after `timeout`. Calls nest and every call, whatever it
    /// answers, is balanced by one `endQuiesce()`.
    func quiesce(timeout: Duration = .seconds(30)) async -> Bool {
        quiesceDepth += 1
        scheduler?.setActive(false)
        await engine?.cancelCurrentRun()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while busy || automaticRunning || receivingTask != nil {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func endQuiesce() {
        quiesceDepth = max(0, quiesceDepth - 1)
        if quiesceDepth == 0 { setActive(true) }
    }

    func refreshAutomatically() async -> MacSyncScheduler.Outcome {
        guard !isLocalOnly else { return .needsUser }
        guard quiesceDepth == 0 else { return .deferred }
        guard !stopping, !paused, !busy, receivingTask == nil, let library,
              !library.syncClosed else { return .deferred }
        busy = true; automaticRunning = true
        defer { busy = false; automaticRunning = false }
        do {
            guard try await keychain.load() != nil else { return .needsUser }
            try await prepareTransport()
            if !ready { try await loadAccount() }
            guard ready else { return .needsUser }
            try await syncNow(automatic: true)
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

    func cancelAutomaticRun() async {
        guard automaticRunning else { return }
        await engine?.cancelCurrentRun()
    }

    private func discardBackgroundTransfers() async {
        await engine?.shutdown(); engine = nil
        await blobs?.shutdown(); blobs = nil
    }

    func stopScheduling() { scheduler?.cancelScheduledWork() }

    func shutdown() async {
        stopping = true
        await scheduler?.stop(); scheduler = nil
        web?.cancel()
        receivingTask?.cancel(); await receivingTask?.value; receivingTask = nil
        await enrollment?.shutdown(); enrollment = nil
        await engine?.shutdown(); engine = nil
        await blobs?.shutdown(); blobs = nil
        await transport?.shutdown(); transport = nil
        // Manual setup/recovery may still be unwinding its serialized operation.
        while busy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func resumeIfNeeded() async {
        guard !isLocalOnly else { return }
        guard !stopping, !busy, !paused, receivingTask == nil, quiesceDepth == 0 else { return }
        await perform {
            if self.ready { try await self.syncNow(automatic: true); return }
            guard try await self.keychain.load() != nil else { return }
            try await self.prepareTransport()
            try await self.loadAccount()
            if self.ready { try await self.syncNow(automatic: true) }
        }
    }

    func load() async {
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
        await perform {
            let identity = try await self.keychain.identity()
            let client = try self.services.enrollment(identity, self.keychain)
            self.enrollment = client
            self.status = "Waiting for passkey authentication"
            let flow = try await client.begin(create ? .register : .login, provisioningToken: create ? setupCode : nil)
            let web = self.web ?? MacWebAuthentication()
            self.web = web
            let callback = try await web.authenticate(at: flow.url)
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
        guard !isLocalOnly else { return }
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
                let client = try self.services.enrollment(identity, self.keychain)
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
        guard !busy, let preparedRecoveryLibrary else { return }
        do {
            try SyncRecoveryLibrary.select(preparedRecoveryLibrary)
            try await reopenSelectedLibrary(base: preparedRecoveryLibrary.base)
        } catch { errorMessage = error.localizedDescription }
    }

    private func reopenSelectedLibrary(base: AppPaths) async throws {
        // A unit test must never start a second app instance or quit its host.
        guard !isRunningUnitTests else { throw CancellationError() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = AppPaths.isRealLibrary(base.root) ? [] : [AppPaths.dataDirArgument, base.root.path]
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    func returnToOriginalLibrary() async {
        guard !isLocalOnly else { return }
        guard !busy, let library else { return }
        await setPaused(true)
        do {
            let base = try SyncRecoveryLibrary.originalPaths(for: library.paths)
            try SyncRecoveryLibrary.selectOriginal(for: library.paths)
            try await reopenSelectedLibrary(base: base)
        } catch { errorMessage = error.localizedDescription }
    }

    private func setRecoveryNotice(_ message: String?) {
        recoveryNotice = message
        services.defaults.set(message, forKey: namespace + ".recoveryNotice")
    }

    func rotateRecoveryKey() async {
        guard !isLocalOnly else { return }
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
    /// direction, a verified backup and the detach, all in `PrivateServerMove.run`; then this Mac signs out of the private server for
    /// this library (the sign-in and the account keys go from the Keychain, the device identity stays, the server's copy stays), so
    /// nothing reconnects or binds it again. Throws the reason when it cannot move; nothing has changed then.
    /// `withoutMissingFiles`: the owner chose "Move to iCloud Without These Files…" after the refusal offered it (MOVE-R10).
    func leaveForICloud(withoutMissingFiles: Bool = false) async throws {
        guard !isLocalOnly else { throw SyncOffForLibraryCopy() }
        guard !paused else { throw PrivateServerMoveRefusal.syncPaused }
        guard !busy, !stopping, receivingTask == nil, quiesceDepth == 0 else { throw PrivateServerMoveRefusal.syncRunning }
        busy = true
        do {
            scheduler?.setActive(false)
            if !ready, try await keychain.load() != nil { try await prepareTransport(); try await loadAccount() }
            guard ready, let engine, let library else { throw PrivateServerMoveRefusal.notConnected }
            status = "Syncing one last time before the move"
            try await PrivateServerMove.run(database: library.database, paths: library.paths, finalSync: {
                try PrivateServerMove.requireFinished(try await library.synchronize(using: engine, notePassword: nil, remoteNotePassword: nil, exclusive: true))
            }, makeBackup: { try await MacCloudSyncLibrary(environment: library).makeBackup() }, withoutMissingFiles: withoutMissingFiles)
        } catch {
            busy = false
            status = ready ? "Ready to sync" : status
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
        guard !isLocalOnly else { return }
        guard !busy else { return }
        paused = true
        services.defaults.set(true, forKey: namespace + ".paused")
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
            services.defaults.set(false, forKey: namespace + ".connected")
            services.defaults.set(false, forKey: namespace + ".paused")
            status = "Signed out. Your notes remain on this device."
            errorMessage = nil
            setRecoveryNotice(nil)
        } catch { errorMessage = error.localizedDescription; status = "Sync paused. Sign out needs attention." }
        stopping = false
    }

    func confirmRecoverySaved() async {
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
        guard !busy, !stopping else { return }
        await cancelPairing()
        guard receivingInvitation == nil, pendingPairing == nil else { return }
        await beginReceiving()
    }

    func beginReceiving() async {
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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
        guard !isLocalOnly else { return }
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

    func synchronize() async {
        guard !isLocalOnly else { return }
        await perform { try await self.syncNow() }
    }

    func resolveProtectedChanges(password: String, newPassword: String) async {
        guard !isLocalOnly else { return }
        await perform { try await self.syncNow(notePassword: password, remoteNotePassword: newPassword.isEmpty ? password : newPassword) }
    }

    func setPaused(_ value: Bool) async {
        guard !isLocalOnly else { return }
        guard !busy else { return }
        paused = value
        if value { await engine?.cancelCurrentRun() }
        services.defaults.set(value, forKey: namespace + ".paused")
        status = value ? "Sync paused" : "Ready to sync"
        if !value {
            if !ready { await resumeIfNeeded() }
            else { await synchronize() }
            scheduler?.request()
        }
    }

    func renameDevice() async {
        guard !isLocalOnly else { return }
        await perform {
            guard let transport = self.transport, let account = try await self.keychain.account() else { throw SyncHTTPError.authenticationRequired }
            let identity = try await self.keychain.identity()
            try await transport.renameDevice(self.deviceName, accountID: account.keys.accountID, deviceID: identity.id, vaultKey: account.keys.vaultKey)
            try await self.refreshDevices()
        }
    }

    func revoke(_ id: String) async {
        guard !isLocalOnly else { return }
        await perform {
            guard let transport = self.transport else { throw SyncHTTPError.authenticationRequired }
            let identity = try await self.keychain.identity()
            guard id != identity.id else { throw SyncProtocolError.invalidPayload }
            try await transport.revokeDevice(id)
            try await self.refreshDevices()
        }
    }

    private func prepareTransport() async throws {
        guard !isLocalOnly else { throw SyncOffForLibraryCopy() }
        guard !stopping else { throw CancellationError() }
        if transport == nil {
            let identity = try await keychain.identity()
            guard !stopping else { throw CancellationError() }
            transport = try services.transport(identity, keychain)
        }
        connected = try await keychain.load() != nil
        services.defaults.set(connected, forKey: namespace + ".connected")
    }

    private func loadAccount() async throws {
        guard !isLocalOnly else { throw SyncOffForLibraryCopy() }
        guard !stopping else { throw CancellationError() }
        // A move that stopped between the detach and the sign-out finishes here: the library never binds again (MOVE-R3).
        if let library, try PrivateServerMove.hasLeft(library.database) {
            try await keychain.clearAuthentication()
            services.defaults.set(false, forKey: namespace + ".connected")
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
        guard !stopping, let library, !library.syncClosed else { throw CancellationError() }
        try SyncQueue(database: library.database).configure(accountID: saved.keys.accountID)
        if engine == nil {
            _ = try await keychain.identity()
            let made = try services.engine(library, saved, transport)
            blobs = made.blobs
            engine = made.engine
        }
        ready = true
        status = paused ? "Sync paused" : "Ready to sync"
        if scheduler == nil { scheduler = services.scheduler(self, library) }
    }

    private func syncNow(notePassword: String? = nil, remoteNotePassword: String? = nil, automatic: Bool = false) async throws {
        guard !paused else { status = "Sync paused"; return }
        guard ready, let engine, let library, let account = try await keychain.account() else { return }
        if waitingForNotePassword && notePassword == nil { return }
        let queue = SyncQueue(database: library.database)
        var unopenableLockedNotes = 0
        // Ruling 6: while a recovered journal waits for the notes key, only the key-only intake runs.
        // The sync controller's busy flag and quiesce barrier already fence it from library operations.
        library.refreshJournalRecovery()
        if library.journalKeyState == .waitingForSyncKey {
            guard let notePassword else {
                if try await engine.pendingNoteVaultIsAbsent() {
                    library.offerSealedJournalMoveAside()
                    waitingForNotePassword = false
                    status = "The notes key is not available yet. You can move the recovery files aside in Advanced settings; they will be kept unchanged."
                } else {
                    waitingForNotePassword = true
                    status = "A recovered edit needs the notes key from sync. Enter your notes password to continue."
                }
                return
            }
            status = "Fetching the notes key without changing your notes"
            guard let candidate = try await engine.scanPendingNoteVault(password: notePassword) else {
                library.offerSealedJournalMoveAside()
                waitingForNotePassword = false
                status = "The notes key is not available yet. You can move the recovery files aside in Advanced settings; they will be kept unchanged."
                return
            }
            guard try await engine.installPendingNoteVault(candidate) else {
                status = "The notes key is not available yet. Try again when the other device has synced."
                return
            }
            unopenableLockedNotes = try await engine.unopenableLockedNoteCount(for: candidate)
            try await library.unlockNotes(password: notePassword)
            waitingForNotePassword = false
            if try queue.isEnabled() {
                status = unopenableLockedNotes > 0 ? VaultIntakeLockedNotesMismatch.partialMessage(count: unopenableLockedNotes)
                    : "A recovery note is saved. Review it in Settings ▸ Advanced, then sync again."
                return
            }
        }
        if try !queue.isEnabled() {
            // Password verification precedes the safety snapshot. Unreplayed journals block it.
            if let notePassword { try await library.verifyNotePassword(notePassword) }
            status = "Saving a backup before the first sync"
            _ = try await library.makeBackup()
        }
        if try !queue.isEnabled(), try NotePrivacy(store: library.store).hasPassword, notePassword == nil {
            waitingForNotePassword = true
            status = "Enter your note password before syncing this protected library"
            return
        }
        status = "Syncing your notes"
        var summary = try await library.synchronize(using: engine, notePassword: notePassword, remoteNotePassword: remoteNotePassword, exclusive: !automatic)
        if summary.passwordRefreshRequired {
            guard let password = remoteNotePassword ?? notePassword else { throw NotePrivacyError.accessRevoked }
            summary = try await library.synchronize(using: engine, notePassword: password, remoteNotePassword: password)
        }
        if try !queue.isEnabled(), try queue.canEnableAfterInitialDownload(summary) {
            try queue.enable(accountID: account.keys.accountID)
            summary = try await library.synchronize(using: engine, notePassword: notePassword, remoteNotePassword: remoteNotePassword)
        }
        shouldContinueSoon = summary.shouldContinueSoon
        lastSync = .now
        waitingForNotePassword = summary.waitingForUnlock > 0
        status = Self.statusText(for: summary)
        if unopenableLockedNotes > 0 { status += " " + VaultIntakeLockedNotesMismatch.partialMessage(count: unopenableLockedNotes) }
        try await refreshDevices()
    }

    /// Attachments whose file is missing on this Mac can never upload; they are reported apart
    /// from real transfers and never hidden behind "All notes are up to date".
    nonisolated static func statusText(for summary: SyncRunSummary) -> String {
        statusText(
            waitingForUnlock: summary.waitingForUnlock, pendingUploads: summary.pendingUploads,
            pendingDownloads: summary.pendingDownloads, unavailableAttachments: summary.unavailableAttachments,
            deferredConflicts: summary.deferredConflicts)
    }

    nonisolated static func statusText(
        waitingForUnlock: Int, pendingUploads: Int, pendingDownloads: Int, unavailableAttachments: Int,
        deferredConflicts: Int = 0
    ) -> String {
        let unavailable = unavailableAttachments > 0
            ? "\(unavailableAttachments) attachments are unavailable on this Mac" : nil
        let conflicts = deferredConflicts > 0
            ? (deferredConflicts == 1 ? "1 edit waiting to merge"
                : "\(deferredConflicts) edits waiting to merge") : nil
        let main: String?
        if waitingForUnlock > 0 {
            main = waitingForUnlock == 1 ? "1 encrypted change needs your note password"
                : "\(waitingForUnlock) encrypted changes need your note password"
        } else if pendingDownloads > 0 || pendingUploads > 0 {
            main = "\(pendingUploads) uploads and \(pendingDownloads) downloads waiting"
        } else {
            main = unavailable == nil && conflicts == nil ? "All notes are up to date" : nil
        }
        return [main, conflicts, unavailable].compactMap { $0 }.joined(separator: " · ")
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

    func perform(_ operation: () async throws -> Void) async {
        guard !isLocalOnly else { return }
        guard !stopping, !busy, receivingTask == nil, quiesceDepth == 0 else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError { status = "Sync cancelled" }
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
