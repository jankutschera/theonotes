// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

/// Error classification and retry timing. Timing comes from the existing `SyncRetrySchedule`.
@Suite struct CloudErrorPolicyTests {
    private static let fixed = Date(timeIntervalSince1970: 1_000_000)

    private func policy(jitter: Double = 1) -> CloudErrorPolicy {
        CloudErrorPolicy(now: { Self.fixed }, jitter: { jitter })
    }

    // MARK: classification

    @Test func everyGatewayErrorHasAClass() {
        #expect(CloudErrorPolicy.classify(CloudSyncError.quotaExceeded) == .quotaFull)
        #expect(CloudErrorPolicy.classify(CloudSyncError.offline) == .offline)
        #expect(CloudErrorPolicy.classify(CloudSyncError.unauthenticated) == .unauthenticated)
        #expect(CloudErrorPolicy.classify(CloudSyncError.unauthenticated, account: .restricted) == .restricted)
        #expect(CloudErrorPolicy.classify(CloudSyncError.unauthenticated, account: .noAccount) == .signedOut)
        #expect(CloudErrorPolicy.classify(CloudSyncError.unauthenticated, account: .available(userHash: "A")) == .unauthenticated)
        #expect(CloudErrorPolicy.classify(CloudSyncError.zoneNotFound) == .zoneRemoved(.deleted))
        #expect(CloudErrorPolicy.classify(CloudSyncError.fenced) == .fenced)
        #expect(CloudErrorPolicy.classify(CloudSyncError.limitExceeded) == .failed(kind: "limitExceeded"))
        #expect(CloudErrorPolicy.classify(CloudSyncError.failed(code: "boom")) == .failed(kind: "boom"))
    }

    @Test func receiverProblemsAreClassifiedByTheirMeaning() {
        #expect(CloudErrorPolicy.classify(CloudPolicyError.unsupportedRecordVersion) == .needsAppUpdate)
        #expect(CloudErrorPolicy.classify(CloudRecordRejection.unsupported(.version(2))) == .needsAppUpdate)
        #expect(CloudErrorPolicy.classify(CloudPolicyError.corruptAttachment) == .itemsUnreadable(count: 1))
        #expect(CloudErrorPolicy.classify(CloudPolicyError.quarantined(count: 3)) == .itemsUnreadable(count: 3))
        #expect(CloudErrorPolicy.classify(CloudPolicyError.quarantined(count: 0)) == .itemsUnreadable(count: 1))
        #expect(CloudErrorPolicy.classify(CloudRecordRejection.unsupported(.missingField("cipher"))) == .itemsUnreadable(count: 1))
        #expect(CloudErrorPolicy.classify(CloudRecordRejection.unsupported(.nameMismatch)) == .itemsUnreadable(count: 1))
    }

    @Test func networkErrorsAreOfflineAndAnythingElseFails() {
        #expect(CloudErrorPolicy.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(CloudErrorPolicy.classify(URLError(.timedOut)) == .offline)
        #expect(CloudErrorPolicy.classify(URLError(.badURL)) == .failed(kind: "network"))
        guard case .failed = CloudErrorPolicy.classify(CrashInjected(boundary: "x")) else { Issue.record("expected failed"); return }
    }

