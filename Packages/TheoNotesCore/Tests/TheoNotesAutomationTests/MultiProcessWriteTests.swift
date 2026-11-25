// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// The `theonotes` executable this test run built (`.build/<config>/theonotes`, beside the test bundle).
enum BuiltProducts {
    static var theonotes: URL {
        let testBundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        if let dir = testBundle?.bundleURL.deletingLastPathComponent() {
            let beside = dir.appendingPathComponent("theonotes")
            if FileManager.default.isExecutableFile(atPath: beside.path) { return beside }
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        for config in ["debug", "release"] {
            let url = root.appendingPathComponent(".build/\(config)/theonotes")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return root.appendingPathComponent(".build/debug/theonotes")
    }
}

/// Runs the built binary as its own process (`environment` is added to this process's).
func runBinary(_ args: [String], environment: [String: String] = [:]) throws -> CLIResult {
    let process = Process()
    process.executableURL = BuiltProducts.theonotes
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Drain stderr on another thread so neither pipe can fill up and stall the child.
    nonisolated(unsafe) var errData = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    drained.wait()
    process.waitUntilExit()
    return CLIResult(
        exit: process.terminationStatus, out: String(decoding: outData, as: UTF8.self), outData: outData,
        err: String(decoding: errData, as: UTF8.self))
}

extension Sequence where Element: Sendable {
    /// `transform` for every element at the same time, each on its own GCD thread (a blocking child
    /// process must not hold a cooperative-pool thread); results in element order.
    func concurrentMap<T: Sendable>(_ transform: @escaping @Sendable (Element) throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in enumerated() {
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global().async {
                            continuation.resume(with: Result { (index, try transform(element)) })
                        }
                    }
                }
            }
            var results: [(Int, T)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// Several `baerchen` processes writing one library at once (M5 Task 16): no write is lost, none
/// reports `busy`.
@Suite struct MultiProcessWriteTests {
    @Test func theBuiltBinaryIsThere() {
        #expect(FileManager.default.isExecutableFile(atPath: BuiltProducts.theonotes.path), "\(BuiltProducts.theonotes.path)")
    }

    @Test func concurrentProcessesNeverLoseAppends() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# T")])
        let id = try lib.firstId()
        let root = lib.paths.root.path
        let results = try await (0..<6).concurrentMap { p in
            try runBinary(["--data-dir", root, "append", id, "--content", (0..<10).map { "p\(p)-\($0)" }.joined(separator: "\n")])
        }
        #expect(results.allSatisfy { $0.exit == 0 }, "\(results.map(\.err))")
        let lines = try lib.text(id).split(separator: "\n").filter { $0.hasPrefix("p") }
        #expect(Set(lines).count == 60)
        #expect(lines.count == 60)
    }

    /// Read-modify-write from 4 processes: even ones compare-and-swap with `edit --find "counter: N"`,
    /// odd ones with `overwrite --base <hash>`; a lost race (`not_found` / `stale_hash`) re-reads and
    /// tries again. Every process lands exactly one increment.
    @Test func concurrentEditsAreSerializedNotLost() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\ncounter: 0")])
        let id = try lib.firstId()
        let root = lib.paths.root.path
        let attempts = try await (0..<4).concurrentMap { p -> Int in
            for attempt in 1...100 {
                let read = try runBinary(["--data-dir", root, "cat", id, "--format", "json"])
                guard read.exit == 0 else { throw NotACommand(description: "cat failed: \(read.err)") }
                let json = try read.json()
                let text = try #require(json["content"]?.string)
                let hash = try #require(json["hash"]?.string)
                let n = try #require(text.split(separator: "\n").last.flatMap { Int($0.dropFirst("counter: ".count)) })
                let write = p.isMultiple(of: 2)
                    ? try runBinary(["--data-dir", root, "edit", id, "--find", "counter: \(n)", "--replace", "counter: \(n + 1)"])
                    : try runBinary(["--data-dir", root, "overwrite", id, "--base", hash, "--content", "# T\ncounter: \(n + 1)"])
                if write.exit == 0 { return attempt }
                let lostRace = write.err.contains("No match for") || write.err.contains("changed since it was read")
                guard lostRace else { throw NotACommand(description: "process \(p): \(write.err)") }
            }
            throw NotACommand(description: "process \(p) never got its increment in")
        }
        #expect(attempts.count == 4)
        #expect(try lib.text(id) == "# T\ncounter: 4")
    }

    /// 8 processes, each adding and removing its own tags 20 times: every command succeeds (no
    /// `busy`: neither SQLITE_BUSY nor "The note kept changing"), and only the tags left added remain.
    @Test func writerNeverSeesSQLiteBusy() async throws {
        let lib = try TestLibrary.make([TestNote(text: "# T\nbody")])
        let id = try lib.firstId()
        let root = lib.paths.root.path
        let failures = try await (0..<8).concurrentMap { p -> [String] in
            var failures: [String] = []
            for i in 0..<20 {
                let tag = "w\(p)/t\(i / 2)"
                let r = try runBinary(["--data-dir", root, "tags", i.isMultiple(of: 2) ? "add" : "remove", id, tag])
                if r.exit != 0 { failures.append("p\(p) #\(i): exit \(r.exit) \(r.err)") }
            }
            // One tag per process stays, so the final text shows every process's last write.
            let r = try runBinary(["--data-dir", root, "tags", "add", id, "kept\(p)"])
            if r.exit != 0 { failures.append("p\(p) kept: exit \(r.exit) \(r.err)") }
            return failures
        }
        #expect(failures.flatMap { $0 }.isEmpty, "\(failures.flatMap { $0 })")
        let tags = Set(NoteParser.metadata(for: try lib.text(id)).tags)
        #expect(tags == Set((0..<8).map { "kept\($0)" }))
    }
}
