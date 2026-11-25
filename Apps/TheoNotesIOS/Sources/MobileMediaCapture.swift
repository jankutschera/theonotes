// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AVFoundation
import CoreTransferable
import Darwin
import ImageIO
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Owns temporary, protected copies until the caller inserts them through the captured editor.
final class MobileMediaBatch: Sendable {
    let directory: URL
    let files: [URL]
    init(directory: URL, files: [URL]) { self.directory = directory; self.files = files }
    deinit { remove() }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    static func directory() throws -> URL {
        var url = FileManager.default.temporaryDirectory.appendingPathComponent("media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        do { try url.setResourceValues(values); return url }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    static func write(_ bytes: Data, filename: String) throws -> MobileMediaBatch {
        guard bytes.count <= MobileMediaCapture.maximumFileBytes else { throw MobileMediaCapture.Failure.tooLarge }
        let directory = try directory()
        do {
            let file = directory.appendingPathComponent(filename)
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            return MobileMediaBatch(directory: directory, files: [file])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Called inside FileRepresentation's import closure, before its provider URL expires.
    static func copyProviderFile(_ source: URL) throws -> MobileMediaBatch {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= MobileMediaCapture.maximumFileBytes else {
            throw MobileMediaCapture.Failure.tooLarge
        }
        let directory = try directory()
        let ext = UTType(filenameExtension: source.pathExtension)?.preferredFilenameExtension ?? "image"
        let target = directory.appendingPathComponent("Photo." + ext)
        do {
            guard FileManager.default.createFile(atPath: target.path, contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            var total = 0
            while true {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(64 * 1024, MobileMediaCapture.maximumFileBytes - total + 1)), !bytes.isEmpty else { break }
                total += bytes.count
                guard total <= MobileMediaCapture.maximumFileBytes else { throw MobileMediaCapture.Failure.tooLarge }
                try output.write(contentsOf: bytes)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, total == before.st_size,
                  before.st_size == after.st_size, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw Failure.fileChanged
            }
            try output.synchronize(); try output.close()
            return MobileMediaBatch(directory: directory, files: [target])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private enum Failure: LocalizedError {
        case fileChanged
        var errorDescription: String? { "The photo changed while it was being copied. Select it again." }
    }
}

enum MobileMediaCapture {
    static let maximumFileBytes = 25 * 1024 * 1024
    static let maximumScanBytes = 100 * 1024 * 1024
    static let maximumItems = 10
    static let maximumDecodedBytes = 128 * 1024 * 1024
    enum Source { case photos, camera, scan }
    enum Failure: LocalizedError {
        case unavailable, permissionDenied, invalidImage, emptyScan, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: "This device does not support this capture method."
            case .permissionDenied: "Camera access is unavailable. Allow Theo Notes camera access in Settings."
            case .invalidImage: "The selected image could not be read."
            case .emptyScan: "The scan has no pages."
            case .tooLarge: "Choose at most 10 photos (25 MB each, 100 MB total) or 50 scan pages (100 MB PDF). A single decoded image must fit within 128 MB."
            }
        }
    }
    @MainActor static var cameraAvailable: Bool { availabilityError(for: .camera) == nil }
    @MainActor static var scannerAvailable: Bool { availabilityError(for: .scan) == nil }
    @MainActor static func availabilityError(for source: Source) -> Failure? {
        if source == .photos { return nil }
        if source == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) { return .unavailable }
        if source == .scan && !VNDocumentCameraViewController.isSupported { return .unavailable }
        let permission = AVCaptureDevice.authorizationStatus(for: .video)
        return permission == .denied || permission == .restricted ? .permissionDenied : nil
    }

    @MainActor static func collectPhotos(_ loads: [@MainActor () async throws -> MobileMediaBatch], contentTypes: [[UTType]] = []) async throws -> MobileMediaBatch? {
        guard !loads.isEmpty else { return nil }
        guard loads.count <= maximumItems else { throw Failure.tooLarge }
        let directory = try MobileMediaBatch.directory()
        var files: [URL] = [], total = 0
        do {
            for (index, load) in loads.enumerated() {
                try Task.checkCancellation()
                let loaded = try await load()
                defer { loaded.remove() }
                try Task.checkCancellation()
                guard let source = loaded.files.first, loaded.files.count == 1 else { throw Failure.invalidImage }
                total += try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard total <= 100 * 1024 * 1024 else { throw Failure.tooLarge }
                let known = UTType(filenameExtension: source.pathExtension)
                let fallback = contentTypes.indices.contains(index) ? contentTypes[index] : []
                let imageType = known?.conforms(to: .image) == true ? known : fallback.first { $0.conforms(to: .image) && $0.preferredFilenameExtension != nil }
                guard let ext = imageType?.preferredFilenameExtension else { throw Failure.invalidImage }
                let target = directory.appendingPathComponent("Photo \(index + 1)." + ext)
                try FileManager.default.moveItem(at: source, to: target)
                files.append(target)
            }
            return MobileMediaBatch(directory: directory, files: files)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func validateScanBytes(_ count: Int) throws {
        guard count >= 0, count <= maximumScanBytes else { throw Failure.tooLarge }
    }

    static func checkedDecodedBytes(bytesPerRow: Int, height: Int) throws -> Int {
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard bytesPerRow > 0, height > 0, !overflow, bytes <= maximumDecodedBytes else { throw Failure.tooLarge }
        return bytes
    }

    static func decodedBytes(_ image: UIImage) throws -> Int {
        guard let raster = image.cgImage else { throw Failure.invalidImage }
        return try checkedDecodedBytes(bytesPerRow: raster.bytesPerRow, height: raster.height)
    }

    static func cameraImage(_ image: UIImage) async throws -> MobileMediaBatch {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            _ = try decodedBytes(image)
            let directory = try MobileMediaBatch.directory()
            do {
                let file = directory.appendingPathComponent("Photo.jpg")
                guard let raster = image.cgImage,
                      let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
                let orientation: Int
                switch image.imageOrientation {
                case .up: orientation = 1
                case .upMirrored: orientation = 2
                case .down: orientation = 3
                case .downMirrored: orientation = 4
                case .leftMirrored: orientation = 5
                case .right: orientation = 6
                case .rightMirrored: orientation = 7
                case .left: orientation = 8
                @unknown default: throw Failure.invalidImage
                }
                let options: [CFString: Any] = [
                    kCGImageDestinationLossyCompressionQuality: 0.85,
                    kCGImagePropertyOrientation: orientation,
                ]
                CGImageDestinationAddImage(destination, raster, options as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
                try Task.checkCancellation()
                guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumFileBytes else { throw Failure.tooLarge }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
                return MobileMediaBatch(directory: directory, files: [file])
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func scanPDFOffMain(images: [UIImage]) async throws -> MobileMediaBatch {
        let worker = Task.detached(priority: .userInitiated) {
            try scanPDF(pageCount: images.count) { images[$0] }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func mergeScanPages(_ pages: [MobileMediaBatch]) async throws -> MobileMediaBatch {
        let worker = Task.detached(priority: .userInitiated) {
            guard !pages.isEmpty, pages.count <= 50 else { throw Failure.emptyScan }
            let directory = try MobileMediaBatch.directory()
            do {
                let document = PDFDocument()
                var total = 0
                for (index, batch) in pages.enumerated() {
                    try Task.checkCancellation()
                    guard batch.files.count == 1, let file = batch.files.first else { throw Failure.invalidImage }
                    total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumScanBytes + 1
                    try validateScanBytes(total)
                    guard let pageDocument = PDFDocument(url: file), pageDocument.pageCount == 1,
                          let page = pageDocument.page(at: 0) else { throw Failure.invalidImage }
                    document.insert(page, at: index)
                }
                let output = directory.appendingPathComponent("Scan.pdf")
                guard document.write(to: output) else { throw Failure.invalidImage }
                try Task.checkCancellation()
                guard let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.invalidImage }
                try validateScanBytes(size)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
                return MobileMediaBatch(directory: directory, files: [output])
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func scanPDF(pageCount: Int, imageAt: (Int) -> UIImage) throws -> MobileMediaBatch {
        guard pageCount > 0 else { throw Failure.emptyScan }
        guard pageCount <= 50 else { throw Failure.tooLarge }
        let directory = try MobileMediaBatch.directory()
        do {
            let document = PDFDocument()
            var pageFiles: [URL] = []
            var total = 0
            for index in 0..<pageCount {
                try Task.checkCancellation()
                // Serialize and release each raster before asking the SDK for the next one.
                // The merged document holds encoded PDF pages, not all original UIImages.
                let pageURL = directory.appendingPathComponent("page-\(index).pdf")
                try autoreleasepool {
                    let image = imageAt(index)
                    _ = try decodedBytes(image)
                    guard let page = PDFPage(image: image, options: [.compressionQuality: 0.75]) else { throw Failure.invalidImage }
                    let single = PDFDocument(); single.insert(page, at: 0)
                    guard single.write(to: pageURL) else { throw Failure.invalidImage }
                }
                total += try pageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumScanBytes + 1
                try validateScanBytes(total)
                guard let single = PDFDocument(url: pageURL), let encodedPage = single.page(at: 0) else { throw Failure.invalidImage }
                document.insert(encodedPage, at: index)
                pageFiles.append(pageURL)
            }
            try Task.checkCancellation()
            let file = directory.appendingPathComponent("Scan.pdf")
            guard document.write(to: file) else { throw Failure.invalidImage }
            try Task.checkCancellation()
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.invalidImage }
            try validateScanBytes(size)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            for page in pageFiles { try FileManager.default.removeItem(at: page) }
            return MobileMediaBatch(directory: directory, files: [file])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

typealias MobileMediaCompletion = @MainActor (Result<MobileMediaBatch?, any Error>) -> Void

private struct MobileTransferredPhoto: Transferable, Sendable {
    let batch: MobileMediaBatch
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            MobileTransferredPhoto(batch: try MobileMediaBatch.copyProviderFile(file.file))
        }
    }
}

extension View {
    func mobilePhotoPicker(isPresented: Binding<Bool>, completion: @escaping MobileMediaCompletion) -> some View {
        modifier(MobilePhotoPicker(isPresented: isPresented, completion: completion))
    }
}

private struct MobilePhotoPicker: ViewModifier {
    @Binding var isPresented: Bool
    let completion: MobileMediaCompletion
    @State private var selection: [PhotosPickerItem] = []
    @State private var loading: Task<Void, Never>?
    @State private var request = UUID()
    @State private var completed = true
    func body(content: Content) -> some View {
        content.photosPicker(isPresented: $isPresented, selection: $selection,
            maxSelectionCount: MobileMediaCapture.maximumItems, selectionBehavior: .ordered,
            matching: .images, preferredItemEncoding: .current)
            .onChange(of: isPresented) { _, presented in
                if presented {
                    request = UUID(); completed = false
                    selection = []; loading?.cancel(); loading = nil
                } else {
                    let current = request
                    Task { @MainActor in
                        await Task.yield()
                        if selection.isEmpty && loading == nil { finish(.success(nil), request: current) }
                    }
                }
            }
            .onChange(of: selection) { _, items in
                guard !items.isEmpty, !completed else { return }
                loading?.cancel()
                let current = request
                loading = Task { @MainActor in
                    do {
                        let loads: [@MainActor () async throws -> MobileMediaBatch] = items.map { item in
                            {
                                guard let photo = try await item.loadTransferable(type: MobileTransferredPhoto.self) else { throw MobileMediaCapture.Failure.invalidImage }
                                return photo.batch
                            }
                        }
                        let batch = try await MobileMediaCapture.collectPhotos(loads, contentTypes: items.map(\.supportedContentTypes))
                        try Task.checkCancellation()
                        finish(.success(batch), request: current)
                    } catch is CancellationError {
                        finish(.success(nil), request: current)
                    } catch { finish(.failure(error), request: current) }
                }
            }
            .onDisappear {
                loading?.cancel()
                finish(.success(nil), request: request)
            }
    }
    private func finish(_ result: Result<MobileMediaBatch?, any Error>, request current: UUID) {
        guard request == current, !completed else { return }
        completed = true
        completion(result)
    }
}

private struct MobileUnavailableMedia: View {
    let error: MobileMediaCapture.Failure
    let completion: MobileMediaCompletion
    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView("Capture Unavailable", systemImage: "camera", description: Text(error.localizedDescription))
            Button("Close") { completion(.failure(error)) }
        }.padding()
    }
}

struct MobileCameraCapture: UIViewControllerRepresentable {
    let completion: MobileMediaCompletion
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIViewController {
        if let error = MobileMediaCapture.availabilityError(for: .camera) {
            return UIHostingController(rootView: MobileUnavailableMedia(error: error, completion: completion))
        }
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let completion: MobileMediaCompletion
        private var finished = false
        private var processing: Task<Void, Never>?
        init(_ completion: @escaping MobileMediaCompletion) { self.completion = completion }
        private func finish(_ result: Result<MobileMediaBatch?, any Error>) {
            guard !finished else { return }; finished = true; processing?.cancel(); processing = nil; completion(result)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(.success(nil)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard !finished, processing == nil else { return }
            guard let image = info[.originalImage] as? UIImage else { finish(.failure(MobileMediaCapture.Failure.invalidImage)); return }
            processing = Task { @MainActor in
                do { finish(.success(try await MobileMediaCapture.cameraImage(image))) }
                catch is CancellationError { finish(.success(nil)) }
                catch { finish(.failure(error)) }
            }
        }
    }
}

struct MobileDocumentCapture: UIViewControllerRepresentable {
    let completion: MobileMediaCompletion
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIViewController {
        if let error = MobileMediaCapture.availabilityError(for: .scan) {
            return UIHostingController(rootView: MobileUnavailableMedia(error: error, completion: completion))
        }
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        private let completion: MobileMediaCompletion
        private var finished = false
        private var processing: Task<Void, Never>?
        init(_ completion: @escaping MobileMediaCompletion) { self.completion = completion }
        private func finish(_ result: Result<MobileMediaBatch?, any Error>) {
            guard !finished else { return }; finished = true; processing?.cancel(); processing = nil; completion(result)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { finish(.success(nil)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) { finish(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard !finished, processing == nil else { return }
            do {
                guard scan.pageCount > 0 else { throw MobileMediaCapture.Failure.emptyScan }
                guard scan.pageCount <= 50 else { throw MobileMediaCapture.Failure.tooLarge }
                // Scan is not Sendable: extract ONE page on MainActor, then await its worker
                // serialization before extracting another. Never retain an array of full rasters.
                processing = Task { @MainActor in
                    var pages: [MobileMediaBatch] = []
                    defer { for page in pages { page.remove() } }
                    do {
                        var total = 0
                        for index in 0..<scan.pageCount {
                            try Task.checkCancellation()
                            let image = scan.imageOfPage(at: index)
                            _ = try MobileMediaCapture.decodedBytes(image)
                            let page = try await MobileMediaCapture.scanPDFOffMain(images: [image])
                            pages.append(page)
                            total += try page.files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? MobileMediaCapture.maximumScanBytes + 1
                            try MobileMediaCapture.validateScanBytes(total)
                        }
                        finish(.success(try await MobileMediaCapture.mergeScanPages(pages)))
                    } catch is CancellationError { finish(.success(nil)) }
                    catch { finish(.failure(error)) }
                }
            } catch { finish(.failure(error)) }
        }
    }
}
