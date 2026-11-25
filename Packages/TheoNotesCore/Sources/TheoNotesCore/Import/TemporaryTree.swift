// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation

/// Removal of the importer's and the backup reader's temporary folders, through descriptors only.
enum TemporaryTree {
    struct ListingFailure: Error {
        let code: Int32
    }

    /// Removes `directory` and everything below it. The parent is opened with
    /// `O_DIRECTORY | O_NOFOLLOW`; below it every item is examined with `fstatat`
    /// (`AT_SYMLINK_NOFOLLOW`), folders are opened with `openat(O_NOFOLLOW)` and removed with
    /// `unlinkat`, so no path is resolved twice and no link is followed (a link is unlinked, also
    /// as `directory` itself). A folder without owner access gets it first (`fchmodat`,
    /// `AT_SYMLINK_NOFOLLOW`). Removal goes on past a failure. Returns `nil` on success (or when
    /// nothing is there), else a short reason.
    static func remove(at directory: URL) -> String? {
        let failure = "temporary files could not be removed (\(directory.path))"
        let name = directory.lastPathComponent
        let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return errno == ENOENT ? nil : failure }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? nil : failure }
        return removeItem(name, in: parent, info) ? nil : failure
    }

    private static func removeItem(_ name: String, in parent: Int32, _ info: stat) -> Bool {
        guard info.st_mode & S_IFMT == S_IFDIR else { return unlinkat(parent, name, 0) == 0 }
        if info.st_mode & 0o700 != 0o700 {
            _ = fchmodat(parent, name, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW)
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let children = try? names(in: fd) else { return false }
        var removedAll = true
        for child in children {
            var childInfo = stat()
            guard fstatat(fd, child, &childInfo, AT_SYMLINK_NOFOLLOW) == 0, removeItem(child, in: fd, childInfo) else {
                removedAll = false
                continue
            }
        }
        return removedAll && unlinkat(parent, name, AT_REMOVEDIR) == 0
    }

    /// The names in the folder `fd` (a duplicate descriptor is read; `fd` stays open). `readdir`
    /// returning nil with `errno` set is a failure, not the end of the folder.
    static func names(
        in fd: Int32, read: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) }
    ) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw ListingFailure(code: errno) }
        guard let dir = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw ListingFailure(code: code)
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = read(dir) else {
                if errno != 0 { throw ListingFailure(code: errno) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
}
