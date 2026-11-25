// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileImageCropTests {
    private func fixtureImage(orientation: Int = 1) throws -> Data {
        // Two columns, three rows: red/green, blue/yellow, cyan/transparent.
        let bytes = Data([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255,
                          0,255,255,255, 0,0,0,0])
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, (orientation == 1 ? UTType.png : UTType.tiff).identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func rgba(_ data: Data) throws -> (Int, Int, [UInt8]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }

    @Test func cropUsesExactPixelBoundsAndPreservesAlpha() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        #expect(prepared.width == 2 && prepared.height == 3)
        let output = try await MobileImageCrop.crop(prepared, rect: .init(x: 1, y: 2, width: 1, height: 1))
        let (width, height, pixels) = try rgba(output)
        #expect(width == 1 && height == 1 && pixels[3] == 0)
        let red = try await MobileImageCrop.crop(prepared, rect: .init(x: 0, y: 0, width: 1, height: 1))
        #expect(try rgba(red).2 == [255, 0, 0, 255])
        let full = MobileImageCrop.PixelRect(x: 0, y: 0, width: 2, height: 3)
        let first = try await MobileImageCrop.crop(prepared, rect: full)
        let second = try await MobileImageCrop.crop(prepared, rect: full)
        #expect(first == second)
    }
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func orientationIsAppliedBeforePixelSelection(orientation: Int) async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage(orientation: orientation))
        let swapped = orientation >= 5
        #expect(prepared.width == (swapped ? 3 : 2) && prepared.height == (swapped ? 2 : 3))
        let output = try await MobileImageCrop.crop(prepared, rect: .init(x: 0, y: 0, width: 1, height: 1))
        let corners: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,0,0], [0,255,255,255],
                                 [255,0,0,255], [0,255,255,255], [0,0,0,0], [0,255,0,255]]
        #expect(try rgba(output).2 == corners[orientation - 1])
    }
    @Test func jpegCropKeepsJPEGAndNormalizesOrientationWithoutDownsampling() async throws {
        let bytes = try Self.largePhoto(width: 40, height: 30, orientation: 6)
        let prepared = try await MobileImageCrop.prepare(data: bytes)
        #expect(prepared.width == 30 && prepared.height == 40)
        let output = try await MobileImageCrop.crop(prepared, rect: .init(x: 2, y: 3, width: 20, height: 25))
        #expect(output.starts(with: [255, 216, 255]))
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 20)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 25)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func invalidBoundsAndCorruptImagesAreRefused() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        for rect in [MobileImageCrop.PixelRect(x: -1, y: 0, width: 1, height: 1),
                     .init(x: 0, y: 0, width: 0, height: 1), .init(x: 1, y: 2, width: 2, height: 1),
                     .init(x: Int.max, y: 0, width: Int.max, height: 1)] {
            await #expect(throws: MobileImageCrop.Failure.invalidRectangle) { try await MobileImageCrop.crop(prepared, rect: rect) }
        }
        await #expect(throws: (any Error).self) { try await MobileImageCrop.prepare(data: Data([0, 1, 2])) }
        await #expect(throws: MobileImageCrop.Failure.tooLarge) {
            try await MobileImageCrop.prepare(data: Data(count: MobileImageCrop.maximumInputBytes + 1))
        }
    }
    @Test func sourceDimensionLimitIsCheckedBeforeWorkingRaster() async throws {
        let context = try #require(CGContext(data: nil, width: 8193, height: 1, bitsPerComponent: 8,
            bytesPerRow: 8193 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        await #expect(throws: MobileImageCrop.Failure.tooLarge) { try await MobileImageCrop.prepare(data: output as Data) }
    }
    /// A sequential constant-pixel provider avoids allocating a second 192MiB fixture
    /// raster just to encode a 48MP source. Decode/crop still exercise real ImageIO bytes.
    nonisolated private static func largePhoto(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { _, buffer, _, count in
                buffer.initializeMemory(as: UInt8.self, repeating: 255, count: count)
                return count
            }, releaseInfo: nil)
        let provider = try #require(CGDataProvider(directInfo: nil, size: off_t(width * height * 4), callbacks: &callbacks))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
        return bytes as Data
    }
    nonisolated private static func sixteenBitPNG(width: Int, height: Int) throws -> Data {
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { _, buffer, _, count in
                buffer.initializeMemory(as: UInt8.self, repeating: 255, count: count); return count
            }, releaseInfo: nil)
        let provider = try #require(CGDataProvider(directInfo: nil, size: off_t(width * height * 8), callbacks: &callbacks))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        try #require(CGImageDestinationFinalize(output))
        return bytes as Data
    }
    @Test func real16BitPNGRemainsCroppableButKeepsOriginalPixelBudget() async throws {
        let bytes = try Self.sixteenBitPNG(width: 2, height: 3)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        try #require(properties[kCGImagePropertyDepth] as? Int == 16, "Fixture must really be 16-bit PNG")
        let prepared = try await MobileImageCrop.prepare(data: bytes)
        #expect(prepared.width == 2 && prepared.height == 3)
        let cropped = try await MobileImageCrop.crop(prepared, rect: .init(x: 1, y: 2, width: 1, height: 1))
        #expect(try rgba(cropped).2 == [255, 255, 255, 255])
        let oversized = try await Task.detached { try Self.sixteenBitPNG(width: 4096, height: 4097) }.value
        await #expect(throws: MobileImageCrop.Failure.tooLarge) { try await MobileImageCrop.prepare(data: oversized) }
    }

    @Test func ordinary24And48MegapixelPhotosKeepFullResolution() async throws {
        for size in [(6048, 4032), (8064, 6048)] {
            try await checkLargePhoto(width: size.0, height: size.1)
        }
    }
    private func checkLargePhoto(width: Int, height: Int) async throws {
        let data = try await Task.detached { try Self.largePhoto(width: width, height: height) }.value
        let prepared = try await MobileImageCrop.prepare(data: data)
        #expect(prepared.width == width && prepared.height == height)
        let full = try await MobileImageCrop.crop(prepared, rect: .init(x: 0, y: 0, width: width, height: height))
        let source = try #require(CGImageSourceCreateWithData(full as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
        let edge = try await MobileImageCrop.crop(prepared, rect: .init(x: width - 1, y: height - 1, width: 1, height: 1))
        #expect(try rgba(edge).2 == [255, 255, 255, 255])
    }
    @Test func rotated48MegapixelSourceKeepsExactDimensionsAndOverBudgetIsRejected() async throws {
        let data = try await Task.detached { try Self.largePhoto(width: 8064, height: 6048, orientation: 6) }.value
        let prepared = try await MobileImageCrop.prepare(data: data)
        #expect(prepared.width == 6048 && prepared.height == 8064)
        let edge = try await MobileImageCrop.crop(prepared, rect: .init(x: 6047, y: 8063, width: 1, height: 1))
        #expect(try rgba(edge).2 == [255, 255, 255, 255])
        let oversized = try await Task.detached { try Self.largePhoto(width: 8192, height: 6145) }.value
        await #expect(throws: MobileImageCrop.Failure.tooLarge) { try await MobileImageCrop.prepare(data: oversized) }
    }

    @Test func hostSaveFailureKeepsExactSelectionAndAllowsSafeRetry() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        let session = MobileImageCropSession(prepared: prepared)
        let selection = MobileImageCrop.PixelRect(x: 1, y: 1, width: 1, height: 2)
        session.rect = selection
        var submissions: [Data] = []
        session.confirm { bytes in
            submissions.append(bytes)
            throw CocoaError(.fileWriteNoPermission) // host confirms failure before any write
        }
        await session.waitForCompletion()
        #expect(!session.isWorking && !session.isClosed && session.errorMessage != nil)
        #expect(session.rect == selection)
        session.confirm { bytes in submissions.append(bytes) }
        await session.waitForCompletion()
        #expect(submissions.count == 2 && submissions[0] == submissions[1])
        #expect(session.isClosed && !session.isWorking && !session.cancel())
    }
    @Test func uncertainHostOutcomePreservesSelectionWithoutBlindSecondWrite() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        let session = MobileImageCropSession(prepared: prepared, encode: { _, _ in Data([7]) })
        session.rect = .init(x: 1, y: 1, width: 1, height: 2)
        let selection = session.rect
        var writes = 0, unconfirmed = false
        // The host owns write-outcome knowledge and latches an uncertain operation. The view
        // must retain the draft and surface that host error, never treat a throw as success.
        let host: @MainActor (Data) async throws -> Void = { _ in
            guard !unconfirmed else { throw CropHostFailure.unconfirmed }
            writes += 1; unconfirmed = true
            throw CropHostFailure.unconfirmed
        }
        session.confirm(onComplete: host)
        await session.waitForCompletion()
        session.confirm(onComplete: host)
        await session.waitForCompletion()
        #expect(writes == 1 && session.rect == selection && !session.isClosed && session.errorMessage != nil)
    }
    @Test func cancellationDuringHeldHostSaveFencesLateSuccessAndDuplicateConfirm() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        let session = MobileImageCropSession(prepared: prepared, encode: { _, _ in Data([7]) })
        let held = HeldCrop()
        session.confirm { _ in _ = await held.run() } // non-cooperative durable-save seam
        for _ in 0..<1000 { if await held.started { break }; await Task.yield() }
        try #require(await held.started)
        #expect(session.isWorking && !session.isClosed)
        session.confirm { _ in Issue.record("Duplicate host save accepted") }
        #expect(session.cancel())
        await held.release()
        await session.waitForCompletion()
        #expect(session.isClosed && !session.isWorking && session.errorMessage == nil && !session.cancel())
        #expect(await held.calls == 1)
    }
    @Test func terminalCallbacksCanBeClaimedOnlyOnce() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        let cancelled = MobileImageCropSession(prepared: prepared)
        var cancellations = 0
        if cancelled.cancel() { cancellations += 1 }
        if cancelled.cancel() { cancellations += 1 }
        #expect(cancellations == 1)
        let completed = MobileImageCropSession(prepared: prepared, encode: { _, _ in Data([1]) })
        var deliveries = 0
        completed.confirm { _ in deliveries += 1 }
        await completed.waitForCompletion()
        #expect(deliveries == 1)
        #expect(!completed.cancel(), "A completed crop must never deliver a second terminal Cancel callback")
        completed.confirm { _ in deliveries += 1 }
        #expect(deliveries == 1)
    }
    @Test func cancelFencesLateCompletionAndRepeatedConfirm() async throws {
        let prepared = try await MobileImageCrop.prepare(data: fixtureImage())
        let held = HeldCrop()
        let session = MobileImageCropSession(prepared: prepared, encode: { _, _ in await held.run() })
        var deliveries = 0
        session.confirm { _ in deliveries += 1 }
        session.confirm { _ in deliveries += 1 }
        for _ in 0..<1000 { if await held.started { break }; await Task.yield() }
        try #require(await held.started)
        session.cancel()
        await held.release()
        await session.waitForCompletion()
        #expect(deliveries == 0 && !session.isWorking)
        #expect(await held.calls == 1)
        session.confirm { _ in deliveries += 1 }
        #expect(deliveries == 0)
    }
}

private actor HeldCrop {
    var calls = 0
    var started: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Data, Never>?
    func run() async -> Data {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: Data([1])); continuation = nil }
}

private enum CropHostFailure: LocalizedError {
    case unconfirmed
    var errorDescription: String? { "The save could not be confirmed. The crop selection is retained; do not retry the write blindly." }
}
