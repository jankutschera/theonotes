// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation
import Testing
@testable import TheoNotesCore

/// Hand-built `CKError`s: the mapping needs no container.
@Suite struct CloudKitErrorMappingTests {
    private func error(_ code: CKError.Code, _ userInfo: [String: Any] = [:]) -> CKError {
        CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo))
    }

    private func outcome(_ code: CKError.Code, _ userInfo: [String: Any] = [:]) -> CloudSaveOutcome {
        CloudKitErrorMapping.outcome(for: error(code, userInfo)) { _ in CloudRecord(name: "x", type: .entity, fields: [:]) }
    }

    @Test func serverRecordChangedCarriesTheServerRecordFromUserInfo() throws {
        let zone = CKRecordZone.ID(zoneName: "Z", ownerName: CKCurrentUserDefaultName)
        let server = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.a", zoneID: zone))
        server["v"] = Int64(1)
        let zones = CloudZones(main: zone, blob: CKRecordZone.ID(zoneName: "ZBlobs", ownerName: CKCurrentUserDefaultName))
        let result = CloudKitErrorMapping.outcome(for: error(.serverRecordChanged, [CKRecordChangedErrorServerRecordKey: server])) {
            try #require(CloudRecordMapping.makeCloudRecord(from: $0))
        }
        guard case .serverRecordChanged(let mapped) = result else { Issue.record("got \(result)"); return }
        #expect(mapped.name == "e.note.a" && mapped.fields["v"] == .int(1))
        _ = zones
    }

    @Test func serverRecordChangedWithoutARecordIsAFailureNotACrash() {
        #expect(outcome(.serverRecordChanged) == .failed(code: "serverRecordChangedWithoutRecord"))
    }

    @Test func aConflictAssetThatCannotBeKeptBecomesAFailure() {
        let zone = CKRecordZone.ID(zoneName: "Z", ownerName: CKCurrentUserDefaultName)
        let server = CKRecord(recordType: "Entity", recordID: CKRecord.ID(recordName: "e.note.a", zoneID: zone))
        let result = CloudKitErrorMapping.outcome(for: error(.serverRecordChanged, [CKRecordChangedErrorServerRecordKey: server])) { _ in
            throw CloudSyncError.failed(code: "assetNotAvailable")
        }
        #expect(result == .failed(code: "conflictAssetUnavailable"))
    }

    @Test func perRecordOutcomes() {
        #expect(outcome(.unknownItem) == .unknownItem)
        #expect(outcome(.quotaExceeded) == .quotaExceeded)
        #expect(outcome(.limitExceeded) == .limitExceeded)
        #expect(outcome(.zoneNotFound) == .zoneNotFound)
        #expect(outcome(.userDeletedZone) == .zoneNotFound)
        #expect(outcome(.notAuthenticated) == .unauthenticated)
        #expect(outcome(.networkUnavailable) == .offline)
        #expect(outcome(.networkFailure) == .offline)
        #expect(outcome(.requestRateLimited) == .offline)
        #expect(outcome(.zoneBusy) == .offline)
        #expect(outcome(.serviceUnavailable) == .offline)
        #expect(outcome(.invalidArguments) == .failed(code: "invalidArguments"))
        #expect(outcome(.assetFileNotFound) == .failed(code: "assetFileNotFound"))
        #expect(outcome(.batchRequestFailed) == .failed(code: "batchRequestFailed"))
    }

    @Test func operationErrorsMapToTheGatewaysVocabulary() {
        #expect(CloudKitErrorMapping.syncError(for: error(.networkUnavailable)) == .offline)
        #expect(CloudKitErrorMapping.syncError(for: error(.notAuthenticated)) == .unauthenticated)
        #expect(CloudKitErrorMapping.syncError(for: error(.quotaExceeded)) == .quotaExceeded)
        #expect(CloudKitErrorMapping.syncError(for: error(.limitExceeded)) == .limitExceeded)
        #expect(CloudKitErrorMapping.syncError(for: error(.zoneNotFound)) == .zoneNotFound)
        #expect(CloudKitErrorMapping.syncError(for: error(.userDeletedZone)) == .zoneNotFound)
        #expect(CloudKitErrorMapping.syncError(for: CloudSyncError.fenced) == .fenced)
        #expect(CloudKitErrorMapping.syncError(for: error(.permissionFailure)) == .unauthenticated)
        if case .failed(let code) = CloudKitErrorMapping.syncError(for: NSError(domain: "x", code: 3)) { #expect(code == "error:x:3") }
        else { Issue.record("a foreign error must become failed") }
    }

    @Test func aPartialFailureReportsTheErrorThatMatters() {
        let zone = CKRecordZone.ID(zoneName: "Z", ownerName: CKCurrentUserDefaultName)
        let a = CKRecord.ID(recordName: "a", zoneID: zone), b = CKRecord.ID(recordName: "b", zoneID: zone), c = CKRecord.ID(recordName: "c", zoneID: zone)
        let partial = error(.partialFailure, [CKPartialErrorsByItemIDKey: [a: error(.batchRequestFailed), b: error(.quotaExceeded), c: error(.unknownItem)]])
        #expect(CloudKitErrorMapping.syncError(for: partial) == .quotaExceeded)
    }

    @Test func rateLimitHonoursTheRetryAfterKey() {
        #expect(CloudKitErrorMapping.retryAfter(error(.requestRateLimited, [CKErrorRetryAfterKey: 7.5])) == 7.5)
        #expect(CloudKitErrorMapping.retryAfter(error(.networkUnavailable)) == nil)
        #expect(CloudKitErrorMapping.retryAfter(NSError(domain: "x", code: 1)) == nil)
    }

    @Test func changeTokenExpiredIsRecognisedAndUserDeletedZoneIsAZoneRemoval() {
        #expect(CloudKitErrorMapping.isChangeTokenExpired(error(.changeTokenExpired)))
        #expect(!CloudKitErrorMapping.isChangeTokenExpired(error(.networkFailure)))
        #expect(CloudKitErrorMapping.zoneRemoval(for: error(.userDeletedZone)) == .userDeletedZone)
        #expect(CloudKitErrorMapping.zoneRemoval(for: error(.zoneNotFound)) == .deleted)
        #expect(CloudKitErrorMapping.zoneRemoval(for: error(.quotaExceeded)) == nil)
    }

    @Test func zoneDeletionReasonsMapOneToOne() {
        #expect(CloudKitErrorMapping.removal(for: .deleted) == .deleted)
        #expect(CloudKitErrorMapping.removal(for: .purged) == .purged)
        #expect(CloudKitErrorMapping.removal(for: .encryptedDataReset) == .encryptedDataReset)
    }

    @Test func transientCodesAreTheOnesTheEngineRetries() {
        for code: CKError.Code in [.networkUnavailable, .networkFailure, .zoneBusy, .serviceUnavailable, .requestRateLimited, .accountTemporarilyUnavailable] {
            #expect(CloudKitErrorMapping.isTransient(code))
        }
        for code: CKError.Code in [.quotaExceeded, .unknownItem, .serverRecordChanged, .notAuthenticated, .zoneNotFound] {
            #expect(!CloudKitErrorMapping.isTransient(code))
        }
    }
}
