// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import BaerchenIOS

@Suite @MainActor struct MobileMediaOperationGateTests {
    @Test func beginClaimsOneOperationUntilMatchingFinish() throws {
        let gate = MobileMediaOperationGate()
        let first = try #require(gate.begin())
        #expect(gate.isCurrent(first))
        #expect(gate.begin() == nil)
        #expect(!gate.finish(UUID()))
        #expect(gate.isCurrent(first))
        #expect(gate.finish(first))
        #expect(!gate.isCurrent(first))
        #expect(!gate.finish(first))
        #expect(gate.begin() != nil)
    }

    @Test func lateCallbackCannotFinishReplacementOperation() throws {
        let gate = MobileMediaOperationGate()
        let first = try #require(gate.begin())
        let lateCompletion = { gate.finish(first) }
        gate.invalidate()
        let replacement = try #require(gate.begin())
        #expect(replacement != first)
        #expect(!gate.isCurrent(first))
        #expect(!lateCompletion())
        #expect(gate.isCurrent(replacement))
        #expect(gate.finish(replacement))
    }

    @Test func dismissalAfterSuccessfulCompletionCannotEndNextOperation() throws {
        let gate = MobileMediaOperationGate()
        let first = try #require(gate.begin())
        #expect(gate.finish(first))
        let next = try #require(gate.begin())
        #expect(!gate.finish(first))
        #expect(gate.isCurrent(next))
        #expect(gate.begin() == nil)
    }

    @Test func invalidationIsIdempotentAndReleasesCurrentOperation() throws {
        let gate = MobileMediaOperationGate()
        let first = try #require(gate.begin())
        gate.invalidate()
        gate.invalidate()
        #expect(!gate.isCurrent(first))
        #expect(!gate.finish(first))
        #expect(gate.begin() != nil)
    }
}
