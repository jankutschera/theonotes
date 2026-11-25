// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

/// Ruling M5-R269: no sentence of eight words or more from the private research dumps (the reference
/// tool's help text and MCP descriptions) may appear in a shipping source. `scripts/ip-guard.py` does the
/// comparison; `scripts/test-all.sh` runs it as well.
@Suite struct CleanRoomGuardTests {
    private static func guardRun(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        try HelpTests.run(
            "/usr/bin/env", ["python3", "-I", MCPFixtures.root.appendingPathComponent("scripts/ip-guard.py").path] + arguments)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/env")))
    func noResearchSentenceShips() throws {
        let (status, stderr) = try Self.guardRun([])
        #expect(status == 0, "reword the text named below, never the guard:\n\(stderr)")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/env")))
    func theMatcherCatchesCopiesAndLetsRewritesThrough() throws {
        let (status, stderr) = try Self.guardRun(["--self-test"])
        #expect(status == 0, "\(stderr)")
    }
}
