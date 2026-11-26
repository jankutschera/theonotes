// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Observation
import SwiftUI

/// State of Settings → Automation: the command-line install, the Claude setup and the
/// x-callback-url token. Nothing here runs by itself. The only writes are the `theonotes` link in
/// `~/.local/bin` (Install / Uninstall), the token in the library's settings (Show, Copy and
/// Regenerate) and the pasteboard. Connect to Claude hands the bundled extension to Claude, which
/// asks the user before it installs it; the app itself never writes a Claude configuration file.
@MainActor
@Observable
final class AutomationSettingsModel {
    @ObservationIgnored let installer: CLIInstaller
    @ObservationIgnored private let settings: TheoNotesCore.Settings
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let claude: ClaudeDesktop

    private(set) var userStatus: CLIInstaller.Status = .notInstalled
    private(set) var systemStatus: CLIInstaller.Status = .notInstalled
    /// The stored token; "" until one was made (looking at the pane makes none).
    private(set) var token = ""
    private(set) var tokenRevealed = false
    /// The last failure, shown under the buttons.
    private(set) var errorMessage: String?
    /// What the last Copy put on the pasteboard, announced to VoiceOver and shown briefly.
    private(set) var copiedMessage: String?

    /// Where Claude Desktop is installed; nil when it is not.
    private(set) var claudeApp: URL?

    /// Comma-separated tags for `--only-tags` / `--exclude-tags`.
    var onlyTags = ""
    var excludeTags = ""

    init(installer: CLIInstaller, database: AppDatabase, pasteboard: NSPasteboard = .general, claude: ClaudeDesktop = .live) {
        self.installer = installer
        settings = TheoNotesCore.Settings(db: database)
        self.pasteboard = pasteboard
        self.claude = claude
        refresh()
    }

    /// The pane for the real home folder and the binary embedded in the app.
    convenience init(database: AppDatabase, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(installer: CLIInstaller(home: home, binary: Self.bundledBinary(bundleURL: Bundle.main.bundleURL)), database: database)
    }

    /// `<app>/Contents/Helpers/theonotes` (not `url(forAuxiliaryExecutable)`, which
    /// looks in `Contents/MacOS`).
    nonisolated static func bundledBinary(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/theonotes")
    }

    func refresh() {
        userStatus = installer.status(.userLocalBin)
        systemStatus = installer.status(.usrLocalBin)
        token = (try? settings.value(.automationToken)) ?? ""
        claudeApp = claude.appURL()
    }

    // MARK: Command-line tool

    var canInstall: Bool { installer.binaryExists && userStatus != .occupiedByFile && userStatus != .installed(pointsHere: true) }
    var isInstalledHere: Bool { userStatus == .installed(pointsHere: true) }

    func install() {
        guard installer.binaryExists else { return }
        run { try installer.install() }
    }

    func uninstall() {
        run { try installer.uninstall() }
    }

    private func run(_ action: () throws -> Void) {
        errorMessage = nil
        copiedMessage = nil
        do {
            try action()
        } catch let error as CLIInstaller.InstallError {
            errorMessage = error.description
        } catch {
            errorMessage = "Could not change ~/.local/bin: \(error.localizedDescription)"
        }
        refresh()
    }

    var sudoCommand: String { installer.sudoCommand() }

    /// Why the `/usr/local/bin` command is not offered, or nil.
    var sudoBlocker: String? { installer.systemLinkBlocker() }

    func copySudoCommand() {
        guard sudoBlocker == nil else { return }
        copy(sudoCommand, what: "The sudo command")
    }

    // MARK: Connect to Claude

    /// The download page offered when Claude Desktop is not installed.
    nonisolated static let claudeDownload = URL(string: "https://claude.ai/download")!

    /// The text under Connect to Claude.
    nonisolated static let connectGuidance = """
        Claude asks before it installs it and lets you limit it to some tags. Theo Notes never edits Claude's files. \
        One tool, add_attachment_from_url, fetches a web address that Claude chooses: review its requests before you \
        approve them.
        """

