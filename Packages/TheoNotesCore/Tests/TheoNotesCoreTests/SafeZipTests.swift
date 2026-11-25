// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Compression
import Darwin
import Foundation
import Testing
@testable import TheoNotesCore

/// A test-only zip writer. Every field SafeZip checks can be set to a lie: local and central
/// names, flags, sizes, CRC, data descriptor, offsets, creator system and external attributes,
/// bytes before the first entry or between the directory and its end record, and the comment.
struct TestZip {
    struct Entry {
        var name: String
        var data = Data()
        var deflate = false
        /// Raw bytes after the local header (default: `data`, deflated when `deflate`).
        var payload: Data?
        var method: UInt16?
        var flags: UInt16 = 0
        var localFlags: UInt16?
        var localName: String?
        var creator: UInt8 = 3
        var attributes: UInt32?
        var crc: UInt32?
        var size: UInt32?
        /// (crc, compressed, uncompressed) in the local header.
        var local: (UInt32, UInt32, UInt32)?
        /// (crc, compressed, uncompressed) after the data when flag bit 3 is set.
        var descriptor: (UInt32, UInt32, UInt32)?
        var offset: UInt32?
        var centralExtra = Data()
        var localExtra = Data()

        init(_ name: String, _ text: String = "", deflate: Bool = false) {
            self.name = name
            self.data = Data(text.utf8)
            self.deflate = deflate
        }

        init(_ name: String, data: Data, deflate: Bool = false) {
            self.name = name
            self.data = data
            self.deflate = deflate
        }
    }

    var entries: [Entry]
    var prefix = Data()
    var afterDirectory = Data()
    var comment = Data()
    var count: UInt16?

    init(_ entries: [Entry]) { self.entries = entries }

    static func deflated(_ data: Data) -> Data {
        let capacity = data.count + data.count / 1000 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(written > 0 || data.isEmpty)
        return out.prefix(written)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) }) }

    /// A 22-byte end record with these values (used for a second one inside the comment).
    static func endRecord(entries: UInt16, size: UInt32, offset: UInt32, commentLength: UInt16 = 0) -> Data {
        le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries) + le16(entries) + le32(size) + le32(offset) + le16(commentLength)
    }

    func bytes() -> Data {
        var out = prefix
        var central = Data()
        for entry in entries {
            let payload = entry.payload ?? (entry.deflate ? Self.deflated(entry.data) : entry.data)
            let method = entry.method ?? (entry.deflate ? 8 : 0)
            let crc = entry.crc ?? Self.crc32(entry.data)
            let size = entry.size ?? UInt32(entry.data.count)
            let compressed = UInt32(payload.count)
            let isDirectory = entry.name.hasSuffix("/")
            let attributes = entry.attributes ?? (isDirectory ? (0o40755 << 16 | 0x10) : 0o100644 << 16)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let flags = entry.flags
            let localFlags = entry.localFlags ?? flags
            let offset = entry.offset ?? UInt32(out.count)
            let local = entry.local ?? (localFlags & 8 != 0 ? (0, 0, 0) : (crc, compressed, size))

            out += Self.le32(0x0403_4B50) + Self.le16(20) + Self.le16(localFlags) + Self.le16(method)
            out += Self.le16(0) + Self.le16(0x21)
            out += Self.le32(local.0) + Self.le32(local.1) + Self.le32(local.2)
            out += Self.le16(UInt16(localName.count)) + Self.le16(UInt16(entry.localExtra.count))
            out += localName + entry.localExtra + payload
            if localFlags & 8 != 0 {
                let d = entry.descriptor ?? (crc, compressed, size)
                out += Self.le32(0x0807_4B50) + Self.le32(d.0) + Self.le32(d.1) + Self.le32(d.2)
            }

            central += Self.le32(0x0201_4B50) + Self.le16(UInt16(entry.creator) << 8 | 20) + Self.le16(20)
            central += Self.le16(flags) + Self.le16(method) + Self.le16(0) + Self.le16(0x21)
            central += Self.le32(crc) + Self.le32(compressed) + Self.le32(size)
            central += Self.le16(UInt16(name.count)) + Self.le16(UInt16(entry.centralExtra.count)) + Self.le16(0)
            central += Self.le16(0) + Self.le16(0) + Self.le32(attributes) + Self.le32(offset)
            central += name + entry.centralExtra
        }
        let directoryOffset = UInt32(out.count)
        out += central + afterDirectory
        let n = count ?? UInt16(entries.count)
        out += Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(n) + Self.le16(n)
        out += Self.le32(UInt32(central.count)) + Self.le32(directoryOffset) + Self.le16(UInt16(comment.count)) + comment
        return out
    }
}

