// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// REL-R42/R44: the older MetricKit API hands over a call stack tree as JSON; only its frame facts are taken.
@Suite struct DiagnosticsCallStackJSONTests {
    private let json = """
        {"callStackPerThread": true,
         "callStacks": [
           {"threadAttributed": true,
            "callStackRootFrames": [
              {"binaryUUID": "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment": 100,
               "sampleCount": 1, "binaryName": "Theo Notes", "address": 4294967396,
               "note": "CANARY-from-a-note",
               "subFrames": [
                 {"binaryUUID": "66666666-7777-8888-9999-000000000000", "offsetIntoBinaryTextSegment": 7,
                  "sampleCount": 1, "binaryName": "AppKit", "address": 99, "subFrames": []}
               ]}]},
           {"threadAttributed": false, "callStackRootFrames": []}
         ]}
        """

    @Test func framesAreFlattenedDepthFirstWithTheirDepth() {
        let stacks = DiagnosticsRecord.CallStack.parse(callStackJSON: Data(json.utf8))
        #expect(stacks.count == 2)
        #expect(stacks[0].attributed)
        #expect(!stacks[1].attributed)
        #expect(stacks[0].frames.map(\.binaryName) == ["Theo Notes", "AppKit"])
        #expect(stacks[0].frames.map(\.depth) == [0, 1])
        #expect(stacks[0].frames[0].offset == 100)
        #expect(stacks[0].frames[0].address == 4_294_967_396)
        #expect(stacks[0].frames[0].binaryUUID == "11111111-2222-3333-4444-555555555555")
    }

    @Test func unknownKeysAreNotCarriedAlong() throws {
        let stacks = DiagnosticsRecord.CallStack.parse(callStackJSON: Data(json.utf8))
        let encoded = try String(data: JSONEncoder().encode(stacks), encoding: .utf8) ?? ""
        #expect(!encoded.contains("CANARY"))
    }

    @Test func garbageGivesNoStacksInsteadOfAFailure() {
        #expect(DiagnosticsRecord.CallStack.parse(callStackJSON: Data("not json".utf8)).isEmpty)
        #expect(DiagnosticsRecord.CallStack.parse(callStackJSON: Data("[1,2]".utf8)).isEmpty)
        #expect(DiagnosticsRecord.CallStack.parse(callStackJSON: Data()).isEmpty)
    }

    @Test func aDeepTreeIsFlattenedWithinTheFrameBound() {
        var tree = "{\"binaryName\":\"X\",\"subFrames\":[]}"
        for _ in 0..<150 { tree = "{\"binaryName\":\"X\",\"subFrames\":[\(tree)]}" }
        let data = Data("{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[\(tree)]}]}".utf8)
        let stacks = DiagnosticsRecord.CallStack.parse(callStackJSON: data)
        let frames = stacks.first?.frames.count ?? 0
        #expect(frames > 0)
        #expect(frames <= DiagnosticsRecord.maxFramesPerReport)
    }
}
