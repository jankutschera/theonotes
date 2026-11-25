// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Observation
import SwiftUI

/// What the small alert says (REL-R56). Plain words, no version-number jargon.
struct UpdateAlertContent: Equatable {
    var title: String
    var message: String
    /// Set only when a newer version exists: the page the "Open Download Page" button opens.
    var downloadPage: URL?

    static let openDownloadPage = "Open Download Page"

    init(for outcome: UpdateOutcome) {
        switch outcome {
        case .upToDate(let installed):
            title = "You\u{2019}re up to date"
            message = "Theo Notes \(installed) is the newest version."
            downloadPage = nil
        case .updateAvailable(let version, let installed, let page, let notes):
            title = "Version \(version) is available"
            let base = "You have version \(installed). Theo Notes does not download or install anything by itself. The download page has the new version."
            message = notes.map { "\($0)\n\n\(base)" } ?? base
            downloadPage = page
        case .couldNotCheck(let failure):
            title = "Couldn\u{2019}t check for updates"
            downloadPage = nil
            switch failure {
            case .unreachable:
                message = "Theo Notes could not reach theonotes.app. Check your internet connection and try again."
            case .unreadableAnswer:
                message = "theonotes.app answered, but not in a form Theo Notes understands. Try again later, or look for the newest version on theonotes.app."
            case .installedVersionUnknown:
                message = "This copy of Theo Notes does not know its own version number, so it cannot compare. Look for the newest version on theonotes.app."
            }
        }
    }
}

/// Theo Notes ▸ Check for Updates… (REL-R52). One check per click; nothing runs in the background.
@MainActor
@Observable
final class UpdatesController {
    /// Shows the alert and returns true when the person chose to open the download page.
    typealias Prompt = (UpdateAlertContent) -> Bool

    private(set) var isChecking = false

    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let installedVersion: String?
    @ObservationIgnored private let prompt: Prompt
    @ObservationIgnored private let openURL: (URL) -> Void

    init(checker: UpdateChecker, installedVersion: String?, prompt: @escaping Prompt, openURL: @escaping (URL) -> Void) {
        self.checker = checker
        self.installedVersion = installedVersion
        self.prompt = prompt
        self.openURL = openURL
    }

    /// The controller of the real app: the real site, this bundle's version, an NSAlert, the default browser.
    /// Creating it makes no request.
    static func live(bundle: Bundle = .main) -> UpdatesController {
        UpdatesController(
            checker: UpdateChecker(),
            installedVersion: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
                .trimmingCharacters(in: .whitespaces),
            prompt: { content in
                let alert = NSAlert()
                alert.messageText = content.title
                alert.informativeText = content.message
                if content.downloadPage != nil {
                    alert.addButton(withTitle: UpdateAlertContent.openDownloadPage)
                    alert.addButton(withTitle: "Not Now")
                } else {
                    alert.addButton(withTitle: "OK")
                }
                let chosen = alert.runModal() == .alertFirstButtonReturn
                return chosen && content.downloadPage != nil
            },
            openURL: { NSWorkspace.shared.open($0) })
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        let outcome = await checker.check(installedVersion: installedVersion)
        isChecking = false
        let content = UpdateAlertContent(for: outcome)
        if prompt(content), let page = content.downloadPage { openURL(page) }
    }
}

/// Theo Notes ▸ Check for Updates…, directly under About.
struct UpdateCommands: Commands {
    let controller: UpdatesController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { Task { await controller.checkForUpdates() } }
                .disabled(controller.isChecking)
        }
    }
}
