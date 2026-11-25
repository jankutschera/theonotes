// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import SwiftUI

/// Crash and hang diagnostics on the Mac (REL-R40 … REL-R48): subscribes to the system's reports, keeps them in
/// a bounded local folder and lets the person look at or copy them. Nothing is sent anywhere by this code.
@MainActor
final class DiagnosticsController {
    /// The running app's controller, for the Settings row; nil in unit-test runs.
    static var shared: DiagnosticsController?

    let store: DiagnosticsStore
    private let source: any DiagnosticsSource
    private let appName: String
    private let appVersion: String
    private let osVersion: String
    private let openFolder: (URL) -> Void
    private let copyText: (String) -> Void
    private var task: Task<Void, Never>?

    init(
        store: DiagnosticsStore, source: any DiagnosticsSource, appName: String = "Theo Notes",
        appVersion: String, osVersion: String, openFolder: @escaping (URL) -> Void, copyText: @escaping (String) -> Void
    ) {
        self.store = store
        self.source = source
        self.appName = appName
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.openFolder = openFolder
        self.copyText = copyText
    }

    /// The controller of the real app: MetricKit as the source, the folder of this build's identity.
    static func live() -> DiagnosticsController {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return DiagnosticsController(
            store: DiagnosticsStore(folder: DiagnosticsLocation.live), source: MetricKitDiagnosticsSource(),
            appName: AppIdentity.current.displayName,
            appVersion: build.map { "\(version) (\($0))" } ?? version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            openFolder: { NSWorkspace.shared.open($0) },
            copyText: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString($0, forType: .string)
            })
    }

    /// Begins receiving reports. Safe to call twice.
    func start() {
        guard task == nil else { return }
        let collector = DiagnosticsCollector(store: store, source: source) { error in
            appLogger.error("could not store a diagnostic report: \(error.localizedDescription, privacy: .public)")
        }
        task = Task { await collector.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Opens the folder in Finder. It is created first so the item works before the first report exists.
    func showReports() {
        try? FileManager.default.createDirectory(
            at: store.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        openFolder(store.folder)
    }

    /// Puts the plain-text summary on the pasteboard, for pasting into an email.
    func copySummary() {
        copyText(summary())
    }

    func summary() -> String {
        DiagnosticsSummary.text(
            appName: appName, appVersion: appVersion, osVersion: osVersion, entries: store.entries())
    }
}

/// Titles of the Help menu items and the Settings buttons.
enum DiagnosticsMenu {
    static let showReports = "Show Diagnostic Reports in Finder"
    static let copySummary = "Copy Diagnostics Summary"
}

/// Help ▸ Show Diagnostic Reports in Finder / Copy Diagnostics Summary.
struct DiagnosticsCommands: Commands {
    let controller: DiagnosticsController?

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button(DiagnosticsMenu.showReports) { controller?.showReports() }
                .disabled(controller == nil)
            Button(DiagnosticsMenu.copySummary) { controller?.copySummary() }
                .disabled(controller == nil)
        }
    }
}

/// Debug builds only: a deliberate main-thread stall so the system has a hang to report (REL-R47). The report
/// arrives through MetricKit on a later launch, up to a day later; this does not make it faster.
enum DiagnosticsDebugHooks {
    static let hangArgument = "--simulate-hang"
    static let hangSeconds: TimeInterval = 8

    static func simulatedHangRequested(arguments: [String], identity: AppIdentity = .current) -> Bool {
        #if DEBUG
        return identity == .dev && arguments.contains(hangArgument)
        #else
        return false
        #endif
    }
}
