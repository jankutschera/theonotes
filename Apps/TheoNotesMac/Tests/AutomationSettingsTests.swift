// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesAutomation
import TheoNotesCore
import Foundation
import SwiftUI
import Testing
@testable import TheoNotes

/// M5 Task 15: Settings → Automation. Everything runs against a temporary "home" and a private
/// pasteboard: the real `~/.local/bin`, `/usr/local/bin`, any Claude configuration and the general
/// pasteboard are never touched.
@MainActor
@Suite struct AutomationSettingsTests {
    let home: URL
    let binary: URL
    let systemBin: URL
    let environment: AppEnvironment
    let pasteboard: NSPasteboard
    let model: AutomationSettingsModel

    init() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TheoNotesAutomationSettings-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        let app = root.appendingPathComponent("Baerchen.app/Contents/Helpers", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        binary = app.appendingPathComponent("theonotes")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        environment = try AppEnvironment(paths: AppPaths(root: root.appendingPathComponent("library", isDirectory: true)))
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.truebrewbirdie.baerchen.tests.\(UUID().uuidString)"))
        systemBin = root.appendingPathComponent("usr-local-bin", isDirectory: true)
        model = AutomationSettingsModel(
            installer: CLIInstaller(home: home, binary: binary, systemBin: systemBin),
            database: environment.database, pasteboard: pasteboard)
    }

    private var userLink: String { home.path + "/.local/bin/theonotes" }

    /// Every file and folder under `home`, relative, sorted.
    private func tree() -> [String] {
        let walker = FileManager.default.enumerator(atPath: home.path)
        return (walker?.allObjects as? [String] ?? []).sorted()
    }