    var canConnect: Bool { claudeApp != nil && claude.extensionURL != nil }

    /// Hands the bundled extension to Claude Desktop, which shows its own install dialog.
    func connectToClaude() {
        errorMessage = nil
        copiedMessage = nil
        guard let app = claudeApp, let bundle = claude.extensionURL else { return }
        claude.open(bundle, app) { [weak self] error in
            guard let error else { return }
            self?.errorMessage = "Could not open Claude: \(error.localizedDescription)"
        }
    }

    // MARK: Other ways (copy)

    /// The text under the copy buttons. "Copy Claude config" copies a whole JSON object, so the
    /// text says to merge it.
    nonisolated static let claudeGuidance = """
        Claude can read and write your notes through the Theo Notes MCP server. "Copy Claude config" copies a complete \
        claude_desktop_config.json: if your file already has "mcpServers", merge the "theonotes" entry into it \
        instead of pasting a second one. "Copy Claude Code command" is for Terminal. Theo Notes never edits Claude's \
        files. Only/Exclude tags limit Claude to the notes with (or without) those tags and their nested tags; \
        leave both empty for the whole library. One tool, add_attachment_from_url, fetches a web address that \
        Claude chooses, so whatever is in that address reaches the site (addresses over 2,048 bytes (in their encoded form) are \
        refused): review its requests before you approve them.
        """

    /// The installed link when it points at this binary, else the binary inside the app.
    var binaryPath: String {
        if userStatus == .installed(pointsHere: true) { return installer.linkPath(.userLocalBin) }
        if systemStatus == .installed(pointsHere: true) { return installer.linkPath(.usrLocalBin) }
        return installer.binary.path
    }

    private var onlyList: [String] { Self.tags(onlyTags) }
    private var excludeList: [String] { Self.tags(excludeTags) }

    nonisolated static func tags(_ field: String) -> [String] {
        field.split(separator: ",").map(String.init)
    }

    func copyDesktopConfig() {
        copy(ClaudeConfig.desktopSnippet(binary: binaryPath, onlyTags: onlyList, excludeTags: excludeList), what: "The Claude config")
    }

    func copyClaudeCodeCommand() {
        copy(ClaudeConfig.claudeCodeCommand(binary: binaryPath, onlyTags: onlyList, excludeTags: excludeList), what: "The Claude Code command")
    }

    // MARK: x-callback-url token

    /// The token as the pane shows it: dots until revealed, a note while there is none.
    var displayedToken: String {
        if token.isEmpty { return "No token yet" }
        return tokenRevealed ? token : "••••••-••••••-••••••"
    }

    /// Shows the token, making one first when there is none.
    func revealToken() {
        guard ensureToken() else { return }
        tokenRevealed = true
    }

    func hideToken() { tokenRevealed = false }

    func copyToken() {
        guard ensureToken() else { return }
        copy(token, what: "The token")
    }

    /// A new token; the old one stops working at once (every shortcut using it must be updated).
    func regenerateToken() {
        errorMessage = nil
        do {
            token = try AutomationToken.regenerate(settings)
            tokenRevealed = true
            copiedMessage = "New token made"
        } catch {
            errorMessage = "Could not make a token: \(error.localizedDescription)"
        }
    }

