// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import MetricKit

/// The MetricKit side of crash and hang diagnostics (REL-R44). MetricKit hands the app reports the system
/// collected about earlier runs; this file turns them into `DiagnosticsRecord`s and nothing else happens here:
/// no network, no file access. Only fields that are numbers, system identifiers or binary names are read, never
/// an exception message (`composedMessage`, `formatString`, `arguments`), signpost data or reported state.
///
/// macOS 27 and later use `MetricManager` and `DiagnosticReport`; macOS 26 uses `MXMetricManager` and
/// `MXDiagnosticPayload`, which exist since macOS 12. The file only uses symbols that also exist on iOS, so the
/// iOS target can compile it as it is (REL-R48); iOS-only report types (`appLaunch`, `memoryException`) fall under
/// `.other` until the iOS agent maps them.
struct MetricKitDiagnosticsSource: DiagnosticsSource {
    func reports() -> AsyncStream<[DiagnosticsRecord]> {
        if #available(macOS 27, iOS 27, *) { return Self.modernReports() }
        return Self.legacyReports()
    }

    // MARK: macOS 27 / iOS 27

    @available(macOS 27, iOS 27, *)
    private static func modernReports() -> AsyncStream<[DiagnosticsRecord]> {
        AsyncStream { continuation in
            let manager = MetricManager()
            let task = Task {
                for await report in manager.diagnosticReports {
                    continuation.yield([record(from: report, receivedAt: Date())])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @available(macOS 27, iOS 27, *)
    static func record(from report: DiagnosticReport, receivedAt: Date) -> DiagnosticsRecord {
        var facts: [String: String] = [:]
        var kind = DiagnosticsRecord.Kind.other
        var tree: CallStackTree?
        switch report.result {
        case .crash(let crash):
            kind = .crash
            tree = crash.callStackTree
            facts["signal"] = crash.signal.map(String.init)
            facts["exceptionType"] = crash.exceptionType.map(String.init)
            facts["exceptionCode"] = crash.exceptionCode.map(String.init)
            facts["terminationCategory"] = crash.terminationCategory?.rawValue
            facts["terminationReason"] = crash.terminationReason?.rawValue
            facts["exceptionClass"] = crash.exceptionReason?.className
            facts["exceptionName"] = crash.exceptionReason?.exceptionName
        case .hang(let hang):
            kind = .hang
            tree = hang.callStackTree
            facts["hangSeconds"] = seconds(hang.hangDuration)
        case .cpuException(let cpu):
            kind = .cpuException
            tree = cpu.callStackTree
            facts["cpuSeconds"] = seconds(cpu.totalCPUTime)
            facts["sampledSeconds"] = seconds(cpu.totalSampledTime)
        case .diskWriteException(let disk):
            kind = .diskWriteException
            tree = disk.callStackTree
            facts["bytesWritten"] = String(Int64(disk.totalBytesWritten.converted(to: .bytes).value))
        default:
            break
        }
        let environment = report.environment
        return DiagnosticsRecord(
            kind: kind, receivedAt: receivedAt, periodStart: report.timeRange.start, periodEnd: report.timeRange.end,
            appVersion: environment.applicationVersion, appBuild: environment.applicationBuildVersion,
            osVersion: "\(environment.osVersion.platform) \(environment.osVersion.number) (\(environment.osVersion.buildNumber))",
            facts: facts.compactMapValues { $0 }, stacks: tree.map { stacks(of: $0) } ?? [])
    }

    @available(macOS 27, iOS 27, *)
    private static func stacks(of tree: CallStackTree) -> [DiagnosticsRecord.CallStack] {
        var budget = DiagnosticsRecord.maxFramesPerReport
        return tree.callStackThreads.prefix(DiagnosticsRecord.maxStacks).map { thread in
            var frames: [DiagnosticsRecord.Frame] = []
            var pending = thread.rootFrames.reversed().map { ($0, 0) }
            while let (frame, depth) = pending.popLast(), budget > 0 {
                budget -= 1
                frames.append(DiagnosticsRecord.Frame(
                    depth: depth, binaryName: frame.binaryName(from: tree), binaryUUID: frame.binaryUUID?.uuidString,
                    offset: frame.offsetIntoBinaryTextSegment, address: frame.address, samples: frame.sampleCount))
                pending.append(contentsOf: frame.subFrames.reversed().map { ($0, depth + 1) })
            }
            return DiagnosticsRecord.CallStack(attributed: thread.threadAttributed ?? false, frames: frames)
        }
    }

    private static func seconds(_ duration: Measurement<UnitDuration>) -> String {
        String(format: "%.3f", duration.converted(to: .seconds).value)
    }

    // MARK: macOS 26 / iOS 26

    private static func legacyReports() -> AsyncStream<[DiagnosticsRecord]> {
        AsyncStream { continuation in
            let subscriber = LegacySubscriber(continuation: continuation)
            MXMetricManager.shared.add(subscriber)
            continuation.onTermination = { _ in MXMetricManager.shared.remove(subscriber) }
        }
    }

    private final class LegacySubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
        let continuation: AsyncStream<[DiagnosticsRecord]>.Continuation

        init(continuation: AsyncStream<[DiagnosticsRecord]>.Continuation) {
            self.continuation = continuation
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            let received = Date()
            let records = payloads.flatMap { MetricKitDiagnosticsSource.records(from: $0, receivedAt: received) }
            if !records.isEmpty { continuation.yield(records) }
        }
    }

    static func records(from payload: MXDiagnosticPayload, receivedAt: Date) -> [DiagnosticsRecord] {
        func record(
            _ kind: DiagnosticsRecord.Kind, _ diagnostic: MXDiagnostic, _ tree: MXCallStackTree, _ facts: [String: String?]
        ) -> DiagnosticsRecord {
            DiagnosticsRecord(
                kind: kind, receivedAt: receivedAt, periodStart: payload.timeStampBegin, periodEnd: payload.timeStampEnd,
                appVersion: diagnostic.applicationVersion, appBuild: diagnostic.metaData.applicationBuildVersion,
                osVersion: diagnostic.metaData.osVersion, facts: facts.compactMapValues { $0 },
                stacks: DiagnosticsRecord.CallStack.parse(callStackJSON: tree.jsonRepresentation()))
        }
        var records: [DiagnosticsRecord] = []
        for crash in payload.crashDiagnostics ?? [] {
            records.append(record(.crash, crash, crash.callStackTree, [
                "signal": crash.signal.map { String($0.intValue) },
                "exceptionType": crash.exceptionType.map { String($0.intValue) },
                "exceptionCode": crash.exceptionCode.map { String($0.uint64Value) },
                "terminationReason": crash.terminationReason,
                "exceptionClass": crash.exceptionReason?.className,
                "exceptionName": crash.exceptionReason?.exceptionName,
            ]))
        }
        for hang in payload.hangDiagnostics ?? [] {
            records.append(record(.hang, hang, hang.callStackTree, ["hangSeconds": seconds(hang.hangDuration)]))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            records.append(record(.cpuException, cpu, cpu.callStackTree, [
                "cpuSeconds": seconds(cpu.totalCPUTime), "sampledSeconds": seconds(cpu.totalSampledTime),
            ]))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            records.append(record(.diskWriteException, disk, disk.callStackTree, [
                "bytesWritten": String(Int64(disk.totalWritesCaused.converted(to: .bytes).value))
            ]))
        }
        return records
    }
}