    @Test func automationTabShowsStatusAndCopiesConfigToPasteboard() throws {
        // Status: nothing installed, nothing written by looking.
        #expect(model.userStatus == .notInstalled && model.systemStatus == .notInstalled)
        #expect(tree().isEmpty)
        #expect(model.binaryPath == binary.path)

        // Install: only ~/.local/bin/theonotes appears.
        model.install()
        #expect(model.userStatus == .installed(pointsHere: true))
        #expect(model.errorMessage == nil)
        #expect(tree() == [".local", ".local/bin", ".local/bin/theonotes"])
        // From now on the config names the installed link, not the bundle path.
        #expect(model.binaryPath == userLink)

        // Claude Desktop snippet, with the tag scope from the fields.
        model.onlyTags = " #work, home/kids ,"
        model.excludeTags = "private"
        model.copyDesktopConfig()
        let snippet = try #require(pasteboard.string(forType: .string))
        let parsed = try JSONValue(parsing: Data(snippet.utf8))
        #expect(parsed["mcpServers"]?["theonotes"]?["command"] == .string(userLink))
        #expect(parsed["mcpServers"]?["theonotes"]?["args"] == .array([
            .string("mcp-server"), .string("--only-tags"), .string("work,home/kids"),
            .string("--exclude-tags"), .string("private"),
        ]))

        // Claude Code command replaces the pasteboard content.
        model.copyClaudeCodeCommand()
        #expect(pasteboard.string(forType: .string)
            == "claude mcp add theonotes -- '\(userLink)' mcp-server --only-tags 'work,home/kids' --exclude-tags 'private'")

        // The sudo command for /usr/local/bin is offered, not run.
        model.copySudoCommand()
        #expect(pasteboard.string(forType: .string)?.hasPrefix("sudo mkdir -p ") == true)
        #expect(pasteboard.string(forType: .string)?.contains("'\(binary.path)'") == true)

        // Uninstall removes our link and nothing else.
        model.uninstall()
        #expect(model.userStatus == .notInstalled)
        #expect(tree() == [".local", ".local/bin"])
        #expect(model.binaryPath == binary.path)

        // No Claude configuration anywhere in the temporary home.
        #expect(!tree().contains { $0.contains("claude") || $0.contains("Claude") })
    }

    @Test func sudoCommandUsesLnSfhAndIsWithheldForALinkToAFolder() throws {
        #expect(model.sudoBlocker == nil)
        model.copySudoCommand()
        #expect(pasteboard.string(forType: .string)?.contains(" ln -sfh '\(binary.path)' ") == true)

        // /usr/local/bin/theonotes is somebody's link to a folder: no command, and the reason shows.
        let folder = systemBin.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: systemBin.path + "/theonotes", withDestinationPath: folder.path)
        model.refresh()
        pasteboard.clearContents()
        model.copySudoCommand()
        #expect(model.sudoBlocker?.contains("link to a folder") == true)
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(tree().isEmpty)
    }

    @Test func installSaysWhyWhenTheBinFolderIsWritableByOthers() throws {
        let bin = home.path + "/.local/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: bin)
        model.install()
        #expect(model.errorMessage?.contains("only you can write to") == true)
        #expect(model.userStatus == .notInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin).isEmpty)
    }

    @Test func claudeConfigIsACompleteFileAndTheTextSaysToMergeIt() throws {
        model.copyDesktopConfig()
        let parsed = try JSONValue(parsing: Data(try #require(pasteboard.string(forType: .string)).utf8))
        // The copy is a whole root object ...
        #expect(parsed.keys == ["mcpServers"])
        #expect(parsed["mcpServers"]?["theonotes"]?["command"] == .string(binary.path))
        // ... and the guidance next to the button says so (M5-R201).
        let text = AutomationSettingsModel.claudeGuidance
        #expect(text.contains("complete claude_desktop_config.json"))
        #expect(text.contains("merge the \"theonotes\" entry"))
        #expect(!text.contains("Paste the config into Claude Desktop's"))
    }

    /// The one outbound channel is named where the user sets Claude up (final review M6).
    @Test func claudeGuidanceNamesTheURLFetchAsAnOutboundChannel() {
        let text = AutomationSettingsModel.claudeGuidance
        #expect(text.contains("add_attachment_from_url"))
        #expect(text.contains("fetches a web address that Claude chooses"))
        #expect(text.contains("review its requests before you approve them"))
        #expect(text.contains("over 2,048 bytes (in their encoded form) are refused"))
    }

    @Test func accessibilityIdentifiersAreUniqueAndPrefixed() {
        let all = AutomationControl.all
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0.hasPrefix("automation-") })
        #expect(all.contains(AutomationControl.confirmRegenerate) && all.contains(AutomationControl.cancelRegenerate))
    }

    @Test func installRefusesARealFileAndSaysSo() throws {
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: userLink))
        model.refresh()
        #expect(model.userStatus == .occupiedByFile)
        #expect(!model.canInstall)
        model.install()
        #expect(model.errorMessage != nil)
        #expect(try String(contentsOfFile: userLink, encoding: .utf8) == "mine")
    }

    @Test func installIsOffWhileTheToolIsMissing() {
        let missing = AutomationSettingsModel(
            installer: CLIInstaller(home: home, binary: home.appendingPathComponent("nowhere/theonotes"), systemBin: home.appendingPathComponent("sys")),
            database: environment.database, pasteboard: pasteboard)
        #expect(!missing.canInstall)
        missing.install()
        #expect(tree().isEmpty)
    }

    @Test func bundledBinaryIsTheHelpersCopyNotTheAppExecutable() {
        let app = URL(fileURLWithPath: "/Applications/Baerchen.app")
        #expect(AutomationSettingsModel.bundledBinary(bundleURL: app).path == "/Applications/Baerchen.app/Contents/Helpers/theonotes")
    }

    @Test func tokenIsMaskedUntilShownAndRegenerateReplacesIt() throws {
        let settings = TheoNotesCore.Settings(db: environment.database)
        // Looking at the pane creates no token.
        #expect(model.token == "" && !model.tokenRevealed)
        #expect(try settings.value(.automationToken) == "")

        model.revealToken()
        let first = model.token
        #expect(first.range(of: "^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", options: .regularExpression) != nil)
        #expect(model.tokenRevealed)
        #expect(try settings.value(.automationToken) == first)
        #expect(model.displayedToken == first)

        model.hideToken()
        #expect(!model.tokenRevealed)
        #expect(!model.displayedToken.contains(first.prefix(6)))

        model.copyToken()
        #expect(pasteboard.string(forType: .string) == first)

        model.regenerateToken()
        #expect(model.token != first)
        #expect(try settings.value(.automationToken) == model.token)
        // The old token no longer works.
        #expect(!AutomationToken.matches(first, try settings.value(.automationToken)))
        #expect(AutomationToken.matches(model.token, try settings.value(.automationToken)))
    }

    @Test func automationPaneRendersOffscreen() async throws {
        let hosting = NSHostingView(rootView: AutomationSettingsView(model: model).frame(width: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0)
        // Rendering alone writes nothing.
        #expect(tree().isEmpty)
        // Optional look: BAERCHEN_SETTINGS_PNG_DIR=/some/dir (as in SettingsAppearanceTests).
        if let dir = ProcessInfo.processInfo.environment["BAERCHEN_SETTINGS_PNG_DIR"] {
            window.appearance = NSAppearance(named: .aqua)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("automation.png"))
            }
        }
        window.close()
    }
}
