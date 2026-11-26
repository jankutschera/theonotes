// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation

/// Puts the app's `baerchen` binary on the user's PATH with a symlink. It writes only inside the
/// chosen bin folder (`~/.local/bin`), never replaces or deletes a real file and removes only a
/// link that points at this binary. `/usr/local/bin` needs administrator rights, so the app shows
/// its `sudo` command for the user to run (`sudoCommand()`) and only reads that folder.
///
/// Changing the link never trusts an earlier check: the new link is made under a
/// temporary name and moved into place with `renamex_np`, and whatever it displaced is examined
/// afterwards and put back if it is not a link.
public struct CLIInstaller: Sendable {
    public enum Destination: Sendable { case userLocalBin, usrLocalBin }

    public enum Status: Equatable, Sendable {
        case notInstalled
        /// A symlink is there; `pointsHere` is whether it points at this binary.
        case installed(pointsHere: Bool)
        /// A regular file or folder is in the way. It is never replaced.
        case occupiedByFile
    }

    public enum InstallError: Error, Equatable, Sendable, CustomStringConvertible {
        case occupiedByFile
        case notOurs
        /// A folder on the way to the link is not a folder only the user can write to.
        case unsafeFolder(String)
        /// A system call failed; the text says which and where anything left over is.
        case failed(String)

        public var description: String {
            switch self {
            case .occupiedByFile: "A file named theonotes is already in ~/.local/bin; it was left as it is."
            case .notOurs: "The link in ~/.local/bin points somewhere else; it was left as it is."
            case .unsafeFolder(let path): "\(path) is not a folder that only you can write to, so nothing was installed."
            case .failed(let text): text
            }
        }
    }

    public static let commandName = "theonotes"

    public let home: URL
    public let binary: URL
    let systemBin: URL
    /// The user the folders must belong to; tests change it to see the refusal.
    var userID: uid_t = getuid()
    /// Runs after the checks and before the change; tests use it to swap something in between.
    var beforeChange: (@Sendable () -> Void)?

