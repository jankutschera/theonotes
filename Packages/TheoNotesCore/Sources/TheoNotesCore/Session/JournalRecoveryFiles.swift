// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import Darwin

/// Shared file-format primitives. Callers retain their own authorization and error policies.
enum JournalRecoveryFiles {
    struct Identity {
        let device: UInt64, inode: UInt64, size: Int64, seconds: Int64, nanos: Int64
    }
    static func identity(_ url: URL, failure: any Error) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure }
        return Identity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                        seconds: Int64(info.st_mtimespec.tv_sec), nanos: Int64(info.st_mtimespec.tv_nsec))
    }
    static func validSuffix(_ suffix: String) -> Bool {
        suffix.isEmpty || suffix == ".unreplayed" ||
            (suffix.hasPrefix(".unreplayed.") && Int(suffix.dropFirst(".unreplayed.".count)) != nil)
    }

    static func replayPlain(base: Data, journal: Data) -> String? {
        guard journal.last == UInt8(ascii: "\n"), let saved = try? JSONDecoder().decode(JournalBase.self, from: base),
              saved.v == EditJournal.formatVersion else { return nil }
        let lines = journal.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }
        var text = saved.baseText
        for line in lines.dropLast() {
            guard !line.isEmpty, let entry = try? JSONDecoder().decode(JournalEntry.self, from: Data(line)),
                  entry.v == EditJournal.formatVersion, let next = try? entry.changeSet.apply(to: text) else { return nil }
            text = next
        }
        return text
    }

    static func readRegular(_ url: URL, failure: any Error, tooLarge: (any Error)? = nil) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure }
        guard info.st_size >= 0, info.st_size <= 64 * 1_024 * 1_024 else { throw tooLarge ?? failure }
        return try Data(contentsOf: url)
    }

    static func syncDirectory(_ url: URL, failure: any Error) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw failure }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure }
    }

    static func digest(_ bytes: Data, noteId: String, info: String, key: SymmetricKey?) -> Data {
        guard let key else { return Data(SHA256.hash(data: bytes)) }
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(noteId.utf8),
                                             info: Data(info.utf8), outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: derived))
    }
}