    @Test func aSendOutcomeIsClassifiedLikeTheErrorItStandsFor() {
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.saved(systemFields: Data())) == nil)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.unknownItem) == nil)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.serverRecordChanged(server: entity("n1"))) == nil)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.quotaExceeded) == .quotaFull)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.offline) == .offline)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.unauthenticated, account: .restricted) == .restricted)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.zoneNotFound) == .zoneRemoved(.deleted))
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.fenced) == .fenced)
        #expect(CloudErrorPolicy.classify(CloudSaveOutcome.failed(code: "c")) == .failed(kind: "c"))
        #expect(CloudErrorPolicy.classify(CloudGatewayEvent.remoteChange) == nil)
        #expect(CloudErrorPolicy.classify(CloudGatewayEvent.accountChanged(.noAccount)) == nil)
    }

    // MARK: decisions

    @Test func quotaFullBlocksUploadsOnly() async throws {
        let w = try await CloudPolicyWorld.make()
        // a second device of the same person wrote a note before the storage ran out
        let other = FakeCloudKitDevice(account: w.one, store: InMemoryCloudGatewayStore())
        _ = try await other.prepare()
        try await other.submit([CloudSave(attemptId: "b1", accountGeneration: 1, record: entity("from-b"))])
        await w.device.setQuota(bytes: 1)

        try await w.device.submit([CloudSave(attemptId: "a1", accountGeneration: try w.store.generation(), record: entity("from-a"))])
        let outcome = try #require(try w.store.sendResult(attemptId: "a1")).outcome
        #expect(outcome == .quotaExceeded)
        #expect(await w.one.recordNames == ["e.note.from-b"], "the upload was refused")

        let sink = RecordingSink()
        try await w.device.fetchChanges(into: sink)
        #expect(sink.changedNames == ["e.note.from-b"], "receiving continues while uploads are blocked")

        var errors = policy()
        let maybe = errors.decide(outcome)
        let decision = try #require(maybe)
        #expect(decision.state == .quotaFull)
        #expect(decision.uploadsBlocked && !decision.receivingBlocked)
        #expect(decision.retry == .onForegroundOrEvery(6 * 3600))
        #expect(errors.consecutiveFailures == 0, "a full account is not a backoff failure")
        // blocked states block; none of the non-quota failures blocks receiving
        for kind in [CloudErrorClass.offline, .unauthenticated, .needsAppUpdate, .itemsUnreadable(count: 2), .failed(kind: "x")] {
            var each = policy()
            let d = each.decide(kind)
            #expect(!d.receivingBlocked && !d.uploadsBlocked, "\(kind)")
        }
    }

    @Test func offlineRetriesWithBackoffAndNeverSpins() async throws {
        let w = try await CloudPolicyWorld.make()
        var errors = policy()
        var delays: [TimeInterval] = []
        for _ in 0..<14 {
            await w.device.failNext(.offline)
            do { try await w.device.fetchChanges(into: RecordingSink()); Issue.record("expected the fetch to fail") }
            catch {
                let decision = errors.decide(error)
                guard case .after(let delay) = decision.retry else { Issue.record("expected a backoff, got \(decision.retry)"); return }
                #expect(decision.state == .offline(retryAt: Self.fixed.addingTimeInterval(delay)))
                #expect(!decision.uploadsBlocked && !decision.receivingBlocked)
                delays.append(delay)
            }
        }
        #expect(Array(delays.prefix(8)) == [2, 4, 8, 16, 32, 64, 128, 256])
        #expect(delays.dropFirst(8).allSatisfy { $0 == 300 }, "capped at five minutes")
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })

        errors.succeeded()
        #expect(errors.decide(CloudSyncError.offline).retry == .after(2), "success resets the backoff")
    }

    @Test func jitterKeepsTheDelayInsideTheSchedule() {
        for jitter in [0.8, 1.0, 1.2] {
            var errors = policy(jitter: jitter)
            for _ in 0..<12 {
                guard case .after(let delay) = errors.decide(CloudSyncError.offline).retry else { Issue.record("no backoff"); return }
                #expect(delay >= 1.6 && delay <= 360)
            }
        }
        var random = CloudErrorPolicy()      // the production jitter
        for _ in 0..<20 {
            guard case .after(let delay) = random.decide(CloudSyncError.offline).retry else { Issue.record("no backoff"); return }
            #expect(delay >= 1.6 && delay <= 360)
        }
    }

    @Test func unauthenticatedBacksOffAndWaitsForICloud() {
        var errors = policy()
        let first = errors.decide(CloudSyncError.unauthenticated)
        #expect(first.state == .waitingForICloud && first.retry == .after(2))
        #expect(errors.decide(CloudSyncError.unauthenticated).retry == .after(4))
    }

    @Test func restrictedAndSignedOutDoNotRetryByThemselves() {
        var errors = policy()
        let restricted = errors.decide(CloudSyncError.unauthenticated, account: .restricted)
        let signedOut = errors.decide(CloudSyncError.unauthenticated, account: .noAccount)
        #expect(restricted.state == .restricted && restricted.retry == .none && restricted.uploadsBlocked && restricted.receivingBlocked)
        #expect(signedOut.state == .signedOutOfICloud && signedOut.retry == .none)
        #expect(restricted.state.message != signedOut.state.message)
        #expect(errors.consecutiveFailures == 0, "waiting for an account event is not a failure to back off from")
    }

    @Test func aNewerAppVersionAndUnreadableItemsDoNotRetryByThemselves() {
        var errors = policy()
        #expect(errors.decide(CloudPolicyError.unsupportedRecordVersion) == CloudErrorDecision(
            state: .needsAppUpdate, retry: .none, uploadsBlocked: false, receivingBlocked: false))
        #expect(errors.decide(CloudPolicyError.quarantined(count: 2)).state == .itemsUnreadable(count: 2))
        #expect(errors.decide(CloudPolicyError.corruptAttachment).retry == .none)
    }

    @Test func aFencedGatewayPausesWithoutRetry() {
        var errors = policy()
        let decision = errors.decide(CloudSyncError.fenced)
        #expect(decision.state == .paused && decision.retry == .none && decision.uploadsBlocked && decision.receivingBlocked)
    }

    @Test func anythingElseFailsWithBackoffAndTheMessageHidesTheKind() {
        var errors = policy()
        let decision = errors.decide(CloudSyncError.failed(code: "CKErrorDomain 12"))
        #expect(decision.state == .failed(kind: "CKErrorDomain 12"))
        #expect(decision.retry == .after(2))
        #expect(!decision.state.message.contains("CKErrorDomain"))
    }
}
