// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@MainActor @Suite struct WebAuthenticationCallbackTests {
    private enum FixtureError: Error { case rejected }

    private func callbackFromBackground(url: URL?, error: (any Error)?) async -> Result<URL, any Error> {
        await withCheckedContinuation { continuation in
            // Created on MainActor just like the two application adapters, but entered
            // off actor just like AuthenticationServices' Safari XPC completion.
            let handler = WebAuthenticationCallback.makeHandler { result in
                MainActor.preconditionIsolated()
                continuation.resume(returning: result)
            }
            DispatchQueue.global().async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                handler(url, error)
            }
        }
    }

    @Test func successfulBackgroundCallbackArrivesOnMainActor() async throws {
        let url = try #require(URL(string: "baerchen://sync-auth?code=test&flow=test"))
        let result = await callbackFromBackground(url: url, error: nil)
        #expect(try result.get() == url)
    }

    @Test func backgroundErrorTakesPrecedenceOverCallbackURL() async throws {
        let result = await callbackFromBackground(url: URL(string: "baerchen://sync-auth"), error: FixtureError.rejected)
        guard case .failure(let error) = result else { Issue.record("Expected callback failure"); return }
        #expect(error is FixtureError)
    }

    @Test func emptyBackgroundCallbackBecomesUserCancellation() async {
        let result = await callbackFromBackground(url: nil, error: nil)
        guard case .failure(let error) = result else { Issue.record("Expected cancellation"); return }
        #expect((error as? CocoaError)?.code == .userCancelled)
    }

    @Test func explicitBackgroundCancellationIsPreserved() async {
        let result = await callbackFromBackground(url: nil, error: CancellationError())
        guard case .failure(let error) = result else { Issue.record("Expected cancellation"); return }
        #expect(error is CancellationError)
    }
}
