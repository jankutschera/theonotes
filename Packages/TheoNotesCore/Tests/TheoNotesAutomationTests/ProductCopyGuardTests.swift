// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing

/// and the positioning rule of the focus layer: no user-facing string names a condition.
/// `scripts/copy-guard.py` does the scan; `scripts/test-all.sh` runs it as well.
@Suite struct ProductCopyGuardTests {
    private static func guardRun(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
        try HelpTests.run(
            "/usr/bin/env", ["python3", "-I", MCPFixtures.root.appendingPathComponent("scripts/copy-guard.py").path] + arguments)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/env")))
    func noConditionWordInUserFacingCopy() throws {
        let (status, stderr) = try Self.guardRun([])
        #expect(status == 0, "reword the text named below, never the guard:\n\(stderr)")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/env")))
    func theGuardCatchesAPlantedWord() throws {
        let (status, stderr) = try Self.guardRun(["--self-test"])
        #expect(status == 0, "\(stderr)")
    }
}