    private func ensureToken() -> Bool {
        errorMessage = nil
        do {
            token = try AutomationToken.ensure(settings)
            return true
        } catch {
            errorMessage = "Could not make a token: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Pasteboard

    private func copy(_ text: String, what: String) {
        errorMessage = nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedMessage = "\(what) is on the clipboard"
        AccessibilityNotification.Announcement(copiedMessage ?? "").post()
    }
}

/// Claude Desktop as the pane sees it, replaceable in tests.
struct ClaudeDesktop {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    /// The extension built into the app by scripts/build-mcpb.py; nil in a build without it.
    var extensionURL: URL?
    var appURL: @MainActor () -> URL?
    /// Opens `bundle` with the app at `app`; `completion` gets the error, if any, on the main actor.
    var open: @MainActor (_ bundle: URL, _ app: URL, _ completion: @escaping @MainActor ((any Error)?) -> Void) -> Void

    @MainActor static let live = ClaudeDesktop(
        extensionURL: Bundle.main.url(forResource: "TheoNotes", withExtension: "mcpb"),
        appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) },
        open: { bundle, app, completion in
            NSWorkspace.shared.open([bundle], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let error = error.map { $0 as NSError }
                Task { @MainActor in completion(error) }
            }
        })
}

/// The accessibility identifiers of the Automation pane.
enum AutomationControl {
    static let install = "automation-install"
    static let uninstall = "automation-uninstall"
    static let copySudo = "automation-copy-sudo"
    static let onlyTags = "automation-only-tags"
    static let excludeTags = "automation-exclude-tags"
    static let copyClaudeConfig = "automation-copy-claude-config"
    static let copyClaudeCode = "automation-copy-claude-code"
    static let connectClaude = "automation-connect-claude"
    static let downloadClaude = "automation-download-claude"
    static let otherWays = "automation-claude-other-ways"
    static let token = "automation-token"
    static let tokenShow = "automation-token-show"
    static let tokenHide = "automation-token-hide"
    static let tokenCopy = "automation-token-copy"
    static let tokenRegenerate = "automation-token-regenerate"
    static let confirmRegenerate = "automation-token-regenerate-confirm"
    static let cancelRegenerate = "automation-token-regenerate-cancel"

    static let all = [
        install, uninstall, copySudo, onlyTags, excludeTags, copyClaudeConfig, copyClaudeCode, connectClaude, downloadClaude,
        otherWays, token, tokenShow, tokenHide, tokenCopy, tokenRegenerate, confirmRegenerate, cancelRegenerate,
    ]
}

/// Settings → Automation (spec §4.8, M5 Task 15).
struct AutomationSettingsView: View {
    @State private var model: AutomationSettingsModel
    @State private var confirmingRegenerate = false

    init(model: AutomationSettingsModel) {
        _model = State(initialValue: model)
    }

    init(environment: AppEnvironment, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(model: AutomationSettingsModel(database: environment.database, home: home))
    }

