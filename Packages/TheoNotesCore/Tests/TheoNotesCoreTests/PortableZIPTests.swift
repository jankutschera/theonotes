// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import ZIPFoundation
@testable import TheoNotesCore

@Suite struct PortableZIPTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portable-zip-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func archive(_ url: URL, entries: [(String, Entry.EntryType, Data)]) throws {
        let zip = try Archive(url: url, accessMode: .create)
        for (path, type, data) in entries {
            try zip.addEntry(with: path, type: type, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
            }
        }
    }

    @Test func roundTripPreservesUnicodeFilesBytesAndEmptyDirectories() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), bundle = source.appendingPathComponent("bear.textbundle")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let text = Data("# Bärchen 🐻\r\nExact e\u{301} source\n".utf8)
        try text.write(to: bundle.appendingPathComponent("text.md"))
        let archive = root.appendingPathComponent("backup.zip"), restored = root.appendingPathComponent("restored")
        try PortableZIP.create(from: source, at: archive)
        try PortableZIP.extract(archive, to: restored)
        #expect(try Data(contentsOf: restored.appendingPathComponent("bear.textbundle/text.md")) == text)
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("bear.textbundle/assets").path, isDirectory: &directory) && directory.boolValue)
        #expect(throws: PortableZIP.Failure.nonemptyDestination) { try PortableZIP.extract(archive, to: restored) }
    }
    @Test func rejectsTraversalLinksAliasesAndFileDirectoryCollisionsBeforeExtraction() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cases: [[(String, Entry.EntryType, Data)]] = [
            [("../outside", .file, Data("escape".utf8))],
            [("/absolute", .file, Data())],
            [("link", .symlink, Data("../outside".utf8))],
            [("A.txt", .file, Data()), ("a.txt", .file, Data())],
            [("folder", .file, Data()), ("folder/inside", .file, Data())],
        ]
        for (index, entries) in cases.enumerated() {
            let zip = root.appendingPathComponent("\(index).zip"), output = root.appendingPathComponent("out-\(index)")
            try archive(zip, entries: entries)
            #expect(throws: (any Error).self) { try PortableZIP.extract(zip, to: output) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }
    @Test func sizeLimitsAndCorruptCRCLeaveNoPartialOutput() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("source.zip"), output = root.appendingPathComponent("out")
        let bytes = Data("unique-uncompressed-payload".utf8)
        try archive(zip, entries: [("file.txt", .file, bytes)])
        #expect(throws: PortableZIP.Failure.limitExceeded) { try PortableZIP.extract(zip, to: output, limits: .init(fileBytes: 2)) }
        var raw = try Data(contentsOf: zip)
        let range = try #require(raw.range(of: bytes)); raw[range.lowerBound] ^= 1
        try raw.write(to: zip)
        #expect(throws: PortableZIP.Failure.invalidChecksum) { try PortableZIP.extract(zip, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
