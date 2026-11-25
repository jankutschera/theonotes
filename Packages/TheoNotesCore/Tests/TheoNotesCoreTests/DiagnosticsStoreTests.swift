// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// REL-R40 … REL-R46: what is written for a crash or hang report, where, and how long it stays.
@Suite struct DiagnosticsStoreTests {
    /// A note's unique text. It must never appear in a file the store writes.
    static let canary = "CANARY-secret-diary-entry-7731 about my dentist"

    private func makeFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Theo Notes Diagnostics", isDirectory: true)
    }

    private func record(
        kind: DiagnosticsRecord.Kind = .crash, at date: Date = Date(timeIntervalSince1970: 1_800_000_000),
        facts: [String: String] = ["signal": "11"], frames: Int = 3
    ) -> DiagnosticsRecord {
        DiagnosticsRecord(
            kind: kind, receivedAt: date, periodStart: date.addingTimeInterval(-86_400), periodEnd: date,
            appVersion: "1.0", appBuild: "42", osVersion: "macOS 27.0 (27A1)", facts: facts,
            stacks: [DiagnosticsRecord.CallStack(
                attributed: true,
                frames: (0..<frames).map {
                    DiagnosticsRecord.Frame(
                        depth: $0, binaryName: "Theo Notes", binaryUUID: UUID().uuidString, offset: UInt64($0) * 16,
                        address: nil, samples: 1)
                })])
    }

    private func files(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    // MARK: Where

    @Test func theFolderIsASiblingOfTheLibraryNeverInsideIt() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        for identity in AppIdentity.allCases {
            let library = AppPaths.production(applicationSupport: support, identity: identity).root
            let folder = DiagnosticsLocation.folder(applicationSupport: support, identity: identity)
            #expect(folder.deletingLastPathComponent().standardizedFileURL == support.standardizedFileURL)
            #expect(!folder.standardizedFileURL.path.hasPrefix(library.standardizedFileURL.path + "/"))
            #expect(folder.standardizedFileURL != library.standardizedFileURL)
            #expect(folder.lastPathComponent == library.lastPathComponent + " Diagnostics")
        }
        // The dev build never writes next to Jan's production reports.
        #expect(
            DiagnosticsLocation.folder(applicationSupport: support, identity: .dev)
                != DiagnosticsLocation.folder(applicationSupport: support, identity: .production))
    }

    // MARK: What is written

    @Test func aSavedReportIsOneJSONFileThatReadsBack() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let saved = record()
        let url = try store.save(saved, now: saved.receivedAt)
        #expect(url.deletingLastPathComponent().standardizedFileURL == store.folder.standardizedFileURL)
        #expect(url.pathExtension == "json")
        #expect(url.lastPathComponent.contains("crash"))
        let entries = store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.url.lastPathComponent == url.lastPathComponent)
        #expect(entries.first?.record?.kind == .crash)
        #expect(entries.first?.record?.facts["signal"] == "11")
        #expect(entries.first?.record?.stacks.first?.frames.count == 3)
    }

    @Test func theFolderAndFilesAreOnlyForTheOwner() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let url = try store.save(record(), now: Date())
        let dirMode = try FileManager.default.attributesOfItem(atPath: store.folder.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test func noNoteTextReachesTheFileWhereverItHides() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let hostile = DiagnosticsRecord(
            kind: .crash, receivedAt: Date(), periodStart: nil, periodEnd: nil,
            appVersion: Self.canary, appBuild: Self.canary, osVersion: Self.canary,
            facts: [
                "signal": "6",
                // Free-text fields of a MetricKit payload and unknown keys: dropped by key.
                "composedMessage": Self.canary, "formatString": Self.canary, "arguments": Self.canary,
                "somethingNew": Self.canary,
                // Allowed keys with a value that is not a plain token: dropped by value.
                "terminationReason": Self.canary + "\n\"quoted\" {json}",
                "exceptionName": String(repeating: Self.canary, count: 20),
            ],
            stacks: [DiagnosticsRecord.CallStack(
                attributed: true,
                frames: [DiagnosticsRecord.Frame(
                    depth: 0, binaryName: Self.canary + "/\"x\"", binaryUUID: Self.canary, offset: 1, address: 2,
                    samples: 3)])])
        let url = try store.save(hostile, now: Date())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("CANARY"))
        #expect(!text.contains("dentist"))
        #expect(!text.contains("diary"))
        // What is allowed still arrives.
        #expect(text.contains("\"signal\""))
        let back = store.entries().first?.record
        #expect(back?.facts["signal"] == "6")
        #expect(back?.facts["composedMessage"] == nil)
        #expect(back?.stacks.first?.frames.first?.offset == 1)
        #expect(back?.stacks.first?.frames.first?.binaryName == nil)
    }

    @Test func systemVersionsFromBothMetricKitGenerationsSurvive() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        for system in ["macOS 27.0 (27A1)", "macOS 26.1", "iPhone OS 27.0 (27A5)"] {
            var saved = record()
            saved.osVersion = system
            _ = try store.save(saved, now: Date())
        }
        let systems = Set(store.entries().compactMap { $0.record?.osVersion })
        #expect(systems == ["macOS 27.0 (27A1)", "macOS 26.1", "iPhone OS 27.0 (27A5)"])
    }

    @Test func theSummaryTheUserCopiesCarriesNoNoteTextEither() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        _ = try store.save(record(facts: ["signal": "6", "composedMessage": Self.canary]), now: Date())
        let entries = store.entries()
        let text = DiagnosticsSummary.text(
            appName: "Theo Notes", appVersion: "1.0 (42)", osVersion: "macOS 27.0", entries: entries)
        #expect(!text.contains("CANARY"))
        #expect(text.contains("Theo Notes"))
        #expect(text.contains("1.0 (42)"))
        #expect(text.contains("macOS 27.0"))
        #expect(text.contains("crash"))
        #expect(text.contains(entries[0].url.lastPathComponent))
        #expect(text.contains("signal 6"))
    }

    @Test func theSummaryOfNothingSaysSo() {
        let text = DiagnosticsSummary.text(appName: "Theo Notes", appVersion: "1.0", osVersion: "macOS 27.0", entries: [])
        #expect(text.contains("No reports"))
    }

    @Test func aHugeReportIsTrimmedToTheFileLimitRatherThanRefused() throws {
        let retention = DiagnosticsRetention(maxFiles: 20, maxAge: 86_400 * 90, maxTotalBytes: 2_000_000, maxFileBytes: 20_000)
        let store = DiagnosticsStore(folder: makeFolder(), retention: retention)
        let url = try store.save(record(frames: 5_000), now: Date())
        #expect(size(of: url) <= 20_000)
        #expect(store.entries().first?.record?.kind == .crash)
    }

    // MARK: How long

    @Test func onlyTheNewestTwentyFilesStay() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<25 {
            let when = start.addingTimeInterval(Double(index) * 3_600)
            _ = try store.save(record(at: when), now: when)
        }
        let kept = store.entries()
        #expect(kept.count == 20)
        // Newest first; the five oldest are gone.
        let times = kept.compactMap { $0.record?.receivedAt }
        #expect(times == times.sorted(by: >))
        #expect(times.last == start.addingTimeInterval(5 * 3_600))
        #expect(files(in: store.folder).count == 20)
    }

    @Test func reportsOlderThanTheAgeLimitGoWhenTheNextOneArrives() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.save(record(at: old), now: old)
        let fresh = old.addingTimeInterval(86_400 * 91)
        _ = try store.save(record(kind: .hang, at: fresh), now: fresh)
        let kept = store.entries()
        #expect(kept.count == 1)
        #expect(kept.first?.record?.kind == .hang)
    }

    @Test func pruneAloneAppliesTheAgeLimit() throws {
        let store = DiagnosticsStore(folder: makeFolder())
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.save(record(at: old), now: old)
        store.prune(now: old.addingTimeInterval(86_400 * 89))
        #expect(store.entries().count == 1)
        store.prune(now: old.addingTimeInterval(86_400 * 91))
        #expect(store.entries().isEmpty)
    }

    @Test func theTotalSizeIsBoundedByDroppingTheOldest() throws {
        let retention = DiagnosticsRetention(maxFiles: 20, maxAge: 86_400 * 90, maxTotalBytes: 6_000, maxFileBytes: 4_000)
        let store = DiagnosticsStore(folder: makeFolder(), retention: retention)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<6 {
            let when = start.addingTimeInterval(Double(index))
            _ = try store.save(record(at: when, frames: 25), now: when)
        }
        let total = files(in: store.folder).reduce(0) { $0 + size(of: store.folder.appendingPathComponent($1)) }
        #expect(total <= 6_000)
        let kept = store.entries()
        #expect(!kept.isEmpty)
        #expect(kept.count < 6)
        #expect(kept.first?.record?.receivedAt == start.addingTimeInterval(5))
    }

    @Test func foreignFilesInTheFolderAreNeverDeleted() throws {
        let folder = makeFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let foreign = folder.appendingPathComponent("notes-from-the-user.txt")
        try Data("keep me".utf8).write(to: foreign)
        let retention = DiagnosticsRetention(maxFiles: 1, maxAge: 1, maxTotalBytes: 10, maxFileBytes: 10_000)
        let store = DiagnosticsStore(folder: folder, retention: retention)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<3 {
            let when = start.addingTimeInterval(Double(index) * 10)
            _ = try store.save(record(at: when), now: when)
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(store.entries().count <= 1)
    }
}
