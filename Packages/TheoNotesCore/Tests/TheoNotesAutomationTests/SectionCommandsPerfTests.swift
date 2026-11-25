// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Timing gates of `outline` and `search-in` on one large note (ruling R29: strict only in the
/// serial perf pass). The plan gives no gate for them; 200 ms on a 500 KB note with 2,000 headings
/// is the controller's choice (Task 5 fix round 1).
@Suite(.tags(.perf), PerfGate.onlyInPerfPass) struct SectionCommandsPerfTests {
    /// About 500 KB: 20 `#` parts of 99 `##` sections each (2,000 headings). The `##` names repeat
    /// across parts, so most addresses need an ancestor.
    private static func largeNote() throws -> TestLibrary {
        let vocabulary = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do"]
        var state: UInt64 = 42
        func word() -> String {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return vocabulary[Int((state >> 33) % UInt64(vocabulary.count))]
        }
        var text = ""
        for part in 0..<20 {
            text += "# Part \(part)\n"
            for section in 0..<99 {
                text += "## Section \(section)\n"
                for _ in 0..<4 { text += (0..<10).map { _ in word() }.joined(separator: " ") + "\n" }
            }
        }
        #expect(text.utf8.count > 450_000 && text.utf8.count < 550_000)
        return try TestLibrary.make([TestNote(text: text)])
    }

    /// The best of three runs, in milliseconds, and the last output.
    private func best(_ lib: TestLibrary, _ args: [String]) -> (ms: Double, result: CLIResult) {
        var best = Double.infinity
        var last = CLIResult(exit: -1, out: "", outData: Data(), err: "")
        for _ in 0..<3 {
            let start = ContinuousClock.now
            last = runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        return (best, last)
    }

    @Test func testPerfOutlineJSON500KB() throws {
        let lib = try Self.largeNote()
        let run = best(lib, ["outline", try lib.firstId(), "--format", "json"])
        print(String(format: "[perf] baerchen outline --format json, 500 KB / 2,000 headings: %.1f ms", run.ms))
        let rows = try run.result.json().array?.count ?? 0
        #expect(run.result.exit == 0 && rows == 2_000)
        #expect(run.ms < 200)
    }

    @Test func testPerfSearchInJSON500KB() throws {
        let lib = try Self.largeNote()
        let run = best(lib, ["search-in", try lib.firstId(), "--string", "lorem", "--format", "json"])
        print(String(format: "[perf] baerchen search-in --string lorem --format json, 500 KB: %.1f ms", run.ms))
        let hits = try run.result.json().array?.count ?? 0
        #expect(run.result.exit == 0 && hits > 1_000)
        #expect(run.ms < 200)
    }
}