    /// `systemBin` is injectable so tests never look at the real `/usr/local/bin`.
    public init(home: URL, binary: URL, systemBin: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)) {
        self.home = home
        self.binary = binary
        self.systemBin = systemBin
    }

    /// Whether the binary is where the app says it is. `install()` does not check (the link is
    /// what it manages); the Settings pane disables Install while this is false.
    public var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    public func folder(_ destination: Destination) -> URL {
        switch destination {
        case .userLocalBin: home.appendingPathComponent(".local/bin", isDirectory: true)
        case .usrLocalBin: systemBin
        }
    }

    /// The path of the link in `destination`.
    public func linkPath(_ destination: Destination) -> String {
        folder(destination).appendingPathComponent(Self.commandName).path
    }

    public func status(_ destination: Destination) -> Status {
        let path = linkPath(destination)
        switch Self.entry(at: path) {
        case .none: return .notInstalled
        case .other: return .occupiedByFile
        case .symlink: return .installed(pointsHere: (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == binary.path)
        }
    }

    // MARK: Install

    /// Creates `~/.local/bin` (0755) and the link. A link that points elsewhere is replaced; a real
    /// file or folder is an error and stays untouched.
    public func install() throws {
        switch status(.userLocalBin) {
        case .occupiedByFile: throw InstallError.occupiedByFile
        case .installed(pointsHere: true): return
        case .installed(pointsHere: false), .notInstalled: break
        }
        try prepareFolders()
        let dest = linkPath(.userLocalBin)
        let temp = Self.temporaryPath(beside: dest)
        do {
            try FileManager.default.createSymbolicLink(atPath: temp, withDestinationPath: binary.path)
        } catch {
            throw InstallError.failed("Could not create a link in ~/.local/bin: \(error.localizedDescription)")
        }
        // Whatever is left under `temp` at the end is our own new link or the displaced old link.
        defer { if Self.entry(at: temp) == .symlink { unlink(temp) } }

        beforeChange?()
        for _ in 0..<3 {
            if renamex_np(temp, dest, UInt32(RENAME_EXCL)) == 0 { return }
            guard errno == EEXIST else { throw Self.systemError("move the new link into place", errno) }
            if renamex_np(temp, dest, UInt32(RENAME_SWAP)) == 0 {
                // `temp` now holds what was at `dest`.
                if Self.entry(at: temp) == .symlink { return }
                // Not a link: put it back.
                guard renamex_np(temp, dest, UInt32(RENAME_SWAP)) == 0 else {
                    throw InstallError.failed("Could not put the file that was in ~/.local/bin back; it is at \(temp).")
                }
                throw InstallError.occupiedByFile
            }
            guard errno == ENOENT else { throw Self.systemError("replace the link", errno) }
            // It vanished in between: try the empty-slot move again.
        }
        throw InstallError.failed("~/.local/bin/theonotes kept changing; nothing was installed.")
    }

    // MARK: Uninstall

    /// Removes the link in `~/.local/bin` if it points at this binary. Nothing there is not an error.
    public func uninstall() throws {
        switch status(.userLocalBin) {
        case .notInstalled: return
        case .occupiedByFile: throw InstallError.occupiedByFile
        case .installed(pointsHere: false): throw InstallError.notOurs
        case .installed(pointsHere: true): break
        }
        let dest = linkPath(.userLocalBin)
        let temp = Self.temporaryPath(beside: dest)
        beforeChange?()
        // Move it aside first, so what gets deleted is exactly what was examined.
        guard renamex_np(dest, temp, UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return }
            throw Self.systemError("remove the link", errno)
        }
        let kind = Self.entry(at: temp)
        if kind == .symlink, (try? FileManager.default.destinationOfSymbolicLink(atPath: temp)) == binary.path {
            unlink(temp)
            return
        }
        guard renamex_np(temp, dest, UInt32(RENAME_EXCL)) == 0 else {
            throw InstallError.failed("Could not put ~/.local/bin/theonotes back; it is at \(temp).")
        }
        throw kind == .symlink ? InstallError.notOurs : InstallError.occupiedByFile
    }

    // MARK: Folders

    /// `~/.local` and `~/.local/bin` must be folders the user owns that nobody else can write to;
    /// missing ones are made with 0755 whatever the umask.
    private func prepareFolders() throws {
        for dir in [home.appendingPathComponent(".local", isDirectory: true), folder(.userLocalBin)] {
            var info = stat()
            if stat(dir.path, &info) == 0 {
                let writableByOthers = info.st_mode & (S_IWGRP | S_IWOTH) != 0
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == userID, !writableByOthers else {
                    throw InstallError.unsafeFolder(dir.path)
                }
            } else {
                do {
                    try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: false)
                } catch {
                    throw InstallError.failed("Could not create \(dir.path): \(error.localizedDescription)")
                }
                guard chmod(dir.path, 0o755) == 0 else { throw Self.systemError("set the rights of \(dir.path)", errno) }
            }
        }
    }

    // MARK: /usr/local/bin

    /// What to run in Terminal to link the tool into `/usr/local/bin` (needs an administrator).
    /// `ln -sfh` does not follow a link already at the destination into the folder it points to.
    public func sudoCommand() -> String {
        let folder = folder(.usrLocalBin).path
        return "sudo mkdir -p \(folder) && sudo ln -sfh \(ShellQuote.quote(binary.path)) \(folder)/\(Self.commandName)"
    }

    /// Why `sudoCommand()` should not be offered right now, or nil when it is fine to.
    public func systemLinkBlocker() -> String? {
        let path = linkPath(.usrLocalBin)
        switch status(.usrLocalBin) {
        case .occupiedByFile:
            return "A file or folder named theonotes is already in /usr/local/bin. Move it away first; the command would replace it."
        case .installed(pointsHere: false):
            var info = stat()
            if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                return "/usr/local/bin/theonotes is a link to a folder. Remove that link first; the command would not replace it."
            }
            return nil
        case .installed(pointsHere: true), .notInstalled:
            return nil
        }
    }

    // MARK: Helpers

    private enum Entry { case none, symlink, other }

    /// What is at `path` itself (a link is not followed).
    private static func entry(at path: String) -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .none : .other }
        return info.st_mode & S_IFMT == S_IFLNK ? .symlink : .other
    }

    private static func temporaryPath(beside path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(".baerchen-\(UUID().uuidString).tmp").path
    }

    private static func systemError(_ what: String, _ code: Int32) -> InstallError {
        .failed("Could not \(what): \(String(cString: strerror(code))).")
    }
}
