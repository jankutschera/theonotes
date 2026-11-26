// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import TheoNotes

/// on the Mac: the controller with a fake source and fake Finder/pasteboard. No MetricKit,
/// no real Application Support folder.
@MainActor
@Suite struct DiagnosticsControllerTests {
    private struct FakeSource: DiagnosticsSource {
        let stream: AsyncStream<[DiagnosticsRecord]>
        func reports() -> AsyncStream<[DiagnosticsRecord]> { stream }
    }

    private final class Box: @unchecked Sendable {
        var opened: [URL] = []
        var copied: [String] = []
    }

    private static let canary = "CANARY-secret-diary-entry-7731 about my dentist"

    private func makeController(
        source: AsyncStream<[DiagnosticsRecord]> = AsyncStream { $0.finish() }, box: Box = Box()
    ) -> (DiagnosticsController, Box) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-controller-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Theo Notes Diagnostics", isDirectory: true)
        let controller = DiagnosticsController(
            store: DiagnosticsStore(folder: folder), source: FakeSource(stream: source), appVersion: "1.0 (7)",
            osVersion: "Version 27.0 (Build 27A1)", openFolder: { box.opened.append($0) }, copyText: { box.copied.append($0) })
        return (controller, box)
    }

    private func record(_ kind: DiagnosticsRecord.Kind = .hang) -> DiagnosticsRecord {
        DiagnosticsRecord(
            kind: kind, receivedAt: Date(), periodStart: nil, periodEnd: nil, appVersion: "1.0", appBuild: "7",
            osVersion: "macOS 27.0 (27A1)", facts: ["hangSeconds": "2.500", "composedMessage": Self.canary], stacks: [])
    }

    @Test func showingReportsCreatesTheFolderAndOpensIt() {
        let (controller, box) = makeController()
        #expect(!FileManager.default.fileExists(atPath: controller.store.folder.path))
        controller.showReports()
        #expect(box.opened == [controller.store.folder])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: controller.store.folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func startStoresWhatTheSourceDeliversAndCopySummaryListsIt() async throws {
        let (stream, continuation) = AsyncStream<[DiagnosticsRecord]>.makeStream()
        let (controller, box) = makeController(source: stream)
        controller.start()
        controller.start() // twice is harmless
        continuation.yield([record(.hang), record(.crash)])
        for _ in 0..<200 where controller.store.entries().count < 2 { try await Task.sleep(for: .milliseconds(25)) }
        continuation.finish()
        #expect(controller.store.entries().count == 2)

        controller.copySummary()
        #expect(box.copied.count == 1)
        let text = box.copied[0]
        #expect(text.contains("Theo Notes diagnostics"))
        #expect(text.contains("1.0 (7)"))
        #expect(text.contains("hang"))
        #expect(text.contains("crash"))
        #expect(!text.contains("CANARY"))
        for entry in controller.store.entries() { #expect(text.contains(entry.url.lastPathComponent)) }
        controller.stop()
    }

    @Test func copySummaryWithoutReportsSaysSoAndWritesNothing() {
        let (controller, box) = makeController()
        controller.copySummary()
        #expect(box.copied.first?.contains("No reports") == true)
        #expect(!FileManager.default.fileExists(atPath: controller.store.folder.path))
    }

    @Test func theMenuTextIsPlainAndCarriesNoInternalNames() {
        for title in [DiagnosticsMenu.showReports, DiagnosticsMenu.copySummary] {
            #expect(!title.isEmpty)
            let lower = title.lowercased()
            #expect(!lower.contains("adhd"))
            #expect(!lower.contains("adhs"))
            #expect(!lower.contains("metrickit"))
            #expect(!lower.contains("baerchen"))
        }
    }

    @Test func theHangHookNeedsDebugDevAndTheArgument() {
        #expect(DiagnosticsDebugHooks.simulatedHangRequested(arguments: ["app"], identity: .dev) == false)
        #expect(DiagnosticsDebugHooks.simulatedHangRequested(arguments: ["app", "--simulate-hang"], identity: .production) == false)
        #if DEBUG
        #expect(DiagnosticsDebugHooks.simulatedHangRequested(arguments: ["app", "--simulate-hang"], identity: .dev))
        #else
        #expect(DiagnosticsDebugHooks.simulatedHangRequested(arguments: ["app", "--simulate-hang"], identity: .dev) == false)
        #endif
    }

    @Test func theLiveFolderIsOutsideTheLibraryOfTheSameIdentity() {
        let live = DiagnosticsLocation.live
        let library = AppPaths.production.root
        #expect(live.standardizedFileURL != library.standardizedFileURL)
        #expect(!live.standardizedFileURL.path.hasPrefix(library.standardizedFileURL.path + "/"))
    }
}
