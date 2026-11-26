// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Compression
import Darwin
import Foundation

/// The one extractor for zip archives from outside the app: `.bear`, `.bearnote` and `.panda`
/// imports and `.baerchen-backup` restores. Own code only: no ditto,
/// no third-party parser; deflate goes through Apple's Compression framework
/// (`COMPRESSION_ZLIB` is raw DEFLATE, RFC 1951, per `compression.h`).
///
/// The whole archive is checked before a byte is written: exactly one end record whose central
/// directory ends right at it, every central entry bounds-checked, every local header equal to
/// its central entry (name bytes, flags, method, CRC and sizes, or a data descriptor that
/// repeats the central values), and the entries tiling the bytes before the directory with no
/// gap or overlap. Names are relative UTF-8 paths without `..`, `.`, empty parts, backslashes,
/// control characters or drive letters, and no two of them name one file when compared the way
/// APFS does (case folding + NFC). Only regular files and folders, judged from the external
/// attributes for every creator system. Encryption, ZIP64, multi-disk archives and methods
/// other than stored and deflate are refused. While writing, each entry's output is capped at
/// its declared size, the per-entry cap and the running total cap before each chunk is
/// written; CRC-32 and size are checked at the end of each entry. Files are created with
/// `O_CREAT | O_EXCL | O_NOFOLLOW` and folders opened with `O_NOFOLLOW` below a destination
/// that is new or an empty folder. On any error the destination is removed again (or emptied
/// when it existed).
public enum SafeZip {
    public struct Limits: Sendable, Equatable {
        public var maxEntries: Int
        public var maxEntryBytes: UInt64
        public var maxTotalBytes: UInt64
        public var maxNameBytes: Int
        public var maxDirectoryBytes: Int
        /// Folders, explicit or implied by a path, in the whole archive.
        public var maxFolders: Int
        /// Parts of one entry path (`a/b/c.txt` has 3).
        public var maxDepth: Int

        public init(
            maxEntries: Int = 10_000, maxEntryBytes: UInt64 = 512 << 20, maxTotalBytes: UInt64 = 1 << 30,
            maxNameBytes: Int = 1024, maxDirectoryBytes: Int = 16 << 20, maxFolders: Int = 20_000, maxDepth: Int = 64
        ) {
            self.maxEntries = maxEntries
            self.maxEntryBytes = maxEntryBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxNameBytes = maxNameBytes
            self.maxDirectoryBytes = maxDirectoryBytes
            self.maxFolders = maxFolders
            self.maxDepth = maxDepth
        }

        /// `.bear`, `.bearnote`, `.panda`: one note with its attachments.
        public static let imports = Limits()
        /// `.zip`, `.textpack`, `.bear2bk`: up to a whole Bear backup, within what a zip without
        /// ZIP64 can hold (65,534 entries, entries under 4 GiB).
        public static let bulkImports = Limits(
            maxEntries: 65_534, maxEntryBytes: 0xFFFF_FFFE, maxTotalBytes: 20 << 30, maxDirectoryBytes: 64 << 20,
            maxFolders: 65_534)
        /// `.baerchen-backup`: a whole library, within what a zip without ZIP64 can hold.
        public static let backups = Limits(
            maxEntries: 65_534, maxEntryBytes: 0xFFFF_FFFE, maxTotalBytes: 8 << 30, maxDirectoryBytes: 64 << 20,
            maxFolders: 65_534)
    }

    /// Extracts `archive` into `destination` (created; or an existing empty folder) and returns
    /// the relative paths written, in central-directory order (folders without a trailing `/`).
    @discardableResult
    public static func extract(archive: URL, to destination: URL, limits: Limits) throws -> [String] {
        try extract(archive: archive, to: destination, limits: limits, onWrite: nil)
    }

