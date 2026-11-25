// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Pure image operations: no attachment, note, filesystem or sketch-classification access.
/// Integration must refuse destructive crop for recognized editable sketches separately.
enum MobileImageCrop {
    static let maximumInputBytes = 64 * 1024 * 1024
    private static let maximumDimension = 8192
    // Includes standard 8064×6048 (48MP) photos. Explicit RGBA working rasters
    // are each bounded to 192MiB; a full crop can retain two (384MiB), plus
    // compressed input/output and ImageIO internals. Physical jetsam acceptance is required.
    private static let maximumPixels = 50_331_648
    private static let maximumHighDepthPixels = 16_777_216

    struct PixelRect: Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }
    /// Immutable CoreGraphics raster; all decoding/conversion completes before publication.
    struct Prepared: @unchecked Sendable {
        let image: CGImage
        fileprivate let jpeg: Bool
        fileprivate init(image: CGImage, jpeg: Bool = false) { self.image = image; self.jpeg = jpeg }
        var width: Int { image.width }
        var height: Int { image.height }
    }
    enum Failure: Error, Equatable, LocalizedError {
        case invalidImage, tooLarge, invalidRectangle, encodingFailed
        var errorDescription: String? {
            switch self {
            case .invalidImage: "This image could not be opened."
            case .tooLarge: "This image is too large to crop safely."
            case .invalidRectangle: "Choose a crop inside the image."
            case .encodingFailed: "The cropped image could not be created."
            }
        }
    }

    nonisolated static func prepare(data: Data) async throws -> Prepared {
        try await background {
            guard data.count <= maximumInputBytes else { throw Failure.tooLarge }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.invalidImage }
            guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                  width <= maximumPixels / height else { throw Failure.tooLarge }
            // Preserve the existing 16-bit input support without granting it the much
            // larger 8-bit photo budget. Check metadata BEFORE allocating that raster.
            let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
            guard depth > 0, depth <= 16 else { throw Failure.tooLarge }
            if depth > 8, width > maximumHighDepthPixels / height { throw Failure.tooLarge }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            guard (1...8).contains(orientation) else { throw Failure.invalidImage }
            try Task.checkCancellation()
            // Always transform EXIF before pixel coordinates are exposed. No resizing is allowed.
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldAllowFloat: false,
            ] as CFDictionary) else { throw Failure.invalidImage }
            let swapped = (5...8).contains(orientation)
            guard decoded.width == (swapped ? height : width), decoded.height == (swapped ? width : height),
                  CGImageSourceGetStatusAtIndex(source, 0).rawValue == 0 else { throw Failure.invalidImage }
            try Task.checkCancellation()
            // Retain only ImageIO's orientation-correct raster. Do not allocate a
            // second full-size normalization buffer for the interactive crop preview.
            // Reject unsupported working formats rather than silently downsampling.
            if decoded.bitsPerComponent <= 8 {
                guard decoded.bitsPerComponent > 0, decoded.bitsPerPixel <= 32,
                      decoded.bytesPerRow <= maximumPixels * 4 / decoded.height else { throw Failure.tooLarge }
            } else {
                guard decoded.bitsPerComponent <= 16, decoded.bitsPerPixel <= 64,
                      decoded.width <= maximumHighDepthPixels / decoded.height,
                      decoded.bytesPerRow <= maximumHighDepthPixels * 8 / decoded.height else { throw Failure.tooLarge }
            }
            return Prepared(image: decoded, jpeg: CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        }
    }

    /// Coordinates are integer pixels from the top-left of the orientation-normalized raster.
    nonisolated static func crop(_ prepared: Prepared, rect: PixelRect) async throws -> Data {
        try await background {
            guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
                  rect.x < prepared.width, rect.y < prepared.height,
                  rect.width <= prepared.width - rect.x, rect.height <= prepared.height - rect.y
            else { throw Failure.invalidRectangle }
            guard let cropped = prepared.image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            else { throw Failure.invalidRectangle }
            // Normalize only the selected region, preserving alpha and sRGB output.
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: rect.width, height: rect.height,
                    bitsPerComponent: 8, bytesPerRow: rect.width * 4, space: color,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw Failure.invalidImage }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            guard let normalized = context.makeImage() else { throw Failure.invalidImage }
            try Task.checkCancellation()
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, (prepared.jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
            else { throw Failure.encodingFailed }
            // Pixels already carry the EXIF transform; do not copy stale orientation or
            // private source metadata. JPEG necessarily re-encodes at explicit high quality.
            let properties: [CFString: Any] = prepared.jpeg
                ? [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.95]
                : [:]
            CGImageDestinationAddImage(destination, normalized, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
            guard output.length <= maximumInputBytes else { throw Failure.tooLarge }
            return output as Data
        }
    }

    nonisolated private static func background<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try work()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}

/// Production-used completion fence. Even an encoder that ignores cancellation cannot deliver
/// bytes after cancel/dismiss, or deliver twice after repeated Crop taps.
@MainActor @Observable final class MobileImageCropSession {
    let prepared: MobileImageCrop.Prepared
    var rect: MobileImageCrop.PixelRect
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private var closed = false
    var isClosed: Bool { closed }
    private var generation = 0
    private var operation: Task<Void, Never>?
    private let encode: @Sendable (MobileImageCrop.Prepared, MobileImageCrop.PixelRect) async throws -> Data

