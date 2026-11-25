// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import CryptoKit
import GRDB
import ImageIO
import CoreGraphics
import Testing
@testable import TheoNotesCore

/// A transport fixture, NOT a PencilKit archive or the production sketch codec. The PNG is a
/// single opaque red pixel. Its private, ancillary, safe-to-copy `skEt` chunk carries arbitrary
/// binary bytes so image decoding cannot accidentally stand in for metadata preservation.
enum SketchOpaquePNGFixture {
    static func make(payload: Data) -> Data {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let ihdr = Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
        let scanline = Data([0, 255, 0, 0, 255]) // filter byte followed by RGBA
        // RFC1950 zlib + final uncompressed DEFLATE block + Adler32; no codec dependencies.
        var zlib = Data([0x78, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff])
        zlib.append(scanline)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in scanline { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        zlib.append(bigEndian: (b << 16) | a)
        return signature + chunk("IHDR", ihdr) + chunk("skEt", payload)
            + chunk("IDAT", zlib) + chunk("IEND", Data())
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        precondition(payload.count <= Int(UInt32.max))
        let body = Data(type.utf8) + payload
        var chunk = Data(); chunk.append(bigEndian: UInt32(payload.count))
        chunk.append(body); chunk.append(bigEndian: crc32(body))
        return chunk
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) }
        }
        return crc ^ UInt32.max
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}

