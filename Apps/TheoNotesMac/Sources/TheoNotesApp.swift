// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI
import UserNotifications

/// Hosted unit tests build their own environments in temp dirs and never show the main window.
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

@main
struct TheoNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Main windows (File ▸ New Window): each has its own scope, selection and history.
        WindowGroup("Theo Notes", id: AppModel.mainWindowID) {
            MainWindowHost(app: appDelegate.app, startupError: appDelegate.startupError)
        }
        // Opened files and URLs are the delegate's business. Without an empty match set on every scene
        // SwiftUI opens a window per event (and the default Window scene, About, for the first one).
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1100, height: 700)
        .defaultLaunchBehavior(isRunningUnitTests ? .suppressed : .automatic)
        .restorationBehavior(isRunningUnitTests ? .disabled : .automatic)
        .commands {
            AboutCommands()
            UpdateCommands(controller: appDelegate.updates)
            CopyAsCommands(app: appDelegate.app) // M8 Task 14: before Format's Paste From, so Copy As sits above it
            // Format before Note, as in Bear (a menu's place follows the order its commands are declared in).
            FormatCommands()
            TheoNotesCommands(app: appDelegate.app)
            InfoCommands()
            ImportCommands()
            ExportCommands()
            BackupCommands()
            PrintCommands(app: appDelegate.app)
            DiagnosticsCommands(controller: appDelegate.diagnostics)
            GettingStartedCommands(app: appDelegate.app)
        }

        // Capture from anywhere: the menu bar item (Settings ▸ Capture ▸ Show in menu bar).
        MenuBarExtra(isInserted: Bindable(appDelegate.captureSettings).showInMenuBar) {
            CaptureMenuBarContent(
                actions: .live(app: appDelegate.app, capture: appDelegate.captureFromAnywhere))
        } label: {
            Image(systemName: "square.and.pencil").accessibilityLabel("Theo Notes")
        }

        // Separate note windows: double-click, ⌥⌘N, Open In New Window (and Quick Open ⌘↩).
        WindowGroup("Note", id: AppModel.noteWindowID, for: String.self) { $noteId in
            NoteWindowHost(app: appDelegate.app, noteId: $noteId)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 640, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(isRunningUnitTests ? .disabled : .automatic)

        // Theo Notes ▸ About, and the licences window its button opens (LIC-R*).
        Window("About Theo Notes", id: AboutWindow.about) {
            AboutView()
        }
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Acknowledgements", id: AboutWindow.acknowledgements) {
            AcknowledgementsView()
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 820, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        SwiftUI.Settings {
            if let app = appDelegate.app {
                SettingsView(settings: app.settings, environment: app.environment, capture: appDelegate.captureSettingsModel)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private(set) var app: AppModel?
    private(set) var startupError: (any Error)?

    /// Per-Mac capture preferences; read by the App body before launch finishes.
    let captureSettings = CaptureSettings(defaults: .standard, identity: .current)
    /// Nil in unit-test runs and without a library.
    private(set) var captureFromAnywhere: CaptureFromAnywhere?
    private(set) var captureHotKey: CaptureHotKeyController?
    /// Settings ▸ Capture; reads the hot key controller when it is used, not when it is made.
    private(set) lazy var captureSettingsModel = CaptureSettingsModel(
        settings: captureSettings, hotKey: { [unowned self] in captureHotKey }, loginItem: SystemLoginItem())
    /// The first delegate, the one SwiftUI made; lets tests reach the live settings.
    static private(set) weak var live: AppDelegate?

    /// Crash and hang reports kept on this Mac; nil in unit-test runs.
    private(set) var diagnostics: DiagnosticsController?

    /// Theo Notes ▸ Check for Updates…. Creating it makes no request; only a click does.
    let updates = UpdatesController.live()

    /// An unusable `--data-dir` / `BAERCHEN_DATA_DIR`: the app opens no library and quits.
    private var dataDirectoryError: AppPaths.DataDirectoryError?

    /// The CLI / MCP socket (M5 Task 12); nil in unit-test runs and when another instance holds it.
    private var automationServer: AppSocketServer?

    /// `baerchen://x-callback-url/…` URLs (M5 Task 14); they wait here until the app model exists.
    private let xCallbackInbox = XCallbackInbox()

    /// Files opened from the Finder; they wait here until the library is open and unlocked.
    let openFiles = OpenFilesHandler()

    override init() {
        super.init()
        if Self.live == nil { Self.live = self }
        guard !isRunningUnitTests else { return }
        diagnostics = DiagnosticsController.live()
        DiagnosticsController.shared = diagnostics
        do {
            // The real library (following its recovery selection), or exactly the copy a launch
            // override names, which is local-only. Never the real one instead.
            // The real system source and the real app-wide appearance; tests default to a static source and no-op.
            let environment = try AppEnvironment.launching(
                systemAppearance: LiveSystemAppearance(), applyAppAppearance: AppearanceController.setAppAppearance,
                notificationCenter: LiveNotificationCenter(), shareContainerURL: AppEnvironment.liveShareContainer)
            app = AppModel(environment: environment, pullsFromBearAtLaunch: true)
            if let app {
                xCallbackInbox.handler = XCallbackHandler(app: app)
                app.connectReminderTaps()
                EditorContextMenu.remind = { [weak app] editor, scope in app?.remind(editor: editor, scope: scope) }
                EditorContextMenu.copyAs = { [weak app] editor, format in app?.copyAs(editor: editor, format: format) }
                EditorContextMenu.keepTags = { [weak app] in app?.settings.snapshot.keepTagsOnExport ?? true }
                EditorContextMenu.setKeepTags = { [weak app] on in app?.settings.set(.keepTagsOnExport, on) }
                openFiles.attach(to: app)
                captureFromAnywhere = CaptureFromAnywhere(app: app, workspace: WorkspaceFrontmostApp())
            }
        } catch let error as AppPaths.DataDirectoryError {
            dataDirectoryError = error
            startupError = error
            appLogger.fault("refusing to launch: unusable data directory override")
        } catch {
            startupError = error
            appLogger.fault("could not open the library: \(error)")
        }
    }

    /// Takes the URL events before SwiftUI does: its default would open a new window for every URL.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // No window tabs anywhere in the app: drops View ▸ Show Tab Bar and Show All Tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        guard !isRunningUnitTests else { return }
        // Before anything can be delivered: taps that launch the app arrive through this delegate.
        UNUserNotificationCenter.current().delegate = self
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// A silent push about the private iCloud database, if the system ever delivers one. The Mac does not ask for them (Gate G0 A4);
    /// the 5-minute timer, the foreground and the launch are its triggers. A notification is only handed on, never relied on.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        app?.environment.handleCloudRemoteNotification(userInfo)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
            let url = URL(string: text)
        else { return }
        xCallbackInbox.receive(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openFiles.receive(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dataDirectoryError {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Theo Notes did not open a library"
            if case .libraryVanished = dataDirectoryError {
                alert.informativeText = "\(dataDirectoryError.description) Nothing was created and nothing was changed."
            } else {
                alert.informativeText = """
                    \(dataDirectoryError.description) Nothing was opened, not even your real library. Fix the \
                    path given with \(AppPaths.dataDirArgument) or \(AppPaths.dataDirEnvironmentKey), or launch \
                    Theo Notes without it.
                    """
            }
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // The attachment cleanup of R23, off the main thread now that the UI is up.
        app?.environment.sweepAttachments()
        if let captureFromAnywhere, !isRunningUnitTests {
            captureHotKey = CaptureHotKeyController(
                settings: captureSettings, registrar: GlobalHotKey(), onPress: { captureFromAnywhere.capture() })
            captureHotKey?.apply()
        }
        app?.environment.startOCR()
        startAutomationSocket()
        diagnostics?.start()
        if DiagnosticsDebugHooks.simulatedHangRequested(arguments: ProcessInfo.processInfo.arguments) {
            DispatchQueue.main.async { Thread.sleep(forTimeInterval: DiagnosticsDebugHooks.hangSeconds) }
        }
        app?.environment.startSync()
        app?.environment.startDailyBackups() // M8 Task 15: the daily database snapshot
        catchUpReminders() // reminders that came due while the app was closed
        app?.environment.drainShareInbox() // items the share extension queued while the app was closed
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.catchUpReminders()
                self?.app?.environment.applicationDidBecomeActive()
            }
        }
        CopyAsMenuPlacement.install() // M8 Task 14: Edit ▸ Copy As right after Copy
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.app?.environment.flushAll() }
        }
    }

    private func catchUpReminders() {
        guard let environment = app?.environment else { return }
        Task { await environment.reminders.catchUp() }
    }

    // MARK: Notifications (C14)

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        return await presentation(forRequest: identifier)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        await handleNotification(action: action, request: identifier)
    }

    private func presentation(forRequest identifier: String) -> UNNotificationPresentationOptions {
        (app?.environment.reminders.willPresent(requestIdentifier: identifier) ?? false) ? [.banner, .list, .sound] : []
    }

    private func handleNotification(action: String, request: String) async {
        await app?.environment.reminders.handle(actionIdentifier: action, requestIdentifier: request)
    }

    /// Serves `baerchen app open` / `get-selection` for this library. A second instance on the same
    /// library (live socket) serves nothing and says so in the log; the app runs on.
    private func startAutomationSocket() {
        guard let app, !isRunningUnitTests, automationServer == nil else { return }
        let handler = AppAutomationHandler(app: app)
        let server = AppSocketServer(paths: app.environment.paths) { request in await handler.handle(request) }
        do {
            try server.start()
            automationServer = server
        } catch let error as AppSocketServer.StartError {
            appLogger.notice("automation socket not started: \(error.description, privacy: .public)")
        } catch {
            appLogger.error("automation socket not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The app quits with its last window; the test host (main window suppressed) must survive
    /// tests that open and close their own windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isRunningUnitTests
    }

    /// Flushes acknowledged host state only. The editor sends every transaction immediately, so only
    /// transactions in flight (sent but not yet acked) at quit time are not covered.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A capture close still waiting for its editor keeps the note.
        app?.isQuitting = true
        app?.saveSelection()
        app?.runPendingLinkRewrites()
        app?.environment.flushAll()
        app?.environment.stopOCR()
        app?.environment.stopDailyBackups()
        automationServer?.stop()
        app?.environment.stopSync()
        return .terminateNow
    }
}
