// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppIntents
import CoreSpotlight
import TheoNotesCore
import SwiftUI
import UIKit

@main
struct TheoNotesIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileBackgroundSessionDelegate.self) private var backgroundSessionDelegate
    @Environment(\.scenePhase) private var phase
    @State private var library: MobileLibrary?
    @State private var callbacks: MobileXCallbackController?
    @State private var captureRouter = MobileShortcutRuntime.captureRouter
    /// Settings ▸ iCloud, only in a build that offers iCloud sync (`ReleaseFeatures.cloudSyncAvailable`); nil otherwise, so nothing of it is built.
    @State private var cloud: MobileCloudSyncController?
    @State private var startupError: String?
    private let shareContainer: URL?
    private let basePaths: AppPaths

    init() {
        MobileSystemNavigation.connection.connect(nil) // Submit stale-index purge before opening any scene/store.
        var paths = AppPaths.production
        var resetError: (any Error)?
        var shortcutUITesting = false
        #if DEBUG && targetEnvironment(simulator)
        // Shortcuts cold-launches without our UI-test arguments. This opt-in is confined
        // to debug simulators, so system-driven test launches keep using the fixture library.
        if ProcessInfo.processInfo.arguments.contains("--shortcuts-ui-testing") {
            UserDefaults.standard.set(true, forKey: "shortcutsUITesting")
        }
        if ProcessInfo.processInfo.arguments.contains("--end-shortcuts-ui-testing") {
            UserDefaults.standard.removeObject(forKey: "shortcutsUITesting")
        }
        shortcutUITesting = UserDefaults.standard.bool(forKey: "shortcutsUITesting")
        #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") || shortcutUITesting {
                // UI tests never open or reset the user's library.
                paths = AppPaths(root: paths.root.deletingLastPathComponent().appendingPathComponent("TheoNotesUITests"))
                if ProcessInfo.processInfo.arguments.contains("--reset-library"), FileManager.default.fileExists(atPath: paths.root.path) {
                    do { try FileManager.default.removeItem(at: paths.root) }
                    catch { resetError = error }
                }
            }
            #endif
        basePaths = paths
        let shareContainer = MobileShareContainer.usesProductionContainer(
            arguments: ProcessInfo.processInfo.arguments, shortcutsUITesting: shortcutUITesting
        ) ? MobileShareContainer.resolve() : nil
        self.shareContainer = shareContainer
        let publicationError = MobileShareContainer.scrubRecentNotes(in: shareContainer)
        do {
            do { try MobileShareContainer.scrubWidgets(in: shareContainer) }
            catch { throw MobileWidgetCleanupError() }
            if let resetError { throw resetError }
            let current = try MobileLibrary(paths: SyncRecoveryLibrary.activePaths(base: paths), shareContainer: shareContainer,
                seedsGettingStarted: MobileGettingStarted.seedsInThisLaunch(shortcutsUITesting: shortcutUITesting))
            MobileWatchConnectivity.shared.connect(current)
            current.watchPrivacyDidChange = { MobileWatchConnectivity.shared.privacyChanged() }
            current.watchWillRestrictAccess = { MobileWatchConnectivity.shared.redact() }
            // A URLSession relaunch can precede any scene becoming visible.
            _ = MobilePrivateServerSync.controller(for: current)
            Task { await current.drainShareInboxOnActivation() }
            _library = State(initialValue: current)
            _callbacks = State(initialValue: MobileXCallbackController(library: current))
            let cloudController = Self.makeCloudController(for: current)
            _cloud = State(initialValue: cloudController)
            MobileCloudSyncRouter.connect(cloudController)
            MobileSystemNavigation.connection.connect(current)
            WidgetCaptureRuntime.handler = { action, id in
                let router = MobileShortcutRuntime.captureRouter
                router.enqueue(Self.captureAction(action), deliveryID: id)
                try await router.drain()
            }
            BaerchenAppShortcuts.updateAppShortcutParameters()
        } catch {
            MobileSystemNavigation.connection.connect(nil)
            _startupError = State(initialValue: [error.localizedDescription, publicationError].compactMap { $0 }.joined(separator: " "))
        }
    }

    @MainActor private static func makeCloudController(for library: MobileLibrary) -> MobileCloudSyncController? {
        guard ReleaseFeatures.cloudSyncAvailable() else { return nil }
        #if DEBUG
        MobilePrivateServerSync.controller(for: library)?.runPrivateServerUITestFixtureIfRequested()    // before the controller reads the binding
        #endif
        let controller = MobileCloudSyncController(library: MobileCloudSyncLibrary(library: library), services: .live(), available: true)
        // "Move This Library to iCloud" needs the private-server sync of this build.
        if MobilePrivateServerSync.isAvailable() {
            controller.leavePrivateServer = { [weak library] withoutMissingFiles in
                guard let library, let sync = MobilePrivateServerSync.controller(for: library) else { throw CancellationError() }
                try await sync.leaveForICloud(withoutMissingFiles: withoutMissingFiles)
            }
        }
        #if DEBUG
        // UI-test fixture for the evidence screenshot only: the move refuses as for the owner's missing image files.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing"), arguments.contains("--missing-files-fixture") {
            // --six-notes: the owner's case, six notes (five titles and "1 more"), with long titles that must stay on one line each.
            let six = arguments.contains("--six-notes")
            let notes = six ? ["Imported cover image from the old travel journal of the summer road trip",
                               "Trip photos from the long weekend at the lake with the whole family",
                               "Recipe collection scanned from grandmother's handwritten notebook",
                               "Whiteboard sketches from the planning workshop in the spring",
                               "Receipts and warranty cards for the kitchen appliances"] : ["Imported cover", "Trip photos"]
            controller.leavePrivateServer = { withoutMissingFiles in
                guard withoutMissingFiles else {
                    throw PrivateServerMoveRefusal.unavailableAttachments(notes: notes, moreNotes: six ? 1 : 0, canMoveWithout: true)
                }
            }
        }
        #endif
        return controller
    }

    var body: some Scene {
        WindowGroup(for: MobileNoteSceneAddress.self) { $address in
            if let library {
                MobileNoteSceneRoot(library: library, address: $address, onURL: { url in
                    if url.scheme == WidgetRoutes.scheme, url.host == "widget" {
                        handleWidgetURL(url, library: library)
                    } else { Task { await callbacks?.handle(url) } }
                })
                    .id(ObjectIdentifier(library))
                    .environment(cloud)
                    .environment(captureRouter)
                    #if DEBUG
                    .overlay(alignment: .bottomTrailing) {
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                           ProcessInfo.processInfo.arguments.contains("--multiwindow-ui-testing") {
                            MobileMultiwindowUITestProbe(library: library).frame(width: 2, height: 2)
                        }
                    }
                    #endif
                    .task {
                        #if DEBUG
                        await MobilePrivateServerSync.controller(for: library)?.runPauseUITestFixtureIfRequested()
                        #endif
                    }
                    // The launch fetch of the iCloud sync; a library whose switch is off does nothing here.
                    .task(id: library.paths.root) { await cloud?.start() }
                    .task(id: library.paths.root) { _ = await library.sweepAttachments() }
                    .onReceive(NotificationCenter.default.publisher(for: SyncRecoveryLibrary.selectionDidChange)) { _ in
                        // Claim the switch before scheduling, so repeated notifications cannot
                        // close the same library and construct competing replacement stores.
                        guard MobileSystemNavigation.connection.beginSwitch() else { return }
                        do { try library.claimSceneLibrarySwitch() }
                        catch {
                            MobileSystemNavigation.connection.finishSwitch(library)
                            library.errorMessage = error.localizedDescription
                            return
                        }
                        Task {
                            do {
                                MobileWatchConnectivity.shared.connect(nil)
                                let closing = cloud
                                MobileCloudSyncRouter.connect(nil)
                                await closing?.shutdown()
                                try await library.closeAfterStopping()
                                // A library switch opens a library that already exists (a recovery copy): it is never new.
                                let current = try MobileLibrary(paths: SyncRecoveryLibrary.activePaths(base: basePaths), shareContainer: shareContainer, seedsGettingStarted: false)
                                MobileWatchConnectivity.shared.connect(current)
                                current.watchPrivacyDidChange = { MobileWatchConnectivity.shared.privacyChanged() }
                                current.watchWillRestrictAccess = { MobileWatchConnectivity.shared.redact() }
                                _ = MobilePrivateServerSync.controller(for: current)
                                callbacks = MobileXCallbackController(library: current)
                                let next = Self.makeCloudController(for: current)
                                cloud = next
                                MobileCloudSyncRouter.connect(next)
                                await current.drainShareInboxOnActivation()
                                self.library = current
                                MobileSystemNavigation.connection.finishSwitch(current)
                                BaerchenAppShortcuts.updateAppShortcutParameters()
                                await drainCaptures(in: current)
                            } catch {
                                if !library.isClosed {
                                    MobileWatchConnectivity.shared.connect(library)
                                    library.cancelSceneLibrarySwitch()
                                    // A busy importer can reject teardown before the store closes.
                                    // Keep its UI and automation usable instead of showing a startup failure.
                                    MobileSystemNavigation.connection.finishSwitch(library)
                                    library.errorMessage = error.localizedDescription
                                    let reopened = Self.makeCloudController(for: library)
                                    cloud = reopened
                                    MobileCloudSyncRouter.connect(reopened)
                                    Task { await reopened?.start() }
                                    await drainCaptures(in: library)
                                } else {
                                    MobileSystemNavigation.connection.finishSwitch(nil)
                                    callbacks = nil
                                    cloud = nil
                                    self.library = nil
                                    startupError = error.localizedDescription
                                }
                            }
                        }
                    }
                    .tint(Color.accentColor)
                    .onAppear {
                        library.setActive(phase == .active)
                        if phase == .active { library.voiceCapture.updateSceneActivity(active: true, background: false) }
                        Task { await drainCaptures(in: library) }
                    }
                    .onChange(of: phase) { _, phase in
                        library.setActive(phase == .active)
                        if phase == .background { MobileWatchConnectivity.shared.clearReadAuthorization() }
                        if !library.hasRegisteredSceneWindows {
                            library.voiceCapture.updateSceneActivity(active: phase == .active, background: phase == .background)
                        }
                        if phase != .active { library.perform { try library.flush() } }
                        Task { await drainCaptures(in: library) }
                    }
                    .onChange(of: MobileSystemNavigation.spotlight.lastErrorMessage) { previous, message in
                        if let message { library.errorMessage = message }
                        else if library.errorMessage == previous { library.errorMessage = nil }
                    }
                    .onChange(of: library.appLocked) { _, locked in
                        if !locked { Task { await drainCaptures(in: library) } }
                    }
                    .onChange(of: library.items) { _, _ in MobileWatchConnectivity.shared.privacyChanged() }
                    .onChange(of: library.libraryOperationBusy) { _, busy in
                        if !busy { Task { await drainCaptures(in: library) } }
                    }
                    .onContinueUserActivity(CSSearchableItemActionType) { activity in
                        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                        MobileSystemNavigation.receiveSpotlight(identifier)
                        Task { await drainCaptures(in: library) }
                    }
            } else {
                ContentUnavailableView("Unable to open your library", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(startupError ?? "Please restart Theo Notes."))
            }
        }
        .backgroundTask(.appRefresh(MobileSyncScheduler.refreshIdentifier)) {
            // One task serves both syncs: the private server (Jan's builds) and iCloud (only when the switch is on).
            let (current, cloudController) = await MainActor.run { (library, cloud) }
            async let iCloud: Void = { await cloudController?.backgroundRefresh() }()
            if let current { await MobilePrivateServerSync.controller(for: current)?.backgroundRefresh() }
            await iCloud
        }
    }

    @MainActor private func drainCaptures(in library: MobileLibrary) async {
        guard self.library === library,
              MobileSystemNavigation.connection.prepareToDrain(library, ready: phase == .active) else { return }
        if phase == .active {
            MobileSystemNavigation.spotlight.retryPendingPurge()
            if let message = MobileSystemNavigation.spotlight.lastErrorMessage { library.errorMessage = message }
        }
        do {
            try MobileSystemNavigation.drain(ready: phase == .active)
            try await MobileSystemNavigation.connection.drainCaptures(library, ready: phase == .active)
        }
        catch is CancellationError {}
        catch { library.errorMessage = error.localizedDescription }
    }

    @MainActor private func handleWidgetURL(_ url: URL, library: MobileLibrary) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        if let raw = items.first(where: { $0.name == "action" })?.value,
           let action = WidgetCaptureAction(rawValue: raw) {
            captureRouter.enqueue(Self.captureAction(action))
        } else if let id = items.first(where: { $0.name == "note" })?.value,
                  let libraryID = items.first(where: { $0.name == "library" })?.value {
            MobileSystemNavigation.receiveWidget(noteID: id, libraryID: libraryID)
        }
        Task { await drainCaptures(in: library) }
    }

    private static func captureAction(_ action: WidgetCaptureAction) -> MobileCaptureRouter.Action {
        switch action {
        case .thought: .thought
        case .voice: .voice
        case .newNote: .newNote
        case .newTodo: .newTodo
        case .scan: .scan
        case .search: .search
        }
    }

}