@Suite struct SketchStorageTransportTests {
    private struct Library {
        let paths: AppPaths
        let db: AppDatabase
        let store: NoteStore
        var attachments: AttachmentStore { AttachmentStore(paths: paths, database: db) }
        var backup: LibraryBackup { LibraryBackup(database: db, paths: paths) }
        init() throws {
            paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("sketch-transport-\(UUID())"))
            try paths.createDirectories()
            db = try AppDatabase(path: paths.database)
            store = NoteStore(db: db, notifier: nil, paths: paths)
        }
        func cleanup() { try? db.pool.close(); try? FileManager.default.removeItem(at: paths.root) }
        func bytes(noteID: String, filename: String) throws -> Data {
            try Data(contentsOf: paths.attachments.appendingPathComponent(noteID).appendingPathComponent(filename))
        }
    }

    private let payload = Data("synthetic-opaque-sketch-transport-v1\0".utf8)
        + Data((0..<513).map { UInt8(truncatingIfNeeded: $0) })
    private let png: Data
    private let drawing: Data

    init() throws {
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        png = try Data(contentsOf: repository.appendingPathComponent("Fixtures/sketch/one-stroke.png"))
        drawing = try Data(contentsOf: repository.appendingPathComponent("Fixtures/sketch/one-stroke.drawing"))
    }

    /// This is a fixture assertion, not validation of the future untrusted-input sketch codec.
    private func requireExactPNG(_ bytes: Data) throws {
        #expect(bytes == png, "The entire PNG, not just its raster image, must survive")
        var offset = 8, found: [Data] = []
        func word(_ at: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(bytes[at + $1]) }
        }
        while offset + 12 <= bytes.count {
            let count = word(offset)
            try #require(count <= bytes.count - offset - 12)
            let body = bytes.subdata(in: (offset + 4)..<(offset + 8 + count))
            #expect(SketchOpaquePNGFixture.crc32(body) == UInt32(word(offset + 8 + count)))
            if bytes.subdata(in: (offset + 4)..<(offset + 8)) == Data("thND".utf8) {
                found.append(bytes.subdata(in: (offset + 8)..<(offset + 8 + count)))
            }
            offset += 12 + count
        }
        #expect(offset == bytes.count && found == [Data("TNPK".utf8) + Data([1]) + drawing])
    }

    @Test func validOpaquePNGDecodesAndRendersOneRedPixelWithoutConsumingAncillaryBytes() throws {
        let synthetic = SketchOpaquePNGFixture.make(payload: payload)
        let source = try #require(CGImageSourceCreateWithData(synthetic as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1 && image.height == 1)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(Array(UnsafeBufferPointer(start: pixels, count: 4)) == [255, 0, 0, 255])
    }

    @Test func realDrawingFixtureIsPinnedAndMacImageIODecodesItsPNG() throws {
        #expect(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            == "b230e42019b40ffab7c458df722d7f01dc16da14ff8fd17afc84264ef83525bb")
        #expect(!drawing.isEmpty)
        try requireExactPNG(png)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 96 && image.height == 64)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let raster = try #require(context.makeImage())
        #expect(raster.width == 96 && raster.height == 64)
        // This is ImageIO/CoreGraphics decoding/rendering, not the Mac WKWebView or HTML/PDF
        // renderer. Drawing semantics require the separate PencilKit codec fixture tests.
    }

    @Test func attachmentAddCopyBatchAndRenameKeepCompleteAncillaryPNG() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Sketch transport fixture\n![](sketch.png)")
        let first = try library.attachments.add(data: png, filename: "sketch.png", to: note.id)
        try requireExactPNG(library.bytes(noteID: note.id, filename: first))
        let source = library.paths.root.appendingPathComponent("provider.png")
        try png.write(to: source)
        let copy = try library.attachments.add(fileAt: source, to: note.id)
        try requireExactPNG(library.bytes(noteID: note.id, filename: copy))
        let renamed = try library.attachments.rename(first, to: "renamed.png", in: note.id)
        try requireExactPNG(library.bytes(noteID: note.id, filename: renamed))
        try requireExactPNG(library.bytes(noteID: note.id, filename: first)) // Undo alias retained.
        let batch = try library.attachments.addBatch([ImportedAttachment(filename: "batch.png", data: png)], to: note.id)
        #expect(batch == ["batch.png"])
        try requireExactPNG(library.bytes(noteID: note.id, filename: "batch.png"))
    }

    @Test func encryptedAttachmentLockDecryptAndProtectedAddKeepAllPNGBytes() throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Private sketch transport fixture\n![](sketch.png)")
        _ = try library.attachments.add(data: png, filename: "sketch.png", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("fixture-only-password")
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        #expect(library.attachments.url(for: "sketch.png", noteId: note.id) == nil)
        let output = library.paths.root.appendingPathComponent("decrypted-test-output.png")
        try access.decryptAttachment("sketch.png", noteId: note.id, to: output)
        try requireExactPNG(Data(contentsOf: output))
        try FileManager.default.removeItem(at: output)
        let added = try access.addAttachment(data: png, filename: "added.png", to: note.id)
        try access.decryptAttachment(added, noteId: note.id, to: output)
        try requireExactPNG(Data(contentsOf: output))
        try FileManager.default.removeItem(at: output)
        // Both stored files must be ciphertext, not recognizable copies of the custom payload.
        let directory = library.paths.attachments.appendingPathComponent(note.id)
        let encryptedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(encryptedFiles.count == 2)
        for file in encryptedFiles {
            let cipher = try Data(contentsOf: file)
            #expect(cipher != png && cipher.range(of: payload) == nil)
        }
        try access.removeLock(noteId: note.id)
        try requireExactPNG(library.bytes(noteID: note.id, filename: "sketch.png"))
        try requireExactPNG(library.bytes(noteID: note.id, filename: added))
    }

    @Test(arguments: [false, true])
    func backupRestorePreservesPlainAndEncryptedAncillaryPNG(locked: Bool) throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let note = try source.store.create(text: "# Backup sketch transport fixture\n![](sketch.png)")
        _ = try source.attachments.add(data: png, filename: "sketch.png", to: note.id)
        if locked { try NotePrivacy(store: source.store).setPassword("fixture-only-password").lock(noteId: note.id) }
        let archive = source.paths.root.appendingPathComponent("transport.baerchen-backup")
        try source.backup.create(at: archive)
        _ = try destination.backup.restore(archive, mode: .replaceAll)
        let restored = try #require(try destination.store.note(id: note.id))
        #expect(restored.isLocked == locked)
        if locked {
            let access = try NotePrivacy(store: destination.store).unlock(password: "fixture-only-password")
            defer { access.revoke() }
            let output = destination.paths.root.appendingPathComponent("decrypted-test-output.png")
            try access.decryptAttachment("sketch.png", noteId: note.id, to: output)
            try requireExactPNG(Data(contentsOf: output))
            try access.removeLock(noteId: note.id)
        }
        #expect(try destination.store.note(id: note.id)?.text == note.text)
        try requireExactPNG(destination.bytes(noteID: note.id, filename: "sketch.png"))
    }

    @Test(arguments: [FileExportFormat.markdown, .textBundle])
    func exportReimportPreservesAncillaryPNGAndImageMarkdown(format: FileExportFormat) throws {
        let source = try Library(), destination = try Library()
        defer { source.cleanup(); destination.cleanup() }
        let note = try source.store.create(text: "# Export sketch transport fixture\n\n![](sketch.png)\n")
        _ = try source.attachments.add(data: png, filename: "sketch.png", to: note.id)
        let plan = ExportPlan.selection(try source.store.exportCandidates(ids: [note.id]))
        let item = try #require(plan.items.first)
        let output = source.paths.root.appendingPathComponent("export", isDirectory: true)
        let files = try NoteExporter(store: source.store, paths: source.paths).write(item, format: format,
            under: output, options: ExportOptions())
        #expect(files.missingAttachments.isEmpty)
        let exportedAssets = try #require(files.attachmentsFolder)
        try requireExactPNG(Data(contentsOf: exportedAssets.appendingPathComponent("sketch.png")))
        let report = try FileImporter(store: destination.store, paths: destination.paths).importItems([output])
        #expect(report.created == 1 && report.errors.isEmpty && report.warnings.isEmpty)
        let restored = try #require(try destination.store.allNotes().first)
        #expect(restored.text == note.text)
        #expect(NoteParser.attachmentLinks(in: restored.text).map(\.filename) == ["sketch.png"])
        try requireExactPNG(destination.bytes(noteID: restored.id, filename: "sketch.png"))
    }
    @Test(arguments: [FileExportFormat.markdown, .textBundle])
    func lockedSketchIsExcludedAndDirectPlaintextExportIsRefused(format: FileExportFormat) throws {
        let library = try Library(); defer { library.cleanup() }
        let note = try library.store.create(text: "# Protected transport fixture\n![](sketch.png)")
        _ = try library.attachments.add(data: png, filename: "sketch.png", to: note.id)
        let access = try NotePrivacy(store: library.store).setPassword("fixture-only-password")
        defer { access.revoke() }
        try access.lock(noteId: note.id)
        let plan = ExportPlan.selection(try library.store.exportCandidates(ids: [note.id]))
        #expect(plan.items.isEmpty && plan.skippedLocked == [note.id])
        let output = library.paths.root.appendingPathComponent("refused-export")
        #expect(throws: ExportError.noteLocked(id: note.id)) {
            try NoteExporter(store: library.store, paths: library.paths).write(
                ExportItem(noteId: note.id, folder: [], stem: "protected"), format: format,
                under: output, options: ExportOptions())
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let decrypted = library.paths.root.appendingPathComponent("decrypted-test-output.png")
        try access.decryptAttachment("sketch.png", noteId: note.id, to: decrypted)
        try requireExactPNG(Data(contentsOf: decrypted))
    }

}
