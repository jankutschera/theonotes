// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import XCTest
import UIKit
import UniformTypeIdentifiers
import TheoNotesCore

/// Compile the model and builder into the iOS unit test target, as the Mac share tests do.
@MainActor
final class IOSShareSheetTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testEmptyEditedTextKeepsSharedPayloadAndEnqueuesOnlyOnce() async throws {
        let container = try directory()
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        let model = ShareSheetModel(container: container)
        await model.collect(texts: ["Exact **source**"], loads: [], staging: staging)
        model.userEdited("")
        XCTAssertTrue(model.canSave)
        let submitted = await model.submit(target: nil)
        XCTAssertTrue(submitted)
        let repeated = await model.submit(target: nil)
        XCTAssertFalse(repeated)
        let inbox = container.appendingPathComponent("CaptureInbox")
        let items = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(items.count, 1)
        let request = try JSONDecoder().decode(CaptureRequest.self, from: Data(contentsOf: items[0].appendingPathComponent("request.json")))
        XCTAssertEqual(request.text, "Exact **source**")
        XCTAssertEqual(request.mode, .save)
    }

    func testFailureDisablesPartialSaveAndInvalidContainerHasNoFallback() async throws {
        let container = try directory()
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        let model = ShareSheetModel(container: container)
        await model.collect(texts: ["Keep me"], loads: [{ _ in .failed }], staging: staging)
        XCTAssertFalse(model.canSave)
        let submitted = await model.submit(target: nil)
        XCTAssertFalse(submitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("CaptureInbox").path))
        XCTAssertFalse(ShareSheetModel(container: nil).canSave)
    }

    func testRevokedPickerCannotAppend() async throws {
        let container = try directory()
        let id = UUID().uuidString.lowercased()
        try SharedContainerFiles.publish(RecentNotesFile(notes: [.init(id: id, title: "Private later")]), in: container)
        let model = ShareSheetModel(container: container)
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        await model.collect(texts: ["append"], loads: [], staging: staging)
        XCTAssertTrue(model.canAppend)
        try SharedContainerFiles.publish(nil, in: container)
        let submitted = await model.submit(target: id)
        XCTAssertFalse(submitted)
        XCTAssertTrue(model.recentNotes.isEmpty)
    }

    func testStagingCopiesBytesAndRejectsSymlink() throws {
        let container = try directory()
        let source = container.appendingPathComponent("source.png")
        try Data([1, 2, 3]).write(to: source)
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        let first = try staging.stage(source, suggestedName: "../photo.png")
        let second = try staging.stage(source, suggestedName: "../photo.png")
        XCTAssertNotEqual(first, second)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        let link = container.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        XCTAssertThrowsError(try staging.stage(link, suggestedName: nil))
    }

    func testStagingStreamsMultipleChunksAndRejectsOversize() throws {
        let container = try directory()
        let source = container.appendingPathComponent("source.bin")
        let bytes = Data(repeating: 0x43, count: 128 * 1024 + 13)
        try bytes.write(to: source)
        let output = container.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var taken = Set<String>()
        var reads = 0
        let copy = try ShareRequestBuilder.stage(source, suggestedName: nil, into: output, taken: &taken) { _ in reads += 1 }
        XCTAssertGreaterThan(reads, 1)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 25 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try ShareRequestBuilder.stage(source, suggestedName: nil, into: output, taken: &taken))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
    }

    func testStagingRejectsTruncatedOrRewrittenSourceAndRemovesPartialCopy() throws {
        let container = try directory()
        let source = container.appendingPathComponent("source.bin")
        let output = container.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var taken = Set<String>()
        try Data(repeating: 1, count: 128 * 1024).write(to: source)
        XCTAssertThrowsError(try ShareRequestBuilder.stage(source, suggestedName: nil, into: output, taken: &taken) { count in
            if count == 64 * 1024 {
                let handle = try FileHandle(forWritingTo: source)
                try handle.truncate(atOffset: 0)
                try handle.close()
            }
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: source.path)
        XCTAssertThrowsError(try ShareRequestBuilder.stage(source, suggestedName: nil, into: output, taken: &taken) { _ in
            let handle = try FileHandle(forWritingTo: source)
            try handle.write(contentsOf: Data([4, 5, 6]))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: source.path)
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        XCTAssertThrowsError(try ShareRequestBuilder.stage(source, suggestedName: nil, into: output, taken: &taken) { _ in
            throw CancellationError()
        })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    func testShareControlsSupportDynamicTypeAndHeading() throws {
        let container = try directory()
        let controller = ShareViewController()
        controller.resolveContainer = { container }
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.loadViewIfNeeded()
        let controls = descendants(of: controller.view)
        let heading = try XCTUnwrap(controls.compactMap { $0 as? UILabel }.first { $0.text == "Share to Theo Notes" })
        XCTAssertTrue(heading.accessibilityTraits.contains(.header))
        XCTAssertTrue(heading.adjustsFontForContentSizeCategory)
        let buttons = controls.compactMap { $0 as? UIButton }.filter { ["Cancel", "Save", "Append to Note…"].contains($0.title(for: .normal) ?? "") }
        XCTAssertEqual(buttons.count, 3)
        for button in buttons {
            XCTAssertTrue(try XCTUnwrap(button.titleLabel).adjustsFontForContentSizeCategory)
            XCTAssertEqual((button.superview as? UIStackView)?.axis, .vertical)
            XCTAssertEqual(button.titleLabel?.numberOfLines, 0)
        }
    }

    func testStatusAndErrorsAreAnnouncedOnceWhenVisible() async throws {
        let container = try directory()
        let controller = ShareViewController()
        controller.resolveContainer = { container }
        var announcements: [String] = []
        controller.announce = { announcements.append($0) }
        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)
        XCTAssertEqual(announcements, ["Reading shared content…"])
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        await controller.model.collect(texts: [], loads: [{ _ in .failed }], staging: staging)
        XCTAssertEqual(announcements.last, "Some shared content could not be read or is too large. Cancel and share fewer items.")
        XCTAssertEqual(announcements.count, 2)
        controller.model.userEdited("typing does not repeat an unchanged error")
        XCTAssertEqual(announcements.count, 2)
    }

    func testMultipleImageProvidersPreserveOrderNamesAndDurableBytes() async throws {
        let container = try directory()
        let data = try [UIColor.red, UIColor.blue].map { color in
            try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }.pngData())
        }
        let sources = try data.enumerated().map { index, bytes in
            let url = container.appendingPathComponent("source-\(index).png")
            try bytes.write(to: url)
            return url
        }
        let providers = sources.map { source in
            let provider = NSItemProvider()
            provider.suggestedName = "photo"
            provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
                completion(source, false, nil)
                return nil
            }
            return provider
        }
        let staging = try StagingArea(directory: container.appendingPathComponent("staging"))
        let model = ShareSheetModel(container: container)
        let loads: [@MainActor (StagingArea) async -> SharedPart] = providers.map { provider in
            { area in await ShareViewController.load(provider, staging: area) }
        }
        await model.collect(texts: [], loads: loads, staging: staging)
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.files.map(\.lastPathComponent), ["photo.png", "photo 2.png"])
        for source in sources { try FileManager.default.removeItem(at: source) }
        let submitted = await model.submit(target: nil)
        XCTAssertTrue(submitted)
        staging.remove()
        let inbox = container.appendingPathComponent("CaptureInbox")
        let items = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        let request = try JSONDecoder().decode(CaptureRequest.self, from: Data(contentsOf: item.appendingPathComponent("request.json")))
        XCTAssertEqual(request.files, ["photo.png", "photo 2.png"])
        for (name, bytes) in zip(request.files, data) {
            XCTAssertEqual(try Data(contentsOf: item.appendingPathComponent(name)), bytes)
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

}