@Suite struct SafeZipTests {
    let scratch: Scratch

    init() throws { scratch = try Scratch() }

    private var out: URL { scratch.url.appendingPathComponent("out", isDirectory: true) }

    private func archive(_ zip: TestZip, _ name: String = "a.zip") throws -> URL {
        try scratch.write(name, zip.bytes())
    }

    @discardableResult
    private func extract(_ zip: TestZip, limits: SafeZip.Limits = .imports) throws -> [String] {
        try SafeZip.extract(archive: try archive(zip), to: out, limits: limits)
    }

    /// The error, and nothing left at the destination.
    private func refusal(
        _ zip: TestZip, limits: SafeZip.Limits = .imports, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> SafeZipError? {
        let file = try archive(zip)
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try SafeZip.extract(archive: file, to: out, limits: limits)
            Issue.record("extracted, expected a refusal", sourceLocation: sourceLocation)
            return nil
        } catch let error as SafeZipError {
            #expect(!FileManager.default.fileExists(atPath: out.path), "destination left behind", sourceLocation: sourceLocation)
            return error
        }
    }

    private func read(_ relative: String) throws -> Data {
        try Data(contentsOf: out.appendingPathComponent(relative))
    }

    private func fileType(_ relative: String) -> mode_t {
        var info = stat()
        guard lstat(out.appendingPathComponent(relative).path, &info) == 0 else { return 0 }
        return info.st_mode & S_IFMT
    }

    // MARK: - Valid archives

