// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import ImageIO
import PencilKit
import UniformTypeIdentifiers
import zlib

/// Spike wire format: normal PNG pixels + one `thND` private ancillary chunk.
/// Third letter is uppercase (PNG reserved bit); fourth is uppercase (UNSAFE to copy
/// after pixel changes). Crop/rasterization must not silently retain mismatched drawing data.
/// The codec never changes raster chunks, other ancillary chunks, or PKDrawing archive bytes.
enum MobileSketchPNG {
    static let maximumDrawingBytes = 8 * 1024 * 1024
    static let maximumPNGBytes = 64 * 1024 * 1024
    static let maximumPixelCount = 16_777_216
    private static let maximumDimension = 8192
    private static let maximumChunks = 16_384
    private static let drawingType: UInt32 = 0x74684e44 // thND
    private static let header = Data([84, 78, 80, 75, 1]) // TNPK, schema 1
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    enum Failure: Error, Equatable {
        case invalidPNG, invalidCRC, unsupportedCriticalChunk, multipleDrawings
        case tooLarge, unsupportedDrawingVersion, invalidDrawing, unsupportedAnimation
        case unsupportedMetadata, invalidMetadata
    }

    /// Task 6 must use this encoder for freshly rendered, app-owned sketch CGImages.
    /// It intentionally normalizes NEW pixels to bounded sRGB RGBA8 with alpha. Never use this
    /// to rewrite an imported/ordinary image or an existing sketch: their bytes stay untouched.
    /// Platform PNG encoders may attach compressed ICC profiles even to their default renderer;
    /// remove encoder metadata only after the explicit color conversion, then declare sRGB.
    static func pngForNewSketch(from image: CGImage) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixelCount / height else { throw Failure.tooLarge }
        try Task.checkCancellation()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw Failure.invalidPNG }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        guard let converted = context.makeImage() else { throw Failure.invalidPNG }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.invalidPNG }
        CGImageDestinationAddImage(destination, converted, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidPNG }
        let raster = try rasterPNGForValidation(in: encoded as Data)
        let chunks = try parseFraming(raster)
        var result = Data(signature)
        for chunk in chunks {
            try Task.checkCancellation()
            raster.withUnsafeBytes { bytes in result.append(contentsOf: bytes[chunk.whole]) }
            if chunk.type == 0x49484452 { try appendChunk(type: 0x73524742, body: Data([0]), to: &result) } // sRGB intent 0
        }
        guard result.count <= maximumPNGBytes else { throw Failure.tooLarge }
        _ = try parse(result)
        return result
    }

    static func embed(drawing: PKDrawing, in png: Data) throws -> Data {
        try validate(drawing)
        return try embed(drawingData: drawing.dataRepresentation(), in: png)
    }
    /// Also accepts frozen archives, preserving the exact payload bytes across transports.
    static func embed(drawingData: Data, in png: Data) throws -> Data {
        guard drawingData.count <= maximumDrawingBytes else { throw Failure.tooLarge }
        let chunks = try parse(png)
        try validateSketchMetadata(png, chunks: chunks)
        _ = try archive(drawingData)
        // Never silently repair/erase corrupted or future-version sketch metadata.
        if let old = chunks.first(where: { $0.type == drawingType }) { _ = try payload(png, range: old.body) }
        let addedSize = drawingData.count + header.count + 12
        let removedSize = chunks.first(where: { $0.type == drawingType })?.whole.count ?? 0
        // Replacement preserves the count; adding metadata must leave output readable by parse.
        guard removedSize > 0 || chunks.count < maximumChunks else { throw Failure.tooLarge }
        guard png.count - removedSize <= maximumPNGBytes - addedSize else { throw Failure.tooLarge }
        var result = Data(signature)
        let newPayload = header + drawingData
        for chunk in chunks where chunk.type != drawingType {
            if chunk.type == 0x49454e44 { try appendChunk(type: drawingType, body: newPayload, to: &result) }
            png.withUnsafeBytes { bytes in result.append(contentsOf: bytes[chunk.whole]) }
        }
        return result
    }
    /// nil means a structurally valid, decodable PNG with no drawing. Corruption throws.
    static func drawingData(in png: Data) throws -> Data? {
        let chunks = try parse(png)
        guard let chunk = chunks.first(where: { $0.type == drawingType }) else { return nil }
        try validateSketchMetadata(png, chunks: chunks)
        return try payload(png, range: chunk.body)
    }
    static func drawing(in png: Data) throws -> PKDrawing? {
        guard let data = try drawingData(in: png) else { return nil }
        return try archive(data)
    }

    private struct Chunk {
        let type: UInt32
        let whole: Range<Int>
        let body: Range<Int>
    }
    /// The exact, bounded decoder-only PNG handed to ImageIO. Ancillary bytes (including
    /// compressed profiles/text, EXIF, private extensions and thND) never enter that decoder.
    /// This is a validation view only: embed preserves all original chunks byte-for-byte.
    static func rasterPNGForValidation(in png: Data) throws -> Data {
        try validatedRaster(png).bytes
    }

    private static func validatedRaster(_ png: Data) throws -> (chunks: [Chunk], bytes: Data) {
        let chunks = try parseFraming(png)
        // ImageIO can log invalid IDAT yet return a filled-in image with Complete status.
        // Bound and validate the complete zlib/Adler/scanline/filter stream independently.
        try validateImageData(png, chunks: chunks)
        let raster = chunks.filter {
            [UInt32(0x49484452), 0x504c5445, 0x49444154, 0x49454e44].contains($0.type)
        }
        let size = 8 + raster.reduce(0) { $0 + $1.whole.count }
        guard size <= maximumPNGBytes else { throw Failure.tooLarge }
        var result = Data(signature)
        result.reserveCapacity(size)
        try png.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for chunk in raster {
                try Task.checkCancellation()
                result.append(contentsOf: bytes[chunk.whole])
            }
        }
        return (chunks, result)
    }

    private static func parse(_ png: Data) throws -> [Chunk] {
        let raster = try validatedRaster(png)
        // Validate image decoding without exposing metadata decompression or native metadata
        // parsing to untrusted ancillary bytes. Color/alpha metadata is NOT stripped on disk.
        guard let source = CGImageSourceCreateWithData(raster.bytes as CFData, [kCGImageSourceTypeIdentifierHint: UTType.png.identifier] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width > 0, image.height > 0, CGImageSourceGetStatusAtIndex(source, 0).rawValue == 0 else { throw Failure.invalidPNG }
        try Task.checkCancellation()
        return raster.chunks
    }

    private static func parseFraming(_ png: Data) throws -> [Chunk] {
        guard png.count <= maximumPNGBytes else { throw Failure.tooLarge }
        let chunks: [Chunk] = try png.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 8, bytes.prefix(8).elementsEqual(signature) else { throw Failure.invalidPNG }
            var offset = 8, chunks: [Chunk] = []
            var hasHeader = false, hasPalette = false, hasData = false, endedData = false
            var color: UInt8 = 0, depth: UInt8 = 0, drawings = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard chunks.count < maximumChunks, bytes.count - offset >= 12 else { throw Failure.invalidPNG }
                let length = Int(number(bytes, offset)), type = number(bytes, offset + 4)
                guard length <= Int(Int32.max), length <= bytes.count - offset - 12 else { throw Failure.invalidPNG }
                let body = (offset + 8)..<(offset + 8 + length)
                let end = body.upperBound + 4
                let letters = bytes[(offset + 4)..<(offset + 8)]
                guard letters.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                      bytes[offset + 6] & 0x20 == 0 else { throw Failure.invalidPNG }
                guard try crc(bytes[(offset + 4)..<body.upperBound]) == number(bytes, body.upperBound) else { throw Failure.invalidCRC }
                guard hasHeader || type == 0x49484452 else { throw Failure.invalidPNG }
                switch type {
                case 0x49484452: // IHDR
                    guard !hasHeader, offset == 8, length == 13 else { throw Failure.invalidPNG }
                    let width = Int(number(bytes, body.lowerBound)), height = Int(number(bytes, body.lowerBound + 4))
                    guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                          width <= maximumPixelCount / height else { throw Failure.tooLarge }
                    depth = bytes[body.lowerBound + 8]; color = bytes[body.lowerBound + 9]
                    let validDepth: Bool
                    switch color {
                    case 0: validDepth = [1, 2, 4, 8, 16].contains(depth)
                    case 2, 4, 6: validDepth = [8, 16].contains(depth)
                    case 3: validDepth = [1, 2, 4, 8].contains(depth)
                    default: validDepth = false
                    }
                    guard validDepth, bytes[body.lowerBound + 10] == 0, bytes[body.lowerBound + 11] == 0,
                          bytes[body.lowerBound + 12] <= 1 else { throw Failure.invalidPNG }
                    hasHeader = true
                case 0x504c5445: // PLTE
                    guard !hasPalette, !hasData, color != 0, color != 4,
                          length >= 3, length <= 768, length.isMultiple(of: 3),
                          color != 3 || length / 3 <= 1 << Int(depth) else { throw Failure.invalidPNG }
                    hasPalette = true
                case 0x49444154: // IDAT chunks must be consecutive.
                    guard !endedData, color != 3 || hasPalette else { throw Failure.invalidPNG }
                    hasData = true
                case 0x49454e44: // IEND
                    guard hasData, length == 0, end == bytes.count else { throw Failure.invalidPNG }
                case 0x6163544c, 0x6663544c, 0x66644154: // acTL, fcTL, fdAT
                    throw Failure.unsupportedAnimation // Single static raster is the sketch format.
                case drawingType:
                    drawings += 1
                    guard drawings == 1 else { throw Failure.multipleDrawings }
                    guard length >= header.count, length <= maximumDrawingBytes + header.count else { throw Failure.tooLarge }
                default:
                    guard bytes[offset + 4] & 0x20 != 0 else { throw Failure.unsupportedCriticalChunk }
                }
                if hasData && type != 0x49444154 { endedData = true }
                chunks.append(Chunk(type: type, whole: offset..<end, body: body))
                offset = end
            }
            guard chunks.last?.type == 0x49454e44 else { throw Failure.invalidPNG }
            return chunks
        }
        return chunks
    }

    private static func validateImageData(_ png: Data, chunks: [Chunk]) throws {
        try png.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let width = Int(number(input, 16)), height = Int(number(input, 20))
            let depth = Int(input[24]), color = input[25]
            let channels = color == 2 ? 3 : color == 4 ? 2 : color == 6 ? 4 : 1
            let bitsPerPixel = channels * depth
            let passes = input[28] == 0 ? [(0, 0, 1, 1)] : [
                (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2),
            ]
            // Only row-start offsets are retained; inflated pixels stream through 64 KiB.
            var filterOffsets: [Int] = [], expected = 0
            for (x, y, dx, dy) in passes {
                guard width > x, height > y else { continue }
                let columns = (width - x + dx - 1) / dx, rows = (height - y + dy - 1) / dy
                let rowSize = (columns * bitsPerPixel + 7) / 8 + 1
                for _ in 0..<rows { filterOffsets.append(expected); expected += rowSize }
            }
            var stream = z_stream()
            guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalidPNG }
            defer { _ = inflateEnd(&stream) }
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { throw Failure.invalidPNG }
            let blockSize = 64 * 1024
            var output = [UInt8](repeating: 0, count: blockSize)
            var total = 0, filter = 0, ended = false
            for chunk in chunks where chunk.type == 0x49444154 {
                if ended {
                    guard chunk.body.isEmpty else { throw Failure.invalidPNG }
                    continue
                }
                if chunk.body.isEmpty { continue }
                stream.next_in = UnsafeMutablePointer(mutating: base.advanced(by: chunk.body.lowerBound))
                stream.avail_in = uInt(chunk.body.count)
                while true {
                    try Task.checkCancellation()
                    let priorInput = stream.avail_in
                    let status = output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                        stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = uInt(blockSize)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let count = blockSize - Int(stream.avail_out)
                    guard count <= expected - total else { throw Failure.invalidPNG }
                    while filter < filterOffsets.count, filterOffsets[filter] < total + count {
                        let position = filterOffsets[filter] - total
                        guard position >= 0, output[position] <= 4 else { throw Failure.invalidPNG }
                        filter += 1
                    }
                    total += count
                    if status == Z_STREAM_END {
                        // One zlib stream only; no hidden trailing compressed bytes or second stream.
                        guard stream.avail_in == 0 else { throw Failure.invalidPNG }
                        ended = true
                        break
                    }
                    guard status == Z_OK || (status == Z_BUF_ERROR && stream.avail_in == 0 && count == 0) else { throw Failure.invalidPNG }
                    if priorInput == stream.avail_in && count == 0 {
                        guard stream.avail_in == 0 else { throw Failure.invalidPNG }
                        break
                    }
                    if stream.avail_in == 0 && stream.avail_out > 0 { break }
                }
            }
            guard ended, total == expected, filter == filterOffsets.count else { throw Failure.invalidPNG }
        }
    }

    /// This gate applies to recognized sketches and every ordinary->sketch embed, not to
    /// ordinary-image classification. Reject compressed metadata before PencilKit sees an archive.
    /// The decoder-only raster above protects this codec; unrelated original-image renderers
    /// remain responsible for their own metadata/decompression policy.
    private static func validateSketchMetadata(_ png: Data, chunks: [Chunk]) throws {
        try png.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for chunk in chunks {
                try Task.checkCancellation()
                switch chunk.type {
                case 0x7a545874, 0x69434350: // zTXt (compressed text), iCCP (compressed ICC)
                    throw Failure.unsupportedMetadata
                case 0x69545874: // iTXt: keyword NUL, flag, method, language NUL, translation NUL, text
                    let body = chunk.body
                    guard let keywordEnd = body.first(where: { bytes[$0] == 0 }),
                          (1...79).contains(keywordEnd - body.lowerBound),
                          keywordEnd + 2 < body.upperBound else { throw Failure.invalidMetadata }
                    let keyword = bytes[body.lowerBound..<keywordEnd]
                    guard keyword.allSatisfy({ (32...126).contains($0) || (161...255).contains($0) }),
                          keyword.first != 32, keyword.last != 32,
                          !zip(keyword, keyword.dropFirst()).contains(where: { pair in pair.0 == 32 && pair.1 == 32 }) else { throw Failure.invalidMetadata }
                    let flag = bytes[keywordEnd + 1], method = bytes[keywordEnd + 2]
                    guard flag <= 1, method == 0 else { throw Failure.invalidMetadata }
                    if flag == 1 { throw Failure.unsupportedMetadata }
                    let languageStart = keywordEnd + 3
                    guard let languageEnd = (languageStart..<body.upperBound).first(where: { bytes[$0] == 0 }),
                          bytes[languageStart..<languageEnd].allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                          let translatedEnd = ((languageEnd + 1)..<body.upperBound).first(where: { bytes[$0] == 0 }),
                          String(bytes: bytes[(languageEnd + 1)..<translatedEnd], encoding: .utf8) != nil,
                          String(bytes: bytes[(translatedEnd + 1)..<body.upperBound], encoding: .utf8) != nil else { throw Failure.invalidMetadata }
                default: break
                }
            }
        }
    }

    private static func payload(_ png: Data, range: Range<Int>) throws -> Data {
        let bytes = png.withUnsafeBytes { Data($0[range]) }
        guard bytes.count >= header.count else { throw Failure.invalidDrawing }
        guard bytes.prefix(header.count) == header else { throw Failure.unsupportedDrawingVersion }
        let drawing = Data(bytes.dropFirst(header.count))
        _ = try archive(drawing)
        return drawing
    }
    private static func archive(_ bytes: Data) throws -> PKDrawing {
        guard !bytes.isEmpty, bytes.count <= maximumDrawingBytes else { throw Failure.tooLarge }
        do {
            // Public PencilKit exposes no preallocation/time quota. The byte cap is before
            // native decoding; stroke/point/geometry budgets can only be checked afterward.
            let drawing = try PKDrawing(data: bytes)
            try validate(drawing)
            return drawing
        } catch let error as Failure { throw error }
        catch { throw Failure.invalidDrawing }
    }
    private static func validate(_ drawing: PKDrawing) throws {
        let strokes = drawing.strokes
        guard strokes.count <= 10_000 else { throw Failure.tooLarge }
        var points = 0
        for stroke in strokes {
            guard stroke.path.count <= 500_000 - points else { throw Failure.tooLarge }
            points += stroke.path.count
            let bounds = stroke.renderBounds
            guard !bounds.isNull, !bounds.isInfinite,
                  bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  abs(bounds.origin.x) <= 1_000_000, abs(bounds.origin.y) <= 1_000_000,
                  bounds.width <= CGFloat(maximumDimension), bounds.height <= CGFloat(maximumDimension) else { throw Failure.invalidDrawing }
        }
    }
    private static func number(_ bytes: UnsafeRawBufferPointer, _ start: Int) -> UInt32 {
        (UInt32(bytes[start]) << 24) | (UInt32(bytes[start + 1]) << 16) | (UInt32(bytes[start + 2]) << 8) | UInt32(bytes[start + 3])
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }
    private static func crc<C: Collection>(_ bytes: C) throws -> UInt32 where C.Element == UInt8 {
        var value = UInt32.max, count = 0
        for byte in bytes {
            if count.isMultiple(of: 65_536) { try Task.checkCancellation() }
            value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 255)]
            count += 1
        }
        return ~value
    }
    private static func appendChunk(type: UInt32, body: Data, to output: inout Data) throws {
        func append(_ value: UInt32) { output.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }) }
        append(UInt32(body.count))
        let start = output.count
        append(type); output.append(body)
        let end = output.count
        let checksum = try output.withUnsafeBytes { try crc($0[start..<end]) }
        append(checksum)
    }
}