#if DEBUG
/// Read live counts during AX snapshots without polling timers or changing scene behavior.
@MainActor private struct MobileMultiwindowUITestProbe: UIViewRepresentable {
    let library: MobileLibrary
    final class Probe: UIView {
        var counts: (() -> String)?
        override var accessibilityValue: String? {
            get { counts?() }
            set {}
        }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "multiwindow-scene-counts"
        view.accessibilityLabel = "Multiwindow scene counts"
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.counts = { [weak library] in
            "connected=\(UIApplication.shared.connectedScenes.count);registered=\(library?.sceneRegistry.sceneCount ?? -1)"
        }
    }
}
#endif

/// Never admit a restored/cold system activity into an inactive/background scene.
/// Returning nil preserves its pending address for the local active transition.
@MainActor enum MobileSceneActivationAdmission {
    enum Origin { case restoration, external }
    enum Resolution { case waitingForUnlock, unavailable, discardRestoration, note(Note) }
    static func initialNavigation(address: MobileNoteSceneAddress?, library: MobileLibrary) -> MobileSceneNavigation {
        // An addressed window must not briefly show some OTHER window's legacy note.
        MobileSceneNavigation(id: address?.windowID ?? UUID(), restoration: MobileRestoration(
            scope: library.scope, workspace: library.workspace?.path,
            noteID: address == nil ? library.selectedID : nil))
    }
    static func resolve(_ address: MobileNoteSceneAddress, library: MobileLibrary,
                        phase: ScenePhase, origin: Origin = .external) -> Resolution? {
        guard phase == .active else { return nil }
        switch MobileNoteSceneActivation.resolve(address, library: library) {
        case .note(let note): return .note(note)
        case .waitingForUnlock: return .waitingForUnlock
        case .unavailable:
            if case .restoration = origin { return .discardRestoration }
            return .unavailable
        }
    }
}