    @Test func extractsStoredDeflatedAndDirectoryEntries() throws {
        let big = Data((0..<200_000).map { UInt8($0 % 251) })
        let paths = try extract(TestZip([
            .init("note.textbundle/", ""),
            .init("note.textbundle/text.md", "# Hello\n\nBody\n", deflate: true),
            .init("note.textbundle/assets/big.bin", data: big, deflate: true),
            .init("note.textbundle/assets/plain.txt", "stored"),
            .init("note.textbundle/assets/empty.txt", ""),
        ]))
        #expect(paths == [
            "note.textbundle", "note.textbundle/text.md", "note.textbundle/assets/big.bin",
            "note.textbundle/assets/plain.txt", "note.textbundle/assets/empty.txt",
        ])
        #expect(try read("note.textbundle/text.md") == Data("# Hello\n\nBody\n".utf8))
        #expect(try read("note.textbundle/assets/big.bin") == big)
        #expect(try read("note.textbundle/assets/plain.txt") == Data("stored".utf8))
        #expect(try read("note.textbundle/assets/empty.txt").isEmpty)
        #expect(fileType("note.textbundle") == S_IFDIR)
        #expect(fileType("note.textbundle/assets") == S_IFDIR)
        #expect(fileType("note.textbundle/text.md") == S_IFREG)
    }

    @Test func aDataDescriptorThatMatchesTheCentralDirectoryIsAccepted() throws {
        var entry = TestZip.Entry("text.md", "described", deflate: true)
        entry.flags = 8
        try extract(TestZip([entry]))
        #expect(try read("text.md") == Data("described".utf8))
    }

    private func tool(_ path: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(path) failed")
    }

    private func sourceTree() throws -> (URL, [String: Data]) {
        let files: [String: Data] = [
            "Note.textbundle/text.md": Data("# Real\n\n![](assets/pic.png)\n".utf8),
            "Note.textbundle/info.json": Data(#"{"version":2}"#.utf8),
            "Note.textbundle/assets/pic.png": Data((0..<70_000).map { UInt8(($0 * 7) % 256) }),
            "Note.textbundle/assets/zeros.bin": Data(count: 300_000),
            "Note.textbundle/assets/caf\u{E9} n\u{F6}te.txt": Data("unicode".utf8),
        ]
        let tree = try scratch.dir("src")
        for (path, data) in files { try scratch.write("src/" + path, data) }
        try FileManager.default.createDirectory(
            at: tree.appendingPathComponent("Note.textbundle/empty"), withIntermediateDirectories: true)
        return (tree, files)
    }

    @Test func aDittoArchiveExtracts() throws {
        let (tree, files) = try sourceTree()
        let zip = scratch.url.appendingPathComponent("ditto.zip")
        try tool("/usr/bin/ditto", ["-c", "-k", tree.path, zip.path], in: scratch.url)
        let paths = try SafeZip.extract(archive: zip, to: out, limits: .imports)
        for (path, data) in files { #expect(try read(path) == data, "\(path)") }
        #expect(fileType("Note.textbundle/empty") == S_IFDIR)
        #expect(paths.contains("Note.textbundle/text.md"))
    }

    @Test func aZipToolArchiveExtracts() throws {
        let (tree, files) = try sourceTree()
        let zip = scratch.url.appendingPathComponent("zip.zip")
        try tool("/usr/bin/zip", ["-q", "-r", zip.path, "."], in: tree)
        try SafeZip.extract(archive: zip, to: out, limits: .imports)
        for (path, data) in files { #expect(try read(path) == data, "\(path)") }
        #expect(fileType("Note.textbundle/empty") == S_IFDIR)
    }

    // MARK: - Structure

    @Test func aLocalNameThatDiffersFromTheCentralNameIsRefused() throws {
        var entry = TestZip.Entry("text.md", "x")
        entry.localName = "../../escape"
        #expect(try refusal(TestZip([entry])) == .localHeaderMismatch("name"))
        var sameLength = TestZip.Entry("text.md", "x")
        sameLength.localName = "TEXT.md"
        #expect(try refusal(TestZip([sameLength])) == .localHeaderMismatch("name"))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    @Test func twoEndRecordsAreRefused() throws {
        // A second, self-consistent end record as the last 22 bytes of the real one's comment.
        var zip = TestZip([.init("text.md", "x")])
        zip.comment = Data("note".utf8) + TestZip.endRecord(entries: 0, size: 0, offset: 0)
        #expect(try refusal(zip) == .multipleEndRecords)
        // An end-record signature anywhere in the comment.
        var signature = TestZip([.init("text.md", "x")])
        signature.comment = Data("ab".utf8) + TestZip.le32(0x0605_4B50) + Data("cd".utf8)
        #expect(try refusal(signature) == .multipleEndRecords)
        // A plain comment is fine.
        var plain = TestZip([.init("text.md", "x")])
        plain.comment = Data("made by hand".utf8)
        try extract(plain)
    }

    @Test func aDirectoryThatDoesNotEndAtTheEndRecordIsRefused() throws {
        var gap = TestZip([.init("text.md", "x")])
        gap.afterDirectory = Data(count: 8)
        #expect(try refusal(gap) == .directoryNotAtEnd)
    }

    @Test func outOfRangeOffsetsAreRefused() throws {
        var far = TestZip.Entry("text.md", "x")
        far.offset = 0x7FFF_FFF0
        #expect(try refusal(TestZip([far])) != nil)
        var intoDirectory = TestZip.Entry("text.md", "x")
        intoDirectory.offset = 40
        #expect(try refusal(TestZip([intoDirectory])) != nil)
        // A huge declared compressed size whose data would run past the directory.
        var long = TestZip.Entry("text.md", "x")
        long.local = (TestZip.crc32(Data("x".utf8)), 0x0FFF_FFFF, 1)
        #expect(try refusal(TestZip([long])) != nil)
        // An entry count larger than the directory holds.
        var count = TestZip([.init("text.md", "x")])
        count.count = 3
        #expect(try refusal(count) != nil)
    }

    @Test func bytesBeforeOrBetweenEntriesAreRefused() throws {
        var prefixed = TestZip([.init("text.md", "x")])
        prefixed.prefix = Data("MZ stub".utf8)
        #expect(try refusal(prefixed) == .layoutMismatch)
        // Two central entries pointing at one local header (overlap).
        var a = TestZip.Entry("a.txt", "same")
        a.localName = "a.txt"
        var b = TestZip.Entry("a.txt", "same")
        b.offset = 0
        #expect(try refusal(TestZip([a, b])) != nil)
    }

    @Test func encryptionAndUnsupportedMethodsAreRefused() throws {
        var encrypted = TestZip.Entry("text.md", "x")
        encrypted.flags = 1
        #expect(try refusal(TestZip([encrypted])) == .encrypted)
        var strong = TestZip.Entry("text.md", "x")
        strong.flags = 0x40
        #expect(try refusal(TestZip([strong])) == .encrypted)
        var bzip = TestZip.Entry("text.md", "x")
        bzip.method = 12
        #expect(try refusal(TestZip([bzip])) == .unsupportedMethod(12))
        var patched = TestZip.Entry("text.md", "x")
        patched.flags = 0x20
        #expect(try refusal(TestZip([patched])) == .unsupportedFlags(0x20))
        var flagsDiffer = TestZip.Entry("text.md", "x")
        flagsDiffer.localFlags = 0x800
        #expect(try refusal(TestZip([flagsDiffer])) == .localHeaderMismatch("flags"))
    }

    @Test func zip64IsRefused() throws {
        var marker = TestZip([.init("text.md", "x")])
        marker.count = 0xFFFF
        #expect(try refusal(marker) == .zip64)
        var extra = TestZip.Entry("text.md", "x")
        extra.centralExtra = TestZip.le16(0x0001) + TestZip.le16(8) + Data(count: 8)
        #expect(try refusal(TestZip([extra])) == .zip64)
    }

    @Test func dataDescriptorsWithUnderstatedSizesAreRefused() throws {
        let data = Data("ten bytes!".utf8)
        let crc = TestZip.crc32(data)
        var understated = TestZip.Entry("text.md", data: data)
        understated.flags = 8
        understated.descriptor = (crc, 4, 4)
        #expect(try refusal(TestZip([understated])) == .dataDescriptorMismatch)
        var wrongCRC = TestZip.Entry("text.md", data: data)
        wrongCRC.flags = 8
        wrongCRC.descriptor = (crc ^ 1, 10, 10)
        #expect(try refusal(TestZip([wrongCRC])) == .dataDescriptorMismatch)
        // Local sizes that are neither zero nor the central ones.
        var local = TestZip.Entry("text.md", data: data)
        local.flags = 8
        local.local = (crc, 4, 4)
        #expect(try refusal(TestZip([local])) == .localHeaderMismatch("sizes"))
        // Without bit 3 the local header must match exactly.
        var plain = TestZip.Entry("text.md", data: data)
        plain.local = (crc, 10, 4)
        #expect(try refusal(TestZip([plain])) == .localHeaderMismatch("sizes"))
    }

    @Test func aCRCMismatchIsRefusedAndNothingStays() throws {
        var entry = TestZip.Entry("text.md", "hello", deflate: true)
        entry.crc = 0xDEAD_BEEF
        #expect(try refusal(TestZip([.init("first.txt", "ok"), entry])) == .crcMismatch)
    }

    @Test func aWrongDeclaredSizeIsRefused() throws {
        var short = TestZip.Entry("text.md", "hello world", deflate: true)
        short.size = 20
        #expect(try refusal(TestZip([short])) == .sizeMismatch)
        var corrupt = TestZip.Entry("text.md", "hello world")
        corrupt.method = 8
        corrupt.payload = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(try refusal(TestZip([corrupt])) != nil)
    }

    @Test func anEmptyDeflateEntryMustStillBeAFinishedStream() throws {
        var missing = TestZip.Entry("empty.txt", "")
        missing.method = 8
        missing.payload = Data()
        let error = try refusal(TestZip([missing]))
        guard case .damaged? = error else {
            Issue.record("an empty deflate entry without its end block: \(String(describing: error))")
            return
        }
        var ended = TestZip.Entry("empty.txt", "")
        ended.method = 8
        ended.payload = Data([0x03, 0x00])  // one final fixed-Huffman block holding only its end code
        try extract(TestZip([ended]))
        #expect(try read("empty.txt").isEmpty)
    }

    @Test func aDeflateBombDeclaringOneByteStopsBeforeWritingMore() throws {
        let zeros = Data(count: 64 << 20)
        var bomb = TestZip.Entry("text.md", data: zeros, deflate: true)
        bomb.size = 1
        bomb.crc = TestZip.crc32(Data([0]))
        let file = try archive(TestZip([bomb]))
        #expect(try Data(contentsOf: file).count < 1 << 20)
        var written: UInt64 = 0
        #expect(throws: SafeZipError.sizeMismatch) {
            try SafeZip.extract(archive: file, to: out, limits: .imports, onWrite: { written = max(written, $0) })
        }
        #expect(written <= 1)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func entryAndTotalCapsAreEnforced() throws {
        let entries = (0..<4).map { TestZip.Entry("f\($0).txt", "x") }
        #expect(try refusal(TestZip(entries), limits: .init(maxEntries: 3)) == .tooManyEntries(3))
        let tenK = Data(count: 10_000)
        #expect(try refusal(TestZip([.init("big.bin", data: tenK, deflate: true)]), limits: .init(maxEntryBytes: 9_999))
            == .entryTooLarge(9_999))
        let two = [TestZip.Entry("a.bin", data: tenK, deflate: true), TestZip.Entry("b.bin", data: tenK, deflate: true)]
        #expect(try refusal(TestZip(two), limits: .init(maxTotalBytes: 19_999)) == .totalTooLarge(19_999))
        try extract(TestZip(two), limits: .init(maxEntries: 2, maxEntryBytes: 10_000, maxTotalBytes: 20_000))
    }

    @Test func deepAndFolderHeavyArchivesAreRefusedQuickly() throws {
        // 10,000 empty files, each below a chain of 400 one-character folders.
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let chains = (0..<26).map { i in (0..<400).map { String(letters[(i + $0) % 26]) }.joined(separator: "/") }
        let deep = (0..<10_000).map { i in TestZip.Entry(chains[i % 26] + "/f\(i)", "") }
        let deepFile = try archive(TestZip(deep), "deep.zip")
        let start = ContinuousClock.now
        #expect(throws: SafeZipError.tooDeep(64)) { try SafeZip.extract(archive: deepFile, to: out, limits: .imports) }
        #expect(ContinuousClock.now - start < .seconds(20), "not a perf gate: a refusal must not walk the tree")
        #expect(!FileManager.default.fileExists(atPath: out.path))

        // 400 files, each below its own chain of 60 folders: 24,000 folders.
        let wide = (0..<400).map { i in
            TestZip.Entry("p\(i)/" + Array(repeating: "a", count: 59).joined(separator: "/") + "/f", "")
        }
        #expect(try refusal(TestZip(wide)) == .tooManyFolders(20_000))

        let limits = SafeZip.Limits(maxFolders: 2, maxDepth: 3)
        try extract(TestZip([.init("a/b/c.txt", "x"), .init("a/d.txt", "y")]), limits: limits)
        try FileManager.default.removeItem(at: out)
        #expect(try refusal(TestZip([.init("a/b/c/d.txt", "x")]), limits: limits) == .tooDeep(3))
        #expect(try refusal(TestZip([.init("a/b/c.txt", "x"), .init("e/f.txt", "y")]), limits: limits) == .tooManyFolders(2))
        #expect(try refusal(TestZip([.init("a/", ""), .init("b/", ""), .init("c/", "")]), limits: limits) == .tooManyFolders(2))
    }

    // MARK: - Types

    @Test func symbolicLinksAreRefusedForEveryCreator() throws {
        var unix = TestZip.Entry("assets/leak.png", "/etc/passwd")
        unix.attributes = 0o120777 << 16
        #expect(try refusal(TestZip([unix])) == .symbolicLink)
        var macOS = TestZip.Entry("assets/leak.png", "/etc/passwd")
        macOS.creator = 19
        macOS.attributes = 0o120777 << 16
        #expect(try refusal(TestZip([macOS])) == .symbolicLink)
        var dos = TestZip.Entry("assets/leak.png", "/etc/passwd")
        dos.creator = 0
        dos.attributes = 0o120777 << 16
        #expect(try refusal(TestZip([dos])) == .symbolicLink)
        var ntfs = TestZip.Entry("assets/leak.png", "C:\\secret")
        ntfs.creator = 10
        ntfs.attributes = 0x0400
        #expect(try refusal(TestZip([ntfs])) == .symbolicLink)
        var other = TestZip.Entry("text.md", "x")
        other.creator = 7
        #expect(try refusal(TestZip([other])) == .unsupportedCreator(7))
    }

    @Test func specialFilesAreRefused() throws {
        for mode in [0o010644, 0o020644, 0o060644, 0o140644] as [UInt32] {
            var entry = TestZip.Entry("dev", "")
            entry.attributes = mode << 16
            #expect(try refusal(TestZip([entry])) == .specialFile, "\(String(mode, radix: 8))")
        }
        var device = TestZip.Entry("dev", "")
        device.creator = 0
        device.attributes = 0x0040
        #expect(try refusal(TestZip([device])) == .specialFile)
        var folderFile = TestZip.Entry("text.md", "x")
        folderFile.attributes = 0o40755 << 16
        #expect(try refusal(TestZip([folderFile])) == .specialFile)
        var dataInFolder = TestZip.Entry("dir/", "x")
        dataInFolder.attributes = 0o40755 << 16
        #expect(try refusal(TestZip([dataInFolder])) != nil)
    }

    // MARK: - Names

    @Test func unsafeNamesAreRefused() throws {
        let long = String(repeating: "a", count: 256)
        let names = [
            "../escape", "a/../../escape", "a/..", "./a", "/etc/x", "a\\b", "..\\x", "C:/x", "c:x",
            "a\u{0}b", "a\u{7}b", "a\u{1B}b", "a\u{85}b", "a//b", "//x", "", long, "d/" + long + "/x",
            String(repeating: "abc/", count: 300) + "x",
        ]
        for name in names {
            let error = try refusal(TestZip([.init(name, "x")]))
            guard case .unsafePath = error else {
                Issue.record("\(name.debugDescription): \(String(describing: error))")
                continue
            }
        }
        var invalidUTF8 = TestZip.Entry("ab", "x")
        invalidUTF8.name = "a\u{FFFD}"
        var raw = TestZip([invalidUTF8]).bytes()
        // Swap the U+FFFD bytes in both headers for a lone continuation byte, keeping lengths.
        let replacement = Data("\u{FFFD}".utf8)
        while let range = raw.range(of: replacement) { raw.replaceSubrange(range, with: Data([0x80, 0x80, 0x80])) }
        let file = try scratch.write("utf8.zip", raw)
        #expect(throws: SafeZipError.unsafePath("not UTF-8")) {
            try SafeZip.extract(archive: file, to: out, limits: .imports)
        }
    }

    @Test func collisionsAndDuplicatesAreRefused() throws {
        #expect(try refusal(TestZip([.init("a.txt", "1"), .init("a.txt", "2")])) == .duplicateName)
        #expect(try refusal(TestZip([.init("assets/PIC.png", "1"), .init("assets/pic.png", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("Assets/a.png", "1"), .init("assets/b.png", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("\u{E9}.png", "1"), .init("e\u{301}.png", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("STRASSE.txt", "1"), .init("stra\u{DF}e.txt", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("a", "file"), .init("a/b", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("a/b", "2"), .init("A", "file")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("d/", ""), .init("d/", "")])) == .duplicateName)
        #expect(try refusal(TestZip([.init("d/", ""), .init("D/", "")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("\u{E9}/a", "1"), .init("e\u{301}/b", "2")])) == .nameCollision)
        #expect(try refusal(TestZip([.init("d/x.txt", "x"), .init("D/y.txt", "y")])) == .nameCollision)
        // A folder entry after a file inside it is the same folder, not a collision.
        try extract(TestZip([.init("d/x.txt", "x"), .init("d/", ""), .init("d/y.txt", "y")]))
        #expect(try read("d/y.txt") == Data("y".utf8))
    }

    // MARK: - Destination

    @Test func theDestinationMustBeNewOrAnEmptyFolder() throws {
        let file = try archive(TestZip([.init("text.md", "x")]))
        try scratch.write("out/existing.txt", "keep")
        #expect(throws: SafeZipError.destinationNotEmpty) {
            try SafeZip.extract(archive: file, to: out, limits: .imports)
        }
        #expect(try read("existing.txt") == Data("keep".utf8))
        try FileManager.default.removeItem(at: out)

        let elsewhere = try scratch.dir("elsewhere")
        try FileManager.default.createSymbolicLink(at: out, withDestinationURL: elsewhere)
        #expect(throws: SafeZipError.self) { try SafeZip.extract(archive: file, to: out, limits: .imports) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        try FileManager.default.removeItem(at: out)

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try SafeZip.extract(archive: file, to: out, limits: .imports)
        #expect(try read("text.md") == Data("x".utf8))
    }

    /// After the first file is written, the destination is moved away and a symlink to a victim
    /// folder (holding a file of the same name) takes its place; the next entry fails its CRC.
    @Test(arguments: [false, true])
    func cleanupNeverFollowsASymlinkSwappedInForTheDestination(destinationExisted: Bool) throws {
        let victim = try scratch.dir("victim")
        try scratch.write("victim/keep.txt", "victim's")
        var bad = TestZip.Entry("b.txt", "second")
        bad.crc = 1
        let file = try archive(TestZip([.init("keep.txt", "first"), bad]))
        let moved = scratch.url.appendingPathComponent("moved")
        if destinationExisted { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var swapped = false
        let error = #expect(throws: SafeZipError.self) {
            try SafeZip.extract(archive: file, to: out, limits: .imports, onWrite: { _ in
                guard !swapped else { return }
                swapped = true
                try? FileManager.default.moveItem(at: out, to: moved)
                try? FileManager.default.createSymbolicLink(at: out, withDestinationURL: victim)
            })
        }
        #expect(swapped)
        // Created by SafeZip: the folder it made is no longer at the path, which is an error.
        // Existing: only its contents were SafeZip's, and they are gone.
        #expect(error == (destinationExisted ? .crcMismatch : .cleanupFailed(after: .crcMismatch)))
        #expect(try String(contentsOf: victim.appendingPathComponent("keep.txt"), encoding: .utf8) == "victim's")
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, "removed through its descriptor")
        #expect(fileType("") == S_IFLNK || (try? FileManager.default.destinationOfSymbolicLink(atPath: out.path)) != nil)
    }

    /// `readdir` returning nil with errno set is an error, not the end of the folder: a cleanup
    /// that cannot list everything is reported (an existing destination has no final `rmdir`
    /// that would notice what was left).
    @Test func aListingThatFailsMidwayDuringCleanupIsReported() throws {
        var bad = TestZip.Entry("c.txt", "third")
        bad.crc = 1
        let file = try archive(TestZip([.init("a.txt", "1"), .init("b.txt", "2"), bad]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var hooks = SafeZip.Hooks()
        hooks.readDirectory = { dir in
            guard let entry = readdir(dir) else { return nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "b.txt" {
                errno = EIO
                return nil
            }
            return entry
        }
        #expect(throws: SafeZipError.cleanupFailed(after: .crcMismatch)) {
            try SafeZip.extract(archive: file, to: out, limits: .imports, onWrite: nil, hooks: hooks)
        }
    }

    @Test func aDestinationThatCannotBeOpenedAfterItWasMadeIsRemoved() throws {
        let file = try archive(TestZip([.init("a.txt", "1")]))
        var hooks = SafeZip.Hooks()
        hooks.openDestination = { _, _ in
            errno = EACCES
            return -1
        }
        #expect(throws: SafeZipError.writeFailed(EACCES)) {
            try SafeZip.extract(archive: file, to: out, limits: .imports, onWrite: nil, hooks: hooks)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func temporaryTreeRemovalFollowsNoLinkAndOpensLockedFolders() throws {
        let fm = FileManager.default
        let outside = try scratch.dir("outside")
        try scratch.write("outside/keep.txt", "keep")
        try scratch.write("tree/locked/inner/file.txt", "x")
        try scratch.write("tree/unreadable.txt", "y")
        try fm.createSymbolicLink(at: scratch.url.appendingPathComponent("tree/link"), withDestinationURL: outside)
        try fm.createSymbolicLink(
            at: scratch.url.appendingPathComponent("tree/locked/inner/file-link"),
            withDestinationURL: outside.appendingPathComponent("keep.txt"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratch.url.appendingPathComponent("tree/unreadable.txt").path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratch.url.appendingPathComponent("tree/locked/inner").path)
        try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: scratch.url.appendingPathComponent("tree/locked").path)

        #expect(TemporaryTree.remove(at: scratch.url.appendingPathComponent("tree")) == nil)
        #expect(!fm.fileExists(atPath: scratch.url.appendingPathComponent("tree").path))
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")

        // A link as the tree itself is unlinked, not followed; a missing tree is no error.
        try fm.createSymbolicLink(at: scratch.url.appendingPathComponent("tree"), withDestinationURL: outside)
        #expect(TemporaryTree.remove(at: scratch.url.appendingPathComponent("tree")) == nil)
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        #expect(TemporaryTree.remove(at: scratch.url.appendingPathComponent("tree")) == nil)
        #expect(TemporaryTree.remove(at: scratch.url.appendingPathComponent("no/such/tree")) == nil)
    }

    @Test func notAZipAndTruncatedArchivesAreRefused() throws {
        let garbage = try scratch.write("garbage.zip", Data(repeating: 0x41, count: 4096))
        #expect(throws: SafeZipError.notAZip) { try SafeZip.extract(archive: garbage, to: out, limits: .imports) }
        let empty = try scratch.write("empty.zip", Data())
        #expect(throws: SafeZipError.notAZip) { try SafeZip.extract(archive: empty, to: out, limits: .imports) }
        let whole = TestZip([.init("text.md", "hello", deflate: true)]).bytes()
        let truncated = try scratch.write("truncated.zip", whole.prefix(whole.count - 5))
        #expect(throws: SafeZipError.self) { try SafeZip.extract(archive: truncated, to: out, limits: .imports) }
        let missing = scratch.url.appendingPathComponent("missing.zip")
        #expect(throws: SafeZipError.cannotOpen) { try SafeZip.extract(archive: missing, to: out, limits: .imports) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func errorsDescribeTheirKind() {
        #expect("\(SafeZipError.symbolicLink)".contains("symbolic link"))
        #expect("\(SafeZipError.unsafePath(".."))".contains("path"))
        #expect("\(SafeZipError.tooManyEntries(3))".contains("entries"))
        #expect("\(SafeZipError.entryTooLarge(512 << 20))".contains("larger"))
        #expect("\(SafeZipError.totalTooLarge(1 << 30))".contains("expands"))
        #expect("\(SafeZipError.zip64)".contains("ZIP64"))
        #expect("\(SafeZipError.encrypted)".contains("encrypted"))
        #expect("\(SafeZipError.notAZip)".contains("zip"))
    }
}