    /// Validates `archive` as `extract` would before writing (directory, local headers, names,
    /// types, declared sizes against `limits`) without writing or inflating anything.
    static func check(archive: URL, limits: Limits) throws {
        let fd = Darwin.open(archive.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SafeZipError.cannotOpen }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SafeZipError.cannotOpen }
        _ = try readEntries(Reader(fd: fd, size: UInt64(info.st_size)), destination: nil, limits: limits)
    }

    /// `onWrite` (tests) gets the bytes written so far for the current entry after each write.
    /// Seams for failures that cannot be provoked from outside (tests).
    struct Hooks {
        /// `readdir` for every directory listing (emptiness check and cleanup).
        var readDirectory: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>? = { readdir($0) }
        /// Opens the just-made (or existing) destination under its parent's descriptor.
        var openDestination: (Int32, String) -> Int32 = { openat($0, $1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    static func extract(
        archive: URL, to destination: URL, limits: Limits, onWrite: ((UInt64) -> Void)?, hooks: Hooks = Hooks()
    ) throws -> [String] {
        let fd = Darwin.open(archive.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw SafeZipError.cannotOpen }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SafeZipError.cannotOpen }
        let reader = Reader(fd: fd, size: UInt64(info.st_size))

        let entries = try readEntries(reader, destination: destination, limits: limits)
        let target = try openDestination(destination, hooks)
        defer {
            Darwin.close(target.root)
            Darwin.close(target.parent)
        }
        do {
            var total: UInt64 = 0
            for entry in entries {
                try write(entry, from: reader, root: target.root, limits: limits, total: &total, onWrite: onWrite)
            }
        } catch let refusal as SafeZipError {
            do {
                try discard(target, hooks)
            } catch {
                throw SafeZipError.cleanupFailed(after: refusal)
            }
            throw refusal
        }
        return entries.map(\.path)
    }

    // MARK: - Reading the directory

    private static let endSignature: UInt32 = 0x0605_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50
    private static let descriptorSignature: UInt32 = 0x0807_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    /// Traditional, strong and central-directory encryption.
    private static let encryptionFlags: UInt16 = 0x0001 | 0x0040 | 0x2000
    /// Deflate options (bits 1, 2), data descriptor (3), UTF-8 names (11).
    private static let allowedFlags: UInt16 = 0x0002 | 0x0004 | 0x0008 | 0x0800
    /// MS-DOS/FAT, Unix, Windows NTFS, VFAT, OS X: the systems whose external attributes are the
    /// DOS bits (low 16) and, when set, a Unix mode (high 16).
    private static let knownCreators: Set<UInt8> = [0, 3, 10, 14, 19]

    struct Entry {
        var path: String
        var components: [String]
        var nameBytes: [UInt8]
        var isDirectory: Bool
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localOffset: UInt64
        var dataStart: UInt64 = 0
        var end: UInt64 = 0
    }

    /// `destination` nil (a check only) skips the full-path length test.
    static func readEntries(_ reader: Reader, destination: URL?, limits: Limits) throws -> [Entry] {
        guard reader.size >= 22 else { throw SafeZipError.notAZip }
        let tailLength = Int(min(reader.size, 22 + 0xFFFF))
        let tailStart = reader.size - UInt64(tailLength)
        let tail = try reader.read(at: tailStart, count: tailLength)
        var candidates: [Int] = []
        for i in stride(from: tailLength - 22, through: 0, by: -1)
        where u32(tail, i) == endSignature && i + 22 + Int(u16(tail, i + 20)) == tailLength {
            candidates.append(i)
        }
        guard let end = candidates.first else { throw SafeZipError.notAZip }
        guard candidates.count == 1 else { throw SafeZipError.multipleEndRecords }
        if tailLength - (end + 22) >= 4 {
            for i in (end + 22)...(tailLength - 4) where u32(tail, i) == endSignature {
                throw SafeZipError.multipleEndRecords
            }
        }
        let endOffset = tailStart + UInt64(end)

        let disk = u16(tail, end + 4), directoryDisk = u16(tail, end + 6)
        let entriesOnDisk = u16(tail, end + 8), count = u16(tail, end + 10)
        let directorySize = u32(tail, end + 12), directoryOffset = u32(tail, end + 16)
        guard disk != 0xFFFF, directoryDisk != 0xFFFF, entriesOnDisk != 0xFFFF, count != 0xFFFF,
              directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { throw SafeZipError.zip64 }
        guard disk == 0, directoryDisk == 0, entriesOnDisk == count else { throw SafeZipError.multiDisk }
        guard Int(count) <= limits.maxEntries else { throw SafeZipError.tooManyEntries(limits.maxEntries) }
        let directoryStart = UInt64(directoryOffset)
        guard directoryStart + UInt64(directorySize) == endOffset else {
            if endOffset >= 20, u32(try reader.read(at: endOffset - 20, count: 4), 0) == zip64LocatorSignature {
                throw SafeZipError.zip64
            }
            throw SafeZipError.directoryNotAtEnd
        }
        guard Int(directorySize) <= limits.maxDirectoryBytes else { throw SafeZipError.directoryTooLarge }
        let directory = try reader.read(at: directoryStart, count: Int(directorySize))

        var entries: [Entry] = []
        var names = NameTable(limits: limits)
        var total: UInt64 = 0
        var position = 0
        for _ in 0..<Int(count) {
            guard position + 46 <= directory.count, u32(directory, position) == centralSignature else {
                throw SafeZipError.damaged("the central directory is damaged")
            }
            let madeBy = u16(directory, position + 4)
            let flags = u16(directory, position + 8), method = u16(directory, position + 10)
            let crc = u32(directory, position + 16)
            let compressed = u32(directory, position + 20), size = u32(directory, position + 24)
            let nameLength = Int(u16(directory, position + 28)), extraLength = Int(u16(directory, position + 30))
            let commentLength = Int(u16(directory, position + 32)), diskStart = u16(directory, position + 34)
            let attributes = u32(directory, position + 38), offset = u32(directory, position + 42)
            let nameStart = position + 46, extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw SafeZipError.damaged("the central directory is damaged") }
            position = next

            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF, diskStart != 0xFFFF else {
                throw SafeZipError.zip64
            }
            try checkExtra(directory, extraStart..<(extraStart + extraLength))
            guard diskStart == 0 else { throw SafeZipError.multiDisk }
            guard flags & encryptionFlags == 0 else { throw SafeZipError.encrypted }
            guard flags & ~allowedFlags == 0 else { throw SafeZipError.unsupportedFlags(flags & ~allowedFlags) }
            guard method == 0 || method == 8 else { throw SafeZipError.unsupportedMethod(method) }
            let creator = UInt8(madeBy >> 8)
            guard knownCreators.contains(creator) else { throw SafeZipError.unsupportedCreator(creator) }

            let nameBytes = Array(directory[nameStart..<extraStart])
            let name = try validatedName(nameBytes, limits: limits)
            let isDirectory = name.hasSuffix("/")
            let path = isDirectory ? String(name.dropLast()) : name
            let components = try validatedComponents(path, destination: destination)
            try checkType(attributes, isDirectory: isDirectory)
            if isDirectory {
                guard compressed == 0, size == 0, crc == 0 else { throw SafeZipError.damaged("a folder entry holds data") }
            }
            guard UInt64(size) <= limits.maxEntryBytes else { throw SafeZipError.entryTooLarge(limits.maxEntryBytes) }
            total += UInt64(size)
            guard total <= limits.maxTotalBytes else { throw SafeZipError.totalTooLarge(limits.maxTotalBytes) }
            guard method != 0 || compressed == size else { throw SafeZipError.sizeMismatch }
            try names.add(nameBytes: nameBytes, components: components, isDirectory: isDirectory)

            entries.append(Entry(
                path: path, components: components, nameBytes: nameBytes, isDirectory: isDirectory, flags: flags,
                method: method, crc: crc, compressedSize: UInt64(compressed), size: UInt64(size), localOffset: UInt64(offset)))
        }
        guard position == directory.count else { throw SafeZipError.directoryNotAtEnd }

        for index in entries.indices {
            try readLocalHeader(&entries[index], reader, directoryStart: directoryStart)
        }
        var expected: UInt64 = 0
        for entry in entries.sorted(by: { $0.localOffset < $1.localOffset }) {
            guard entry.localOffset == expected else { throw SafeZipError.layoutMismatch }
            expected = entry.end
        }
        guard expected == directoryStart else { throw SafeZipError.layoutMismatch }
        return entries
    }

    private static func readLocalHeader(_ entry: inout Entry, _ reader: Reader, directoryStart: UInt64) throws {
        let outside = SafeZipError.damaged("an entry lies outside the archive")
        guard entry.localOffset <= directoryStart, directoryStart - entry.localOffset >= 30 else { throw outside }
        let header = try reader.read(at: entry.localOffset, count: 30)
        guard u32(header, 0) == localSignature else { throw SafeZipError.damaged("a local header is missing") }
        guard u16(header, 6) == entry.flags else { throw SafeZipError.localHeaderMismatch("flags") }
        guard u16(header, 8) == entry.method else { throw SafeZipError.localHeaderMismatch("method") }
        let local = (u32(header, 14), u32(header, 18), u32(header, 22))
        let nameLength = Int(u16(header, 26)), extraLength = Int(u16(header, 28))
        let afterHeader = entry.localOffset + 30
        guard afterHeader + UInt64(nameLength + extraLength) <= directoryStart else { throw outside }
        let variable = try reader.read(at: afterHeader, count: nameLength + extraLength)
        guard Array(variable[0..<nameLength]) == entry.nameBytes else { throw SafeZipError.localHeaderMismatch("name") }
        try checkExtra(variable, nameLength..<variable.count)
        entry.dataStart = afterHeader + UInt64(nameLength + extraLength)
        guard entry.compressedSize <= directoryStart - entry.dataStart else { throw outside }

        let central = (entry.crc, UInt32(entry.compressedSize), UInt32(entry.size))
        var end = entry.dataStart + entry.compressedSize
        if entry.flags & 8 == 0 {
            guard local == central else { throw SafeZipError.localHeaderMismatch("sizes") }
        } else {
            guard local == (0, 0, 0) || local == central else { throw SafeZipError.localHeaderMismatch("sizes") }
            let descriptor = try reader.read(at: end, count: Int(min(16, directoryStart - end)))
            func matches(at i: Int) -> Bool {
                i + 12 <= descriptor.count
                    && (u32(descriptor, i), u32(descriptor, i + 4), u32(descriptor, i + 8)) == central
            }
            if descriptor.count >= 16, u32(descriptor, 0) == descriptorSignature, matches(at: 4) {
                end += 16
            } else if matches(at: 0) {
                end += 12
            } else {
                throw SafeZipError.dataDescriptorMismatch
            }
        }
        entry.end = end
    }

    /// Extra fields must be well-formed; a ZIP64 field (0x0001) is refused.
    private static func checkExtra(_ bytes: [UInt8], _ range: Range<Int>) throws {
        var i = range.lowerBound
        while i < range.upperBound {
            guard range.upperBound - i >= 4 else { throw SafeZipError.damaged("an extra field is damaged") }
            let id = u16(bytes, i), length = Int(u16(bytes, i + 2))
            guard range.upperBound - (i + 4) >= length else { throw SafeZipError.damaged("an extra field is damaged") }
            if id == 0x0001 { throw SafeZipError.zip64 }
            i += 4 + length
        }
    }

    /// Low 16 bits: DOS/Windows attributes (any creator). High 16 bits, when set: a Unix mode,
    /// whatever the creator says (a non-Unix creator cannot smuggle a link type in).
    private static func checkType(_ attributes: UInt32, isDirectory: Bool) throws {
        let mode = attributes >> 16
        if mode != 0 {
            switch mode & 0xF000 {
            case 0xA000: throw SafeZipError.symbolicLink
            case 0x4000: guard isDirectory else { throw SafeZipError.specialFile }
            case 0x8000: guard !isDirectory else { throw SafeZipError.specialFile }
            case 0: break
            default: throw SafeZipError.specialFile
            }
        }
        let dos = attributes & 0xFFFF
        if dos & 0x0400 != 0 { throw SafeZipError.symbolicLink }  // reparse point (link, junction)
        if dos & (0x0040 | 0x0008) != 0 { throw SafeZipError.specialFile }  // device, volume label
        if dos & 0x0010 != 0, !isDirectory { throw SafeZipError.specialFile }
    }

    private static func validatedName(_ bytes: [UInt8], limits: Limits) throws -> String {
        guard !bytes.isEmpty else { throw SafeZipError.unsafePath("empty") }
        guard bytes.count <= limits.maxNameBytes else { throw SafeZipError.unsafePath("too long") }
        guard let name = String(validating: bytes, as: UTF8.self) else { throw SafeZipError.unsafePath("not UTF-8") }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw SafeZipError.unsafePath("control character")
        }
        guard !name.contains("\\") else { throw SafeZipError.unsafePath("backslash") }
        guard !name.hasPrefix("/") else { throw SafeZipError.unsafePath("absolute") }
        return name
    }

    private static func validatedComponents(_ path: String, destination: URL?) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for component in components {
            guard !component.isEmpty else { throw SafeZipError.unsafePath("empty part") }
            guard component != ".", component != ".." else { throw SafeZipError.unsafePath("..") }
            guard component.utf8.count <= Int(NAME_MAX) else { throw SafeZipError.unsafePath("too long") }
        }
        let first = Array(components[0].utf8)
        if first.count >= 2, first[1] == UInt8(ascii: ":"), (first[0] | 0x20) >= UInt8(ascii: "a"), (first[0] | 0x20) <= UInt8(ascii: "z") {
            throw SafeZipError.unsafePath("drive letter")
        }
        guard (destination?.path.utf8.count ?? 0) + 1 + path.utf8.count < Int(PATH_MAX) else {
            throw SafeZipError.unsafePath("too long")
        }
        return components
    }

    /// Names as APFS compares them: Unicode case folding on NFC, one trie node per folder or
    /// file (each path part is folded and looked up once; nothing is copied per prefix). Swift's
    /// `String` equality is canonical equivalence, so exact names and spellings are compared as
    /// UTF-8 bytes. Counts every folder, explicit or implied, against `maxFolders`.
    private struct NameTable {
        struct Node {
            var children: [String: Int] = [:]
            var spelling: [UInt8]
            var isFile: Bool
            var isExplicitFolder: Bool
        }

        let limits: Limits
        var nodes = [Node(spelling: [], isFile: false, isExplicitFolder: false)]
        var exact: Set<[UInt8]> = []
        var folders = 0

        init(limits: Limits) { self.limits = limits }

        static func fold(_ s: String) -> String {
            s.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
                .precomposedStringWithCanonicalMapping
        }

        mutating func add(nameBytes: [UInt8], components: [String], isDirectory: Bool) throws {
            guard components.count <= limits.maxDepth else { throw SafeZipError.tooDeep(limits.maxDepth) }
            guard exact.insert(nameBytes).inserted else { throw SafeZipError.duplicateName }
            var node = 0
            for (n, component) in components.enumerated() {
                let last = n == components.count - 1
                let isFile = last && !isDirectory
                let key = Self.fold(component)
                let spelling = Array(component.utf8)
                if let child = nodes[node].children[key] {
                    // A file met again, a file where a folder is, or a folder spelled another way.
                    guard !nodes[child].isFile, !isFile, nodes[child].spelling == spelling else {
                        throw SafeZipError.nameCollision
                    }
                    if last {
                        guard !nodes[child].isExplicitFolder else { throw SafeZipError.nameCollision }
                        nodes[child].isExplicitFolder = true
                    }
                    node = child
                } else {
                    if !isFile {
                        folders += 1
                        guard folders <= limits.maxFolders else { throw SafeZipError.tooManyFolders(limits.maxFolders) }
                    }
                    nodes.append(Node(spelling: spelling, isFile: isFile, isExplicitFolder: last && isDirectory))
                    nodes[node].children[key] = nodes.count - 1
                    node = nodes.count - 1
                }
            }
        }
    }

    // MARK: - Writing

    /// The destination, held by descriptors: created and opened under its parent's descriptor,
    /// and removed only through descriptors, so a path swapped for a link later is never followed.
    private struct Target {
        let parent: Int32
        let name: String
        let root: Int32
        let created: Bool
        let device: dev_t
        let inode: ino_t
    }

    private static func openDestination(_ destination: URL, _ hooks: Hooks) throws -> Target {
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { throw SafeZipError.writeFailed(EINVAL) }
        let parentURL = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw SafeZipError.writeFailed(errno) }
        var created = false
        if mkdirat(parent, name, 0o700) == 0 {
            created = true
        } else if errno != EEXIST {
            let code = errno
            Darwin.close(parent)
            throw SafeZipError.writeFailed(code)
        }
        let root = hooks.openDestination(parent, name)
        var info = stat()
        guard root >= 0, fstat(root, &info) == 0 else {
            let code = errno
            if root >= 0 { Darwin.close(root) }
            // The folder just made is empty: AT_REMOVEDIR removes nothing else under that name.
            if created { _ = unlinkat(parent, name, AT_REMOVEDIR) }
            Darwin.close(parent)
            throw created ? SafeZipError.writeFailed(code) : SafeZipError.destinationNotEmpty
        }
        if !created, (try? names(in: root, hooks))?.isEmpty != true {
            Darwin.close(root)
            Darwin.close(parent)
            throw SafeZipError.destinationNotEmpty
        }
        return Target(parent: parent, name: name, root: root, created: created, device: info.st_dev, inode: info.st_ino)
    }

    /// Empties the destination through its descriptor; when SafeZip created it, removes it too,
    /// but only if the name still refers to that same folder.
    private static func discard(_ target: Target, _ hooks: Hooks) throws {
        try removeContents(of: target.root, hooks)
        guard target.created else { return }
        var info = stat()
        guard fstatat(target.parent, target.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == target.device, info.st_ino == target.inode,
              unlinkat(target.parent, target.name, AT_REMOVEDIR) == 0
        else { throw SafeZipError.writeFailed(errno) }
    }

    /// Removes everything below `fd` with `unlinkat`; folders are opened with `O_NOFOLLOW`, links
    /// are unlinked, never followed.
    private static func removeContents(of fd: Int32, _ hooks: Hooks) throws {
        for name in try names(in: fd, hooks) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SafeZipError.writeFailed(errno) }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw SafeZipError.writeFailed(errno) }
                defer { Darwin.close(child) }
                try removeContents(of: child, hooks)
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw SafeZipError.writeFailed(errno) }
            } else {
                guard unlinkat(fd, name, 0) == 0 else { throw SafeZipError.writeFailed(errno) }
            }
        }
    }

    /// The names in the folder `fd`; a failed listing is `writeFailed` (never a short list).
    private static func names(in fd: Int32, _ hooks: Hooks) throws -> [String] {
        do {
            return try TemporaryTree.names(in: fd, read: hooks.readDirectory)
        } catch let failure as TemporaryTree.ListingFailure {
            throw SafeZipError.writeFailed(failure.code)
        }
    }

    private static func openFolder(_ name: String, in parent: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(parent, name, flags)
        if fd < 0, errno == ENOENT {
            guard mkdirat(parent, name, 0o755) == 0 || errno == EEXIST else { throw SafeZipError.writeFailed(errno) }
            fd = openat(parent, name, flags)
        }
        guard fd >= 0 else { throw SafeZipError.writeFailed(errno) }
        return fd
    }

    private static func write(
        _ entry: Entry, from reader: Reader, root: Int32, limits: Limits, total: inout UInt64,
        onWrite: ((UInt64) -> Void)?
    ) throws {
        var opened: [Int32] = []
        defer { for fd in opened { Darwin.close(fd) } }
        var parent = root
        for component in entry.isDirectory ? entry.components : Array(entry.components.dropLast()) {
            parent = try openFolder(component, in: parent)
            opened.append(parent)
        }
        guard !entry.isDirectory else { return }

        let fd = openat(parent, entry.components[entry.components.count - 1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw SafeZipError.writeFailed(errno) }
        defer { Darwin.close(fd) }
        var output = Output(fd: fd, declared: entry.size, limits: limits, total: total, onWrite: onWrite)
        if entry.method == 8 {
            // Even an empty deflate entry must be a finished stream (its final block's end code).
            try inflate(entry, reader, into: &output)
        } else {
            try copy(entry, reader, into: &output)
        }
        guard output.written == entry.size else { throw SafeZipError.sizeMismatch }
        guard output.crc ^ 0xFFFF_FFFF == entry.crc else { throw SafeZipError.crcMismatch }
        total = output.total
    }

    private static let chunk = 1 << 16

    private static func copy(_ entry: Entry, _ reader: Reader, into output: inout Output) throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var offset = entry.dataStart
        var remaining = entry.compressedSize
        while remaining > 0 {
            let n = Int(min(UInt64(chunk), remaining))
            try reader.read(into: buffer, at: offset, count: n)
            try output.emit(UnsafeRawBufferPointer(start: buffer, count: n))
            offset += UInt64(n)
            remaining -= UInt64(n)
        }
    }

    /// Streams the entry's deflate data through `compression_stream`. Input is topped up so the
    /// decoder always has up to `chunk` bytes; FINALIZE is set once the last compressed byte is
    /// in the buffer (`compression.h`: without it a truncated stream would make no progress).
    private static func inflate(_ entry: Entry, _ reader: Reader, into output: inout Output) throws {
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let decoded = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer {
            input.deallocate()
            decoded.deallocate()
            stream.deallocate()
        }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SafeZipError.damaged("the decompressor could not start")
        }
        defer { compression_stream_destroy(stream) }

        var offset = entry.dataStart
        var remaining = entry.compressedSize
        var buffered = 0
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
        while true {
            if remaining > 0, buffered < chunk {
                let start = stream.pointee.src_ptr
                if buffered > 0, start != UnsafePointer(input) { memmove(input, start, buffered) }
                let n = Int(min(UInt64(chunk - buffered), remaining))
                try reader.read(into: UnsafeMutableRawPointer(input + buffered), at: offset, count: n)
                offset += UInt64(n)
                remaining -= UInt64(n)
                buffered += n
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = buffered
            }
            stream.pointee.dst_ptr = decoded
            stream.pointee.dst_size = chunk
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let consumed = buffered - stream.pointee.src_size
            buffered = stream.pointee.src_size
            let produced = chunk - stream.pointee.dst_size
            guard status != COMPRESSION_STATUS_ERROR else { throw SafeZipError.damaged("the compressed data is damaged") }
            if produced > 0 { try output.emit(UnsafeRawBufferPointer(start: decoded, count: produced)) }
            if status == COMPRESSION_STATUS_END {
                guard buffered == 0, remaining == 0 else { throw SafeZipError.damaged("data follows the compressed stream") }
                return
            }
            if consumed == 0, produced == 0, remaining == 0 || buffered == chunk {
                throw SafeZipError.damaged("the compressed data is truncated")
            }
        }
    }

    /// One entry's output: capped before every write, CRC-32 over what was written.
    private struct Output {
        let fd: Int32
        let declared: UInt64
        let limits: Limits
        var total: UInt64
        let onWrite: ((UInt64) -> Void)?
        var written: UInt64 = 0
        var crc: UInt32 = 0xFFFF_FFFF

        init(fd: Int32, declared: UInt64, limits: Limits, total: UInt64, onWrite: ((UInt64) -> Void)?) {
            self.fd = fd
            self.declared = declared
            self.limits = limits
            self.total = total
            self.onWrite = onWrite
        }

        mutating func emit(_ bytes: UnsafeRawBufferPointer) throws {
            let n = UInt64(bytes.count)
            guard written + n <= declared else { throw SafeZipError.sizeMismatch }
            guard written + n <= limits.maxEntryBytes else { throw SafeZipError.entryTooLarge(limits.maxEntryBytes) }
            guard total + n <= limits.maxTotalBytes else { throw SafeZipError.totalTooLarge(limits.maxTotalBytes) }
            crc = CRC32.update(crc, bytes)
            var done = 0
            while done < bytes.count {
                let result = Darwin.write(fd, bytes.baseAddress! + done, bytes.count - done)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SafeZipError.writeFailed(errno)
                }
                done += result
            }
            written += n
            total += n
            onWrite?(written)
        }
    }

    // MARK: - Bytes

    struct Reader {
        let fd: Int32
        let size: UInt64

        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            guard count > 0 else { return bytes }
            try bytes.withUnsafeMutableBytes { try read(into: $0.baseAddress!, at: offset, count: count) }
            return bytes
        }

        func read(into buffer: UnsafeMutableRawPointer, at offset: UInt64, count: Int) throws {
            guard offset <= size, UInt64(count) <= size - offset else { throw SafeZipError.damaged("the archive is truncated") }
            var done = 0
            while done < count {
                let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SafeZipError.damaged("the archive could not be read")
                }
                guard n > 0 else { throw SafeZipError.damaged("the archive is truncated") }
                done += n
            }
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// CRC-32 (ISO-HDLC, the zip polynomial 0xEDB88320), table-driven.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = crc
        table.withUnsafeBufferPointer { t in
            for byte in bytes { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c
    }
}

