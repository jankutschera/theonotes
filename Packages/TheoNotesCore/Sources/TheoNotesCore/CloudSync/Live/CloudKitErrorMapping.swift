// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import CloudKit
import Foundation

/// CloudKit errors -> the gateway's vocabulary. Pure functions over `CKError` so they are tested with
/// hand-built errors and need no container.
enum CloudKitErrorMapping {
    /// Codes after which the same request can simply be made again later. The engine retries some of them itself; the gateway
    /// reports them to its caller as `offline` so the publisher's backoff owns the retry.
    static func isTransient(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy, .accountTemporarilyUnavailable,
             .requestRateLimited, .operationCancelled, .serverResponseLost, .internalError:
            return true
        default:
            return false
        }
    }

    static func ckError(_ error: Error) -> CKError? {
        if let ck = error as? CKError { return ck }
        let ns = error as NSError
        return ns.domain == CKErrorDomain ? CKError(_nsError: ns) : nil
    }

    /// The outcome of one failed record save. `serverRecord` maps the record a `serverRecordChanged` carries; it may throw (an asset
    /// that could not be kept), which becomes `failed("conflictAssetUnavailable")` exactly like the fake.
    static func outcome(for error: CKError, serverRecord: (CKRecord) throws -> CloudRecord) -> CloudSaveOutcome {
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord else { return .failed(code: "serverRecordChangedWithoutRecord") }
            do { return .serverRecordChanged(server: try serverRecord(server)) } catch { return .failed(code: "conflictAssetUnavailable") }
        case .unknownItem: return .unknownItem
        case .quotaExceeded: return .quotaExceeded
        case .limitExceeded: return .limitExceeded
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .notAuthenticated, .managedAccountRestricted, .permissionFailure: return .unauthenticated
        default:
            return isTransient(error.code) ? .offline : .failed(code: codeName(error.code))
        }
    }

    /// An error thrown by a whole operation (not one record).
    static func syncError(for error: Error) -> CloudSyncError {
        if let known = error as? CloudSyncError { return known }
        guard let ck = ckError(error) else { return .failed(code: "error:\((error as NSError).domain):\((error as NSError).code)") }
        if ck.code == .partialFailure, let inner = significantPartialError(ck) { return syncError(for: inner) }
        switch ck.code {
        case .quotaExceeded: return .quotaExceeded
        case .limitExceeded: return .limitExceeded
        case .zoneNotFound, .userDeletedZone: return .zoneNotFound
        case .notAuthenticated, .managedAccountRestricted, .permissionFailure: return .unauthenticated
        default: return isTransient(ck.code) ? .offline : .failed(code: codeName(ck.code))
        }
    }

    /// The first underlying failure of a partial failure that is not just "the rest of the batch failed too".
    static func significantPartialError(_ error: CKError) -> CKError? {
        let inner = (error.partialErrorsByItemID ?? [:]).values.compactMap { ckError($0) }.filter { $0.code != .batchRequestFailed }
        let order: [CKError.Code] = [.quotaExceeded, .notAuthenticated, .zoneNotFound, .userDeletedZone, .limitExceeded]
        return order.lazy.compactMap { code in inner.first { $0.code == code } }.first ?? inner.first
    }

    /// Why the zone is gone, when this error says so.
    static func zoneRemoval(for error: Error) -> ZoneRemoval? {
        guard let ck = ckError(error) else { return nil }
        switch ck.code {
        case .userDeletedZone: return .userDeletedZone
        case .zoneNotFound: return .deleted
        default: return nil
        }
    }

    static func isChangeTokenExpired(_ error: Error) -> Bool { ckError(error)?.code == .changeTokenExpired }

    /// `CKErrorRetryAfterKey`, when the error carries one (`requestRateLimited`, `zoneBusy`).
    static func retryAfter(_ error: Error) -> TimeInterval? { ckError(error)?.retryAfterSeconds }

    static func removal(for reason: CKDatabase.DatabaseChange.Deletion.Reason) -> ZoneRemoval {
        switch reason {
        case .deleted: return .deleted
        case .purged: return .purged
        case .encryptedDataReset: return .encryptedDataReset
        @unknown default: return .deleted
        }
    }

    /// Stable names for `CloudSaveOutcome.failed(code:)`; the verified list of Gate G0 plus the rest of the public codes we meet.
    static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return "ckError(\(code.rawValue))"
        }
    }
}
