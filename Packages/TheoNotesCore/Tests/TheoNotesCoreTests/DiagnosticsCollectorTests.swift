// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// The collector turns whatever a source hands over into stored files, with no framework in sight.
@Suite struct DiagnosticsCollectorTests {
    private struct FakeSource: DiagnosticsSource {
        let stream: AsyncStream<[DiagnosticsRecord]>
        func reports() -> AsyncStream<[DiagnosticsRecord]> { stream }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(_ kind: DiagnosticsRecord.Kind, offset: Double) -> DiagnosticsRecord {
        DiagnosticsRecord(
            kind: kind, receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), periodStart: nil, periodEnd: nil,
            appVersion: "1.0", appBuild: "1", osVersion: "macOS 27.0", facts: ["signal": "11"], stacks: [])
    }

    @Test func everyRecordASourceDeliversIsStoredAndTheRunEndsWithTheStream() async {
        let (stream, continuation) = AsyncStream<[DiagnosticsRecord]>.makeStream()
        let store = DiagnosticsStore(folder: folder())
        let collector = DiagnosticsCollector(store: store, source: FakeSource(stream: stream))
        continuation.yield([record(.crash, offset: 0), record(.hang, offset: 1)])
        continuation.yield([record(.cpuException, offset: 2)])
        continuation.finish()
        await collector.run()
        let kinds = store.entries().compactMap { $0.record?.kind }
        #expect(kinds == [.cpuException, .hang, .crash])
    }

    @Test func aFailingWriteIsReportedAndDoesNotStopTheRest() async throws {
        let (stream, continuation) = AsyncStream<[DiagnosticsRecord]>.makeStream()
        // The folder path sits below a file, so nothing can be created there.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)
        let broken = DiagnosticsStore(folder: blocker.appendingPathComponent("inside"))
        let failures = Counter()
        let collector = DiagnosticsCollector(store: broken, source: FakeSource(stream: stream)) { _ in failures.add() }
        continuation.yield([record(.crash, offset: 0), record(.hang, offset: 1)])
        continuation.finish()
        await collector.run()
        #expect(failures.count == 2)
    }

    @Test func aSourceWithNothingToSayWritesNothingAndCreatesNoFolder() async {
        let (stream, continuation) = AsyncStream<[DiagnosticsRecord]>.makeStream()
        let target = folder()
        let collector = DiagnosticsCollector(store: DiagnosticsStore(folder: target), source: FakeSource(stream: stream))
        continuation.finish()
        await collector.run()
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
