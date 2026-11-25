// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import ImageIO
import Foundation
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import BaerchenIOS

@Suite @MainActor struct MobileMediaCaptureTests {
    private func image(_ color: UIColor, size: CGSize = CGSize(width: 40, height: 30)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test func orderedPhotosOwnBytesAfterSourcesDisappear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try [UIColor.red, .blue].map { try #require(image($0).pngData()) }
        let sources = try data.enumerated().map { index, bytes in
            let url = directory.appendingPathComponent("source-\(index).png")
            try bytes.write(to: url); return url
        }
        let loads: [@MainActor () async throws -> MobileMediaBatch] = sources.map { source in
            { try MobileMediaBatch.copyProviderFile(source) }
        }
        let batch = try #require(try await MobileMediaCapture.collectPhotos(loads))
        defer { batch.remove() }
        for source in sources { try FileManager.default.removeItem(at: source) }
        #expect(batch.files.map(\.lastPathComponent) == ["Photo 1.png", "Photo 2.png"])
        for (file, bytes) in zip(batch.files, data) { #expect(try Data(contentsOf: file) == bytes) }
        batch.remove()
        #expect(!FileManager.default.fileExists(atPath: batch.directory.path))
    }

    @Test func partialPhotoFailureAndCancellationRemoveOwnedFiles() async throws {
        var stagedDirectory: URL?
        let loads: [@MainActor () async throws -> MobileMediaBatch] = [
            {
                let batch = try MobileMediaBatch.write(Data([1, 2]), filename: "photo.png")
                stagedDirectory = batch.directory
                return batch
            },
            { throw CocoaError(.fileReadUnknown) },
        ]
        await #expect(throws: (any Error).self) { try await MobileMediaCapture.collectPhotos(loads) }
        #expect(!FileManager.default.fileExists(atPath: try #require(stagedDirectory).path))
        #expect(try await MobileMediaCapture.collectPhotos([]) == nil)
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await MobileMediaCapture.collectPhotos(loads)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func scannedPagesBecomeOneOrderedPDFAndEmptyScanFails() throws {
        let pages = [image(.red), image(.blue, size: CGSize(width: 60, height: 20))]
        let batch = try MobileMediaCapture.scanPDF(pageCount: pages.count) { pages[$0] }
        defer { batch.remove() }
        #expect(batch.files.count == 1)
        #expect(batch.files[0].pathExtension == "pdf")
        let document = try #require(PDFDocument(url: batch.files[0]))
        #expect(document.pageCount == 2)
        for (index, original) in pages.enumerated() {
            let raster = try #require(original.cgImage)
            let page = try #require(document.page(at: index))
            #expect(page.bounds(for: .mediaBox).size == CGSize(width: raster.width, height: raster.height))
            // Read the rendered content as well as geometry: a swapped or repeated page must fail.
            let thumbnail = try #require(page.thumbnail(of: CGSize(width: 16, height: 16), for: .mediaBox).cgImage)
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if index == 0 { #expect(pixel[0] > 200 && pixel[2] < 40) }
            else { #expect(pixel[2] > 200 && pixel[0] < 40) }
        }
        #expect(throws: MobileMediaCapture.Failure.self) { try MobileMediaCapture.scanPDF(pageCount: 0) { _ in pages[0] } }
        #expect(throws: MobileMediaCapture.Failure.self) { try MobileMediaCapture.scanPDF(pageCount: 51) { _ in pages[0] } }
    }

    @Test func oversizedAndSymlinkProviderFilesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(MobileMediaCapture.maximumFileBytes + 1)); try handle.close()
        #expect(throws: (any Error).self) { try MobileMediaBatch.copyProviderFile(source) }
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try MobileMediaBatch.copyProviderFile(link) }
    }
    @Test func cameraAvailabilityMatchesSDKAndCancellationCompletesOnce() {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let expectedAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
            && authorization != .denied && authorization != .restricted
        #expect(MobileMediaCapture.cameraAvailable == expectedAvailable)
        #expect((MobileMediaCapture.availabilityError(for: .camera) == nil) == expectedAvailable)
        var calls = 0
        let picker = MobileCameraCapture { result in
            calls += 1
            if case .success(let batch) = result { #expect(batch == nil) }
            else { Issue.record("Cancellation must not become an error") }
        }
        let coordinator = picker.makeCoordinator()
        let controller = UIImagePickerController()
        coordinator.imagePickerControllerDidCancel(controller)
        coordinator.imagePickerControllerDidCancel(controller)
        #expect(calls == 1)
    }

    @Test func canceledPhotoLoadRejectsLateProviderAndRemovesItsFiles() async throws {
        let late = try MobileMediaBatch.write(Data([1, 2, 3]), filename: "late.png")
        defer { late.remove() }
        var resume: CheckedContinuation<MobileMediaBatch, any Error>?
        let task = Task { @MainActor in
            try await MobileMediaCapture.collectPhotos([{
                try await withCheckedThrowingContinuation { resume = $0 }
            }])
        }
        while resume == nil { await Task.yield() }
        task.cancel()
        resume?.resume(returning: late)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: late.directory.path))
    }

    @Test func extensionlessPhotoUsesPickerContentTypeAndPreservesBytes() async throws {
        let bytes = try #require(image(.red).pngData())
        let source = try MobileMediaBatch.write(bytes, filename: "provider-file")
        defer { source.remove() }
        let loads: [@MainActor () async throws -> MobileMediaBatch] = [{ try MobileMediaBatch.copyProviderFile(source.files[0]) }]
        let batch = try #require(try await MobileMediaCapture.collectPhotos(loads, contentTypes: [[.image, .png]]))
        defer { batch.remove() }
        #expect(batch.files[0].lastPathComponent == "Photo 1.png")
        #expect(try Data(contentsOf: batch.files[0]) == bytes)
    }

    @Test func decodedImageBudgetRejectsOversizeAndOverflowWithoutAllocatingImages() throws {
        #expect(try MobileMediaCapture.checkedDecodedBytes(bytesPerRow: 160, height: 30) == 4800)
        #expect(throws: MobileMediaCapture.Failure.self) {
            try MobileMediaCapture.checkedDecodedBytes(bytesPerRow: MobileMediaCapture.maximumDecodedBytes, height: 2)
        }
        #expect(throws: MobileMediaCapture.Failure.self) {
            try MobileMediaCapture.checkedDecodedBytes(bytesPerRow: Int.max, height: 2)
        }
    }

    @Test func backgroundCameraAndScanKeepDimensionsAndSinglePDF() async throws {
        let photo = image(.red)
        let camera = try await MobileMediaCapture.cameraImage(photo)
        defer { camera.remove() }
        #expect(camera.files[0].pathExtension == "jpg")
        let data = try Data(contentsOf: camera.files[0])
        #expect(Array(data.prefix(2)) == [255, 216])
        #expect(UIImage(data: data)?.cgImage?.width == photo.cgImage?.width)
        #expect(UIImage(data: data)?.cgImage?.height == photo.cgImage?.height)
        let pdf = try await MobileMediaCapture.scanPDFOffMain(images: [photo, image(.blue, size: CGSize(width: 60, height: 20))])
        defer { pdf.remove() }
        #expect(pdf.files.count == 1)
        #expect(PDFDocument(url: pdf.files[0])?.pageCount == 2)
    }

    @Test func cameraJPEGKeepsRightOrientationAndRealisticPixelSize() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2016, height: 3024))
            UIColor.blue.setFill(); context.fill(CGRect(x: 2016, y: 0, width: 2016, height: 3024))
        }
        let oriented = UIImage(cgImage: try #require(original.cgImage), scale: 1, orientation: .right)
        let batch = try await MobileMediaCapture.cameraImage(oriented)
        defer { batch.remove() }
        let source = try #require(CGImageSourceCreateWithURL(batch.files[0] as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4032)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 3024)
        #expect(try Data(contentsOf: batch.files[0]).count < 4 * 1024 * 1024)
        #expect(UIImage(contentsOfFile: batch.files[0].path)?.imageOrientation == .right)
    }

    @Test func twentyOnePageScanDoesNotApplyThePerImageBudgetToAllPages() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let batch = try MobileMediaCapture.scanPDF(pageCount: 21) { index in
            UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1700), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1700))
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
            }
        }
        defer { batch.remove() }
        let document = try #require(PDFDocument(url: batch.files[0]))
        #expect(document.pageCount == 21)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 1200, height: 1700))
        #expect(document.page(at: 20)?.bounds(for: .mediaBox).size == CGSize(width: 1200, height: 1700))
        #expect(try batch.files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= MobileMediaCapture.maximumScanBytes)
    }

    @Test func scansAllowMoreThanPhotoLimitButStopAtHundredMiB() throws {
        try MobileMediaCapture.validateScanBytes(26 * 1024 * 1024)
        try MobileMediaCapture.validateScanBytes(100 * 1024 * 1024)
        #expect(throws: MobileMediaCapture.Failure.self) { try MobileMediaCapture.validateScanBytes(100 * 1024 * 1024 + 1) }
    }

    @Test func preparedScanPagesMergeInOrderWithoutOwningTheirSourceLifetime() async throws {
        let first = try await MobileMediaCapture.scanPDFOffMain(images: [image(.red)])
        let second = try await MobileMediaCapture.scanPDFOffMain(images: [image(.blue, size: CGSize(width: 60, height: 20))])
        defer { first.remove(); second.remove() }
        let merged = try await MobileMediaCapture.mergeScanPages([first, second])
        defer { merged.remove() }
        first.remove(); second.remove()
        let document = try #require(PDFDocument(url: merged.files[0]))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).width != document.page(at: 1)?.bounds(for: .mediaBox).width)
    }

}