/// Each actual SwiftUI window owns its navigation and deferred activation. The shared
/// App state continues to own ONE library, sync controller and background URLSession delegate.
@MainActor private struct MobileNoteSceneRoot: View {
    @Environment(\.scenePhase) private var phase
    let library: MobileLibrary
    @Binding var address: MobileNoteSceneAddress?
    let onURL: (URL) -> Void
    @State private var navigation: MobileSceneNavigation
    @State private var pendingAddress: MobileNoteSceneAddress?
    @State private var pendingAddressOrigin: MobileSceneActivationAdmission.Origin = .restoration
    @State private var deliveredAddresses: Set<UUID> = []
    @State private var sceneSessionID: String?

    init(library: MobileLibrary, address: Binding<MobileNoteSceneAddress?>, onURL: @escaping (URL) -> Void) {
        self.library = library; _address = address; self.onURL = onURL
        let initial = address.wrappedValue
        _navigation = State(initialValue: MobileSceneActivationAdmission.initialNavigation(address: initial, library: library))
        _pendingAddress = State(initialValue: initial)
    }
    var body: some View {
        MobileLibraryView(library: library, sceneNavigation: navigation)
            .background(MobileSceneSessionProbe { sessionID in
                sceneSessionID = sessionID
                takeActivity(sessionID)
            })
            .onAppear {
                // Consume only when this actual destination appears, not during speculative
                // SwiftUI value initializers. A fresh explicit open must not be mistaken for
                // silent restoration if its target vanished during OS scene activation.
                if let pendingAddress, MobileNoteSceneActivation.consumeExplicitRequest(pendingAddress) {
                    pendingAddressOrigin = .external
                }
                // Parent onAppear runs synchronously before the child attach Task can
                // await a previous teardown: count this actual window even with no editor.
                do { try library.registerScene(id: navigation.id, activity: sceneActivity) }
                catch { if !library.isClosing && !library.isClosed { library.errorMessage = error.localizedDescription } }
                resolvePending()
            }
            .onChange(of: phase) { _, _ in
                _ = library.updateSceneActivity(id: navigation.id, activity: sceneActivity)
                if phase == .active { resolvePending() }
            }
            .onChange(of: address) { _, next in
                if let next, !deliveredAddresses.contains(next.windowID) {
                    pendingAddressOrigin = .external; pendingAddress = next; resolvePending()
                }
            }
            .onChange(of: navigation.selectedID) { _, id in
                // Persist this window's CURRENT note in the typed scene restoration,
                // without routing its own state update as another external delivery.
                guard id != address?.noteID else { return }
                if let id {
                    address = try? MobileNoteSceneAddress(windowID: navigation.id,
                        libraryID: MobileCardPublication.libraryID(for: library.paths), noteID: id)
                    deliveredAddresses.insert(navigation.id)
                } else { address = nil }
            }
            .onChange(of: library.appLocked) { _, _ in resolvePending() }
            .onChange(of: library.privateAccess.map(ObjectIdentifier.init)) { _, _ in resolvePending() }
            .onChange(of: library.sceneOperationPending) { _, _ in resolvePending() }
            .onChange(of: library.sceneAdmissionGeneration) { _, _ in resolvePending() }
            .onChange(of: library.libraryOperationBusy) { _, _ in resolvePending() }
            .onReceive(NotificationCenter.default.publisher(for: MobileSceneActivityInbox.notification)) { notification in
                guard let id = notification.object as? String, id == sceneSessionID else { return }
                takeActivity(id)
            }
            .onContinueUserActivity(MobileNoteSceneActivation.activityType) { activity in
                if let sceneSessionID {
                    _ = MobileSceneActivityInbox.shared.receive(activity, sceneSessionID: sceneSessionID)
                    takeActivity(sceneSessionID)
                } else if let next = try? MobileNoteSceneActivation.address(from: activity),
                          !deliveredAddresses.contains(next.windowID) {
                    pendingAddressOrigin = .external; pendingAddress = next; resolvePending()
                }
            }
            .onOpenURL { url in library.prepareLegacyNavigationContext(for: navigation.id); onURL(url) }
    }
    private var sceneActivity: MobileSceneRegistry.Activity {
        switch phase { case .active: .active; case .inactive: .inactive; case .background: .background; @unknown default: .inactive }
    }
    private func takeActivity(_ id: String) {
        guard let next = MobileSceneActivityInbox.shared.take(sceneSessionID: id),
              !deliveredAddresses.contains(next.windowID) else { return }
        pendingAddressOrigin = .external
        pendingAddress = next
        resolvePending()
    }
    private func resolvePending() {
        guard let pendingAddress, !library.sceneOperationPending, !library.libraryOperationBusy else { return }
        guard let resolution = MobileSceneActivationAdmission.resolve(pendingAddress, library: library, phase: phase, origin: pendingAddressOrigin) else { return }
        switch resolution {
        case .waitingForUnlock: return
        case .discardRestoration:
            self.pendingAddress = nil
            if address == pendingAddress { address = nil }
            // Preserve a newer user selection made while restoration waited for access.
            if navigation.selectedID == pendingAddress.noteID { navigation.selectedID = nil }
        case .unavailable:
            self.pendingAddress = nil
            library.errorMessage = "This note is unavailable in the current library."
        case .note(let note):
            do {
                try library.reveal(note.id, in: navigation)
                deliveredAddresses.insert(pendingAddress.windowID)
                // A session receives bounded system deliveries; avoid unbounded in-memory dedup.
                if deliveredAddresses.count > 64 { deliveredAddresses = [pendingAddress.windowID] }
                self.pendingAddress = nil
            } catch MobileEditorDrainError.busy {
                // sceneAdmissionGeneration retries this exact scene-local pending address.
            } catch { library.errorMessage = error.localizedDescription }
        }
    }
}

/// Connect cold scene-delegate user activities to the ACTUAL destination OS scene,
/// rather than opening a second typed window from an already-created drag window.
@MainActor private struct MobileSceneSessionProbe: UIViewRepresentable {
    let attached: (String) -> Void
    final class Probe: UIView {
        var attached: ((String) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let id = window?.windowScene?.session.persistentIdentifier else { return }
            attached?(id)
        }
    }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(frame: .zero); view.isUserInteractionEnabled = false
        view.attached = attached
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.attached = attached
        if let id = view.window?.windowScene?.session.persistentIdentifier {
            Task { @MainActor in attached(id) }
        }
    }
}
