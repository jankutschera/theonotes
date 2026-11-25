// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import BaerchenIOS

@Suite @MainActor struct MobileSketchCanvasGeometryTests {
    private func drawing(from: CGPoint, to: CGPoint) -> PKDrawing {
        let points = [from, to].enumerated().map { index, location in
            PKStrokePoint(location: location, timeOffset: Double(index) * 0.1,
                size: CGSize(width: 8, height: 8), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue),
            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
    }
    @Test func zoomCannotShrinkContentOrBounceBeyondItsEdges() throws {
        let value = drawing(from: CGPoint(x: 0, y: 32), to: CGPoint(x: 256, y: 32))
        let session = try MobileSketchSession(drawing: value, canvasSize: CGSize(width: 256, height: 256))
        defer { session.teardown() }
        #expect(session.canvas.minimumZoomScale == 1 && session.canvas.maximumZoomScale == 2)
        #expect(!session.canvas.bounces && !session.canvas.bouncesZoom)
        #expect(session.canvas.contentInsetAdjustmentBehavior == .never)
        #expect(session.canvas.drawing == value)
    }
    @Test func smallRestoredCanvasHasNoLargerDrawingViewport() async throws {
        let value = drawing(from: CGPoint(x: 8, y: 12), to: CGPoint(x: 40, y: 30))
        let editor = try MobileSketchEditor(initialDrawing: value, canvasSize: CGSize(width: 64, height: 48),
            onDone: { _, _ in }, onCancel: {})
        let hosting = UIHostingController(rootView: editor)
        // NavigationStack requires a real controller/window presentation lifecycle;
        // adding only hosting.view to a detached UIView never mounted its content.
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        #expect(window.bounds.width > 64 && window.bounds.height > 48)
        @MainActor func canvas(in view: UIView) -> PKCanvasView? {
            if let canvas = view as? PKCanvasView { return canvas }
            return view.subviews.lazy.compactMap { canvas(in: $0) }.first
        }
        var found: PKCanvasView?
        for _ in 0..<100 {
            window.setNeedsLayout(); window.layoutIfNeeded()
            hosting.view.setNeedsLayout(); hosting.view.layoutIfNeeded()
            found = canvas(in: hosting.view)
            if let found, found.bounds.width > 0, found.bounds.height > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let actual = try #require(found)
        #expect(actual.window === window)
        #expect(hosting.view.bounds.width > 64 && hosting.view.bounds.height > 48)
        #expect(actual.bounds.width > 0 && actual.bounds.width <= 64)
        #expect(actual.bounds.height > 0 && actual.bounds.height <= 48)
        #expect(actual.drawing == value)
    }
    @Test func capturedEdgeTailCheckpointsRestoresAndSavesWithoutDroppingArchive() async throws {
        let value = drawing(from: CGPoint(x: 16, y: 16), to: CGPoint(x: 900, y: 16))
        var snapshot: MobileSketchCheckpoint?
        let size = CGSize(width: 256, height: 256)
        let session = try MobileSketchSession(drawing: value, canvasSize: size, onCheckpoint: { snapshot = $0 })
        defer { session.teardown() }
        session.activateDraftHooks()
        _ = session.checkpointNow(force: true)
        let saved = try #require(snapshot)
        let archived = try PKDrawing(data: saved.drawingData)
        #expect(archived == value)
        let reopened = try MobileSketchSession(drawing: archived, canvasSize: saved.canvasSize)
        defer { reopened.teardown() }
        var submitted = false
        reopened.save { drawing, canvas in
            #expect(drawing == value && canvas == size)
            let raster = try #require(drawing.image(from: CGRect(origin: .zero, size: canvas), scale: 1).cgImage)
            #expect(raster.width == 256 && raster.height == 256)
            let png = try MobileSketchPNG.embed(drawing: drawing, in: MobileSketchPNG.pngForNewSketch(from: raster))
            #expect(try MobileSketchPNG.drawing(in: png) == value)
            submitted = true
        }
        await reopened.waitForSave()
        #expect(submitted && reopened.isFinished)
    }
}
