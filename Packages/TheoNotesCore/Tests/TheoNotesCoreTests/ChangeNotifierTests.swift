// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ChangeNotifierTests {
    final class Counter: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        func fire() { sem.signal() }
        func wait(seconds: Double) -> Bool { sem.wait(timeout: .now() + seconds) == .success }
    }

    @Test func testPostIsDelivered() async throws {
        let notifier = ChangeNotifier()
        let counter = Counter()
        let token = notifier.observe { counter.fire() }
        notifier.post()
        let delivered = await Task.detached { counter.wait(seconds: 2) }.value
        #expect(delivered)
        token.cancel()
    }

    @Test func testCancelledObserverIsNotCalled() async throws {
        let notifier = ChangeNotifier()
        let counter = Counter()
        let token = notifier.observe { counter.fire() }
        token.cancel()
        notifier.post()
        let delivered = await Task.detached { counter.wait(seconds: 0.5) }.value
        #expect(!delivered)
    }
}
