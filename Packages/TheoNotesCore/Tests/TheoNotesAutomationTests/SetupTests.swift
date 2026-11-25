// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// M5 Task 15: the command-line install and the Claude configuration text. Every test works in a
/// temporary "home"; the real home, `~/.local/bin` and `/usr/local/bin` are never touched.
struct SetupTests {
    private static func fixture() throws -> (home: URL, binary: URL, system: URL, installer: CLIInstaller) {
        let home = try TestLibrary.emptyFolder()
        let appFolder = home.appendingPathComponent("App", isDirectory: true)
        try FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        let binary = appFolder.appendingPathComponent("theonotes")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        let system = try TestLibrary.emptyFolder()
        return (home, binary, system, CLIInstaller(home: home, binary: binary, systemBin: system))
    }

    private static func link(_ home: URL) -> String { home.path + "/.local/bin/theonotes" }

    // MARK: CLIInstaller

    @Test func installCreatesSymlinkOnlyInUserLocalBin() throws {
        let (home, bin, system, installer) = try Self.fixture()
        #expect(installer.status(.userLocalBin) == .notInstalled)
        try installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: Self.link(home)) == bin.path)
        // No ~/.claude or anything else.
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == [".local", "App"].sorted())
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.local").sorted() == ["bin"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.local/bin") == ["theonotes"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: system.path).isEmpty)
        #expect(installer.status(.userLocalBin) == .installed(pointsHere: true))
        #expect(installer.status(.usrLocalBin) == .notInstalled)
        try installer.install() // again: nothing changes
        #expect(installer.status(.userLocalBin) == .installed(pointsHere: true))
    }

    @Test func installNeverReplacesARealFile() throws {
        let (home, _, _, installer) = try Self.fixture()
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: Self.link(home)))
        #expect(installer.status(.userLocalBin) == .occupiedByFile)
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.install() }
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.uninstall() }
        #expect(try String(contentsOfFile: Self.link(home), encoding: .utf8) == "mine")
        // A folder in the way is not ours either.
        try FileManager.default.removeItem(atPath: Self.link(home))
        try FileManager.default.createDirectory(atPath: Self.link(home), withIntermediateDirectories: true)
        #expect(installer.status(.userLocalBin) == .occupiedByFile)
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.install() }
    }

    @Test func installReplacesAForeignSymlinkAndUninstallRemovesOnlyOurs() throws {
        let (home, bin, _, installer) = try Self.fixture()
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: Self.link(home), withDestinationPath: home.path + "/elsewhere")
        #expect(installer.status(.userLocalBin) == .installed(pointsHere: false))
        // Uninstall leaves a link that points somewhere else.
        #expect(throws: CLIInstaller.InstallError.notOurs) { try installer.uninstall() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: Self.link(home)) == home.path + "/elsewhere")
        try installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: Self.link(home)) == bin.path)
        try installer.uninstall()
        #expect(installer.status(.userLocalBin) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: bin.path)) // the app's binary stays
        try installer.uninstall() // nothing there: no error
    }

    @Test func binaryExistsFollowsTheFile() throws {
        let (_, bin, _, installer) = try Self.fixture()
        #expect(!installer.binaryExists) // the fixture file is not executable yet
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        #expect(installer.binaryExists)
        let missing = CLIInstaller(home: bin, binary: bin.deletingLastPathComponent().appendingPathComponent("nowhere"))
        #expect(!missing.binaryExists)
    }

    @Test func systemBinStatusIsReadOnlyAndSudoCommandIsQuoted() throws {
        let (_, bin, system, installer) = try Self.fixture()
        #expect(installer.status(.usrLocalBin) == .notInstalled)
        try FileManager.default.createSymbolicLink(atPath: system.path + "/theonotes", withDestinationPath: bin.path)
        #expect(installer.status(.usrLocalBin) == .installed(pointsHere: true))
        try FileManager.default.removeItem(atPath: system.path + "/theonotes")
        try Data("x".utf8).write(to: system.appendingPathComponent("theonotes"))
        #expect(installer.status(.usrLocalBin) == .occupiedByFile)

        let spaced = CLIInstaller(home: URL(fileURLWithPath: "/h"), binary: URL(fileURLWithPath: "/Apps/It's Me/theonotes"))
        #expect(spaced.sudoCommand() == "sudo mkdir -p /usr/local/bin && sudo ln -sfh '/Apps/It'\\''s Me/theonotes' /usr/local/bin/theonotes")
        let plain = CLIInstaller(home: URL(fileURLWithPath: "/h"), binary: URL(fileURLWithPath: "/Applications/Baerchen.app/Contents/Helpers/theonotes"))
        #expect(plain.sudoCommand() == "sudo mkdir -p /usr/local/bin && sudo ln -sfh '/Applications/Baerchen.app/Contents/Helpers/theonotes' /usr/local/bin/theonotes")
    }

    // MARK: Race safety (M5-R198)

    /// Replaces whatever is at `path` with a regular file, the way another process could between
    /// the installer's check and its change.
    private static func swapInFile(at path: String, text: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func hiddenLeftovers(_ home: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.path + "/.local/bin")) ?? []).filter { $0 != "theonotes" }
    }

    @Test func installNeverDeletesAFileSwappedInOverAForeignLink() throws {
        var (home, _, _, installer) = try Self.fixture()
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: Self.link(home), withDestinationPath: home.path + "/elsewhere")
        let path = Self.link(home)
        installer.beforeChange = { Self.swapInFile(at: path, text: "precious") }
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.install() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "precious")
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    @Test func installNeverReplacesAFileThatAppearsWhereNothingWas() throws {
        var (home, _, _, installer) = try Self.fixture()
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        let path = Self.link(home)
        installer.beforeChange = { Self.swapInFile(at: path, text: "late") }
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.install() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "late")
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    @Test func installNeverReplacesAFolderSwappedIn() throws {
        var (home, _, _, installer) = try Self.fixture()
        try FileManager.default.createDirectory(atPath: home.path + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: Self.link(home), withDestinationPath: home.path + "/elsewhere")
        let path = Self.link(home)
        installer.beforeChange = {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createDirectory(atPath: path + "/inside", withIntermediateDirectories: true)
        }
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.install() }
        #expect(FileManager.default.fileExists(atPath: path + "/inside"))
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    @Test func uninstallNeverDeletesAFileSwappedInOverOurLink() throws {
        var (home, _, _, installer) = try Self.fixture()
        try installer.install()
        let path = Self.link(home)
        installer.beforeChange = { Self.swapInFile(at: path, text: "precious") }
        #expect(throws: CLIInstaller.InstallError.occupiedByFile) { try installer.uninstall() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "precious")
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    @Test func uninstallLeavesAForeignLinkSwappedIn() throws {
        var (home, _, _, installer) = try Self.fixture()
        try installer.install()
        let path = Self.link(home)
        installer.beforeChange = {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/somewhere/else")
        }
        #expect(throws: CLIInstaller.InstallError.notOurs) { try installer.uninstall() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == "/somewhere/else")
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    @Test func uninstallWhenTheLinkVanishesIsFine() throws {
        var (home, _, _, installer) = try Self.fixture()
        try installer.install()
        let path = Self.link(home)
        installer.beforeChange = { try? FileManager.default.removeItem(atPath: path) }
        try installer.uninstall()
        #expect(Self.hiddenLeftovers(home).isEmpty)
    }

    // MARK: The bin folder (M5-R199)

    @Test func newFoldersAreCreatedWith0755WhateverTheUmask() throws {
        let (home, _, _, installer) = try Self.fixture()
        let old = umask(0o077)
        defer { umask(old) }
        try installer.install()
        for dir in [".local", ".local/bin"] {
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: home.path + "/" + dir)[.posixPermissions] as? Int)
            #expect(mode & 0o7777 == 0o755, "\(dir) is \(String(mode, radix: 8))")
        }
    }

    @Test func installRefusesAWritableOrForeignFolder() throws {
        var (home, _, _, installer) = try Self.fixture()
        let bin = home.path + "/.local/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Group- or world-writable: someone else could swap the link.
        for mode in [0o775, 0o757] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: bin)
            #expect(throws: CLIInstaller.InstallError.unsafeFolder(bin)) { try installer.install() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin).isEmpty)
        }
        // A writable ~/.local is just as unsafe.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: home.path + "/.local")
        #expect(throws: CLIInstaller.InstallError.unsafeFolder(home.path + "/.local")) { try installer.install() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path + "/.local")
        // Owned by somebody else (the installer is told another user id).
        installer.userID = getuid() &+ 1
        #expect(throws: CLIInstaller.InstallError.unsafeFolder(home.path + "/.local")) { try installer.install() }
        // A file where the folder should be.
        installer.userID = getuid()
        try FileManager.default.removeItem(atPath: bin)
        try Data("x".utf8).write(to: URL(fileURLWithPath: bin))
        #expect(throws: CLIInstaller.InstallError.unsafeFolder(bin)) { try installer.install() }
        // The same folder with normal rights works.
        try FileManager.default.removeItem(atPath: bin)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try installer.install()
        #expect(installer.status(.userLocalBin) == .installed(pointsHere: true))
    }

    // MARK: /usr/local/bin command (M5-R200)

    @Test func sudoCommandIsBlockedWhereLnWouldDoTheWrongThing() throws {
        let (_, bin, system, installer) = try Self.fixture()
        #expect(installer.systemLinkBlocker() == nil)
        #expect(installer.sudoCommand().contains("ln -sfh "))
        // A foreign link to a folder: the command is not offered.
        let folder = system.appendingPathComponent("somewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: system.path + "/theonotes", withDestinationPath: folder.path)
        #expect(installer.systemLinkBlocker()?.contains("link to a folder") == true)
        // A foreign link to a file is replaced by the command: no blocker.
        try FileManager.default.removeItem(atPath: system.path + "/theonotes")
        try FileManager.default.createSymbolicLink(atPath: system.path + "/theonotes", withDestinationPath: bin.path + "-other")
        #expect(installer.systemLinkBlocker() == nil)
        // A real file is never offered a command that would replace it.
        try FileManager.default.removeItem(atPath: system.path + "/theonotes")
        try Data("x".utf8).write(to: system.appendingPathComponent("theonotes"))
        #expect(installer.systemLinkBlocker()?.contains("already in") == true)
    }

    // MARK: ClaudeConfig

    @Test func claudeConfigUsesAbsoluteBinaryPath() throws {
        let s = try JSONValue(parsing: Data(ClaudeConfig.desktopSnippet(binary: "/Users/me/.local/bin/theonotes", onlyTags: ["work"], excludeTags: []).utf8))
        #expect(s["mcpServers"]?["theonotes"]?["command"] == .string("/Users/me/.local/bin/theonotes"))
        #expect(s["mcpServers"]?["theonotes"]?["args"] == .array([.string("mcp-server"), .string("--only-tags"), .string("work")]))
        #expect(ClaudeConfig.claudeCodeCommand(binary: "/a b/theonotes", onlyTags: [], excludeTags: []) == "claude mcp add theonotes -- '/a b/theonotes' mcp-server")
    }

    @Test func claudeConfigScopeFlagsAreCleanedAndQuoted() throws {
        let text = ClaudeConfig.desktopSnippet(binary: "/b", onlyTags: [" #work ", "", "home/kids"], excludeTags: ["#private"])
        let args = try #require(try JSONValue(parsing: Data(text.utf8))["mcpServers"]?["theonotes"]?["args"])
        #expect(args == .array([
            .string("mcp-server"), .string("--only-tags"), .string("work,home/kids"),
            .string("--exclude-tags"), .string("private"),
        ]))
        #expect(ClaudeConfig.claudeCodeCommand(binary: "/b", onlyTags: ["work", "a b"], excludeTags: ["x"])
            == "claude mcp add theonotes -- '/b' mcp-server --only-tags 'work,a b' --exclude-tags 'x'")
        #expect(ClaudeConfig.claudeCodeCommand(binary: "/b", onlyTags: ["it's"], excludeTags: [])
            == "claude mcp add theonotes -- '/b' mcp-server --only-tags 'it'\\''s'")
        // Only blanks: no flag at all.
        #expect(!ClaudeConfig.desktopSnippet(binary: "/b", onlyTags: [" ", "#"], excludeTags: []).contains("--only-tags"))
    }

    @Test func desktopSnippetIsPrettyPrintedWithCommandFirst() {
        #expect(ClaudeConfig.desktopSnippet(binary: "/b", onlyTags: [], excludeTags: []) == """
        {
          "mcpServers": {
            "theonotes": {
              "command": "/b",
              "args": ["mcp-server"]
            }
          }
        }
        """)
        // Quotes and backslashes in a path are escaped, so the snippet stays valid JSON.
        let odd = ClaudeConfig.desktopSnippet(binary: "/a\"b\\c/theonotes", onlyTags: [], excludeTags: [])
        #expect((try? JSONValue(parsing: Data(odd.utf8)))?["mcpServers"]?["theonotes"]?["command"] == .string("/a\"b\\c/theonotes"))
    }
}