    init(prepared: MobileImageCrop.Prepared,
         encode: @escaping @Sendable (MobileImageCrop.Prepared, MobileImageCrop.PixelRect) async throws -> Data = { try await MobileImageCrop.crop($0, rect: $1) }) {
        self.prepared = prepared
        rect = .init(x: 0, y: 0, width: prepared.width, height: prepared.height)
        self.encode = encode
    }
    func confirm(onComplete: @escaping @MainActor (Data) async throws -> Void) {
        guard !closed, !isWorking else { return }
        isWorking = true; errorMessage = nil; generation += 1
        UIAccessibility.post(notification: .announcement, argument: "Saving cropped image")
        let token = generation, selection = rect, prepared = prepared, encode = encode
        operation = Task { [weak self] in
            do {
                let bytes = try await encode(prepared, selection)
                guard let self, !Task.isCancelled, !self.closed, self.generation == token else { return }
                // Keep both the selection and prepared raster alive until the host confirms
                // durable storage/bridge acknowledgement. A throw leaves this same draft editable.
                // Host work must honor cancellation and fence its own stale/uncertain writes.
                try await onComplete(bytes)
                guard !Task.isCancelled, !self.closed, self.generation == token else { return }
                self.isWorking = false; self.closed = true
            } catch {
                guard let self, !self.closed, self.generation == token else { return }
                self.isWorking = false
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                    UIAccessibility.post(notification: .announcement, argument: "Crop failed: " + error.localizedDescription)
                }
            }
        }
    }
    @discardableResult func cancel() -> Bool {
        guard !closed else { return false }
        closed = true; generation += 1; isWorking = false
        operation?.cancel()
        return true
    }
    /// May be used by host teardown when it needs an explicit worker completion barrier.
    func waitForCompletion() async { await operation?.value }
}

@MainActor struct MobileImageCropView: View {
    @State private var session: MobileImageCropSession
    let onComplete: @MainActor (Data) async throws -> Void
    let onCancel: @MainActor () -> Void

    init(prepared: MobileImageCrop.Prepared, onComplete: @escaping @MainActor (Data) async throws -> Void,
         onCancel: @escaping @MainActor () -> Void) {
        _session = State(initialValue: MobileImageCropSession(prepared: prepared))
        self.onComplete = onComplete; self.onCancel = onCancel
    }
    private func coordinate(_ keyPath: WritableKeyPath<MobileImageCrop.PixelRect, Int>, maximum: Int) -> Binding<Double> {
        Binding(get: { Double(session.rect[keyPath: keyPath]) }, set: { value in
            var rect = session.rect
            rect[keyPath: keyPath] = min(maximum, max(keyPath == \.width || keyPath == \.height ? 1 : 0, Int(value.rounded())))
            rect.width = min(rect.width, session.prepared.width - rect.x)
            rect.height = min(rect.height, session.prepared.height - rect.y)
            session.rect = rect
        })
    }
    private func adjustment(_ title: String, value: Binding<Double>, minimum: Int, maximum: Int) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue)) pixels")
            if maximum > minimum {
                Slider(value: value, in: Double(minimum)...Double(maximum), step: 1)
                    .accessibilityLabel(title).accessibilityValue("\(Int(value.wrappedValue)) pixels")
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { if session.cancel() { onCancel() } }
                Spacer()
                Text("Crop image").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Crop") { session.confirm(onComplete: onComplete) }.disabled(session.isWorking || session.isClosed)
            }.padding()
            ScrollView {
                VStack(spacing: 20) {
                    Image(decorative: session.prepared.image, scale: 1, orientation: .up)
                        .resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                Rectangle().stroke(.white, lineWidth: 3).shadow(color: .black, radius: 1)
                                    .frame(width: geometry.size.width * CGFloat(session.rect.width) / CGFloat(session.prepared.width),
                                           height: geometry.size.height * CGFloat(session.rect.height) / CGFloat(session.prepared.height))
                                    .offset(x: geometry.size.width * CGFloat(session.rect.x) / CGFloat(session.prepared.width),
                                            y: geometry.size.height * CGFloat(session.rect.y) / CGFloat(session.prepared.height))
                            }.accessibilityHidden(true)
                        }
                        .accessibilityLabel("Image crop preview")
                    adjustment("Left", value: coordinate(\.x, maximum: session.prepared.width - 1), minimum: 0, maximum: session.prepared.width - 1)
                    adjustment("Top", value: coordinate(\.y, maximum: session.prepared.height - 1), minimum: 0, maximum: session.prepared.height - 1)
                    adjustment("Width", value: coordinate(\.width, maximum: session.prepared.width - session.rect.x), minimum: 1, maximum: session.prepared.width - session.rect.x)
                    adjustment("Height", value: coordinate(\.height, maximum: session.prepared.height - session.rect.y), minimum: 1, maximum: session.prepared.height - session.rect.y)
                    if session.isWorking { ProgressView("Saving cropped image") }
                    if let error = session.errorMessage { Text(error).foregroundStyle(.red).accessibilityLabel("Crop failed: \(error)").accessibilityAddTraits(.updatesFrequently) }
                }.padding().disabled(session.isWorking || session.isClosed)
            }
            .onDisappear { session.cancel() }
        }
    }
}
