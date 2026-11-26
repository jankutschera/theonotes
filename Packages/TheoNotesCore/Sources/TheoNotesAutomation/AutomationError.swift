// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// Error codes of the `{"error":{"code",…}}` envelope.
public enum ErrorCode: String, Sendable, CaseIterable {
    // Observed from bearcli.
    case usage
    case noteNotFound = "note_not_found"
    case notFound = "not_found"
    case ambiguous
    // Theo Notes' own, plus `out_of_scope`, which bearcli documents.
    case noteLocked = "note_locked"
    case readOnly = "read_only"
    case outOfScope = "out_of_scope"
    case staleHash = "stale_hash"
    case attachmentsRemoved = "attachments_removed"
    case tagExists = "tag_exists"
    case lockedNotes = "locked_notes"
    case tagNotFound = "tag_not_found"
    case attachmentNotFound = "attachment_not_found"
    case invalidURL = "invalid_url"
    case fetchFailed = "fetch_failed"
    case libraryUnavailable = "library_unavailable"
    case appUnavailable = "app_unavailable"
    case busy
    /// The Mac app is locked (App Lock): it answers no request that could return library content.
    case appLocked = "app_locked"
    case `internal`
}

public struct AutomationError: Error, Equatable, Sendable {
    public var code: ErrorCode
    public var message: String
    public var details: JSONValue?

    public init(code: ErrorCode, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// 64 (EX_USAGE) for a usage error, 1 for every other business error.
    public var exitCode: Int32 { code == .usage ? 64 : 1 }

    /// `{"error":{"code":…,"message":…[,"details":…]}}`
    public func envelope() -> JSONValue {
        var fields: [(String, JSONValue)] = [("code", .string(code.rawValue)), ("message", .string(message))]
        if let details { fields.append(("details", details)) }
        return .object([("error", .object(fields))])
    }
}