public enum SafeZipError: Error, Equatable, Sendable, CustomStringConvertible {
    case cannotOpen
    case notAZip
    case multipleEndRecords
    case directoryNotAtEnd
    case directoryTooLarge
    case damaged(String)
    case zip64
    case multiDisk
    case encrypted
    case unsupportedFlags(UInt16)
    case unsupportedMethod(UInt16)
    case unsupportedCreator(UInt8)
    case localHeaderMismatch(String)
    case dataDescriptorMismatch
    case layoutMismatch
    case sizeMismatch
    case crcMismatch
    case symbolicLink
    case specialFile
    case unsafePath(String)
    case duplicateName
    case nameCollision
    case tooManyEntries(Int)
    case tooManyFolders(Int)
    case tooDeep(Int)
    case entryTooLarge(UInt64)
    case totalTooLarge(UInt64)
    case destinationNotEmpty
    case writeFailed(Int32)
    /// The archive was refused after writing began and what was written could not all be removed.
    indirect case cleanupFailed(after: SafeZipError)

    /// Kinds and limits only, never an entry name (names come from the archive).
    public var description: String {
        switch self {
        case .cannotOpen: "the archive could not be opened"
        case .notAZip: "not a zip archive"
        case .multipleEndRecords: "the archive has more than one end record"
        case .directoryNotAtEnd: "the archive's central directory does not end at its end record"
        case .directoryTooLarge: "the archive's central directory is too large"
        case .damaged(let reason): "the archive is damaged: \(reason)"
        case .zip64: "ZIP64 archives are not supported"
        case .multiDisk: "multi-part zip archives are not supported"
        case .encrypted: "the archive is encrypted"
        case .unsupportedFlags(let flags): "the archive uses unsupported options (flags 0x\(String(flags, radix: 16)))"
        case .unsupportedMethod(let method): "the archive uses an unsupported compression method (\(method))"
        case .unsupportedCreator(let system): "the archive was made on an unsupported system (\(system))"
        case .localHeaderMismatch(let field): "an entry's local header disagrees with the central directory (\(field))"
        case .dataDescriptorMismatch: "an entry's data descriptor disagrees with the central directory"
        case .layoutMismatch: "the archive's entries leave gaps or overlap"
        case .sizeMismatch: "an entry's data does not have its declared size"
        case .crcMismatch: "an entry's data does not match its checksum"
        case .symbolicLink: "the archive contains a symbolic link"
        case .specialFile: "the archive contains a special file"
        case .unsafePath(let reason): "an entry path is unsafe (\(reason))"
        case .duplicateName: "the archive names an entry twice"
        case .nameCollision: "two entries name the same file (ignoring case and Unicode normalization)"
        case .tooManyEntries(let limit): "the archive has more than \(limit) entries"
        case .tooManyFolders(let limit): "the archive has more than \(limit) folders"
        case .tooDeep(let limit): "an entry path has more than \(limit) parts"
        case .entryTooLarge(let limit): "an entry is larger than \(Self.size(limit))"
        case .totalTooLarge(let limit): "the archive expands to more than \(Self.size(limit))"
        case .destinationNotEmpty: "the extraction folder is not empty"
        case .writeFailed(let code): "the archive could not be extracted (errno \(code))"
        case .cleanupFailed(let after): "\(after); its partly extracted files could not all be removed"
        }
    }

    private static func size(_ bytes: UInt64) -> String { bytes >= 1 << 20 ? "\(bytes >> 20) MB" : "\(bytes) bytes" }
}