    var body: some View {
        Form {
            commandLineSection
            claudeSection
            callbackSection
            if let message = model.errorMessage {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            } else if let message = model.copiedMessage {
                Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }

    // MARK: Command-line tool

    private var commandLineSection: some View {
        Section {
            LabeledContent("~/.local/bin") {
                HStack {
                    Text(statusText(model.userStatus))
                        .foregroundStyle(.secondary)
                    if model.isInstalledHere {
                        Button("Uninstall") { model.uninstall() }
                            .accessibilityIdentifier(AutomationControl.uninstall)
                            .accessibilityHint("Removes the theonotes link from ~/.local/bin")
                    } else {
                        Button("Install in ~/.local/bin") { model.install() }
                            .disabled(!model.canInstall)
                            .accessibilityIdentifier(AutomationControl.install)
                            .accessibilityHint("Makes the theonotes command available in Terminal")
                    }
                }
            }
            LabeledContent("/usr/local/bin") {
                Text(statusText(model.systemStatus))
                    .foregroundStyle(.secondary)
            }
            if let blocker = model.sudoBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if model.systemStatus != .installed(pointsHere: true) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.sudoCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Terminal command for /usr/local/bin: \(model.sudoCommand)")
                    Button("Copy") { model.copySudoCommand() }
                        .accessibilityLabel("Copy the sudo command")
                        .accessibilityIdentifier(AutomationControl.copySudo)
                }
            }
        } header: {
            Text("Command-line tool")
        } footer: {
            Text("""
                Install links the theonotes tool inside the Theo Notes app into ~/.local/bin, which must be on your PATH. \
                For /usr/local/bin run the command above in Terminal; it asks for your password.
                """)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ status: CLIInstaller.Status) -> String {
        switch status {
        case .notInstalled: "Not installed"
        case .installed(pointsHere: true): "Installed"
        case .installed(pointsHere: false): "Links to another theonotes"
        case .occupiedByFile: "A file named theonotes is in the way"
        }
    }

    // MARK: Claude

    private var claudeSection: some View {
        Section {
            LabeledContent {
                if model.claudeApp == nil {
                    Link("Download Claude", destination: AutomationSettingsModel.claudeDownload)
                        .accessibilityIdentifier(AutomationControl.downloadClaude)
                } else {
                    Button("Connect to Claude") { model.connectToClaude() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canConnect)
                        .accessibilityHint("Opens the Theo Notes extension in Claude, which asks before it installs it")
                        .accessibilityIdentifier(AutomationControl.connectClaude)
                }
            } label: {
                Text("Claude Desktop")
                Text(model.claudeApp == nil ? "Claude is not installed on this Mac." : "Opens the Theo Notes extension in Claude.")
            }
            Text(AutomationSettingsModel.connectGuidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Other ways to connect") {
                otherWays
            }
            .accessibilityIdentifier(AutomationControl.otherWays)
        } header: {
            Text("Claude")
        }
    }

    @ViewBuilder private var otherWays: some View {
        LabeledContent("Only tags") {
            TextField("Only tags", text: $model.onlyTags, prompt: Text("work, home/kids"))
                .labelsHidden()
                .accessibilityIdentifier(AutomationControl.onlyTags)
        }
        LabeledContent("Exclude tags") {
            TextField("Exclude tags", text: $model.excludeTags, prompt: Text("private"))
                .labelsHidden()
                .accessibilityIdentifier(AutomationControl.excludeTags)
        }
        HStack {
            Button("Copy Claude config") { model.copyDesktopConfig() }
                .accessibilityHint("Copies a claude_desktop_config.json with the theonotes entry, to merge into your own")
                .accessibilityIdentifier(AutomationControl.copyClaudeConfig)
            Button("Copy Claude Code command") { model.copyClaudeCodeCommand() }
                .accessibilityHint("Copies a claude mcp add command to run in Terminal")
                .accessibilityIdentifier(AutomationControl.copyClaudeCode)
        }
        Text(AutomationSettingsModel.claudeGuidance)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: x-callback-url

    private var callbackSection: some View {
        Section {
            LabeledContent("Token") {
                Text(model.displayedToken)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(model.token.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .accessibilityLabel(model.tokenRevealed ? "Token \(model.token)" : "Token hidden")
                    .accessibilityIdentifier(AutomationControl.token)
            }
            HStack {
                if model.tokenRevealed {
                    Button("Hide") { model.hideToken() }
                        .accessibilityIdentifier(AutomationControl.tokenHide)
                } else {
                    Button("Show") { model.revealToken() }
                        .accessibilityIdentifier(AutomationControl.tokenShow)
                }
                Button("Copy") { model.copyToken() }
                    .accessibilityLabel("Copy token")
                    .accessibilityIdentifier(AutomationControl.tokenCopy)
                Spacer()
                Button("Regenerate…") { confirmingRegenerate = true }
                    .accessibilityIdentifier(AutomationControl.tokenRegenerate)
            }
        } header: {
            Text("x-callback-url")
        } footer: {
            Text("""
                Shortcuts and scripts add token=… to a theonotes:// link to read notes back or change them. \
                Without the token those links can only open notes, create notes and add text.
                """)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Make a new token?", isPresented: $confirmingRegenerate) {
            Button("Make New Token", role: .destructive) { model.regenerateToken() }
                .accessibilityIdentifier(AutomationControl.confirmRegenerate)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(AutomationControl.cancelRegenerate)
        } message: {
            Text("The old token stops working at once. Shortcuts and scripts that use it must be updated.")
        }
    }
}
