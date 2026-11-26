// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import os

/// Every action of `theonotes://x-callback-url/<action>` (inventory §2.18).
public enum XCallbackAction: String, CaseIterable, Sendable {
    case openNote = "open-note"
    case create
    case addText = "add-text"
    case addFile = "add-file"
    case tags
    case openTag = "open-tag"
    case renameTag = "rename-tag"
    case deleteTag = "delete-tag"
    case trash
    case archive
    case untagged
    case todo
    case today
    case locked
    case search
    case grabURL = "grab-url"
    case openWorkspace = "open-workspace"
    case closeWorkspace = "close-workspace"
}

/// What `x-error` carries: 1 invalid parameter, 2 note not found, 3 note locked
/// or read-only, 4 invalid or missing token, 5 action not supported, 6 failed.
public struct XCallbackFailure: Error, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    static func invalid(_ message: String) -> XCallbackFailure { .init(code: 1, message: message) }
    static func noteNotFound(_ what: String) -> XCallbackFailure { .init(code: 2, message: "Note not found: \(what)") }
    static func locked(_ message: String) -> XCallbackFailure { .init(code: 3, message: message) }
    static let badToken = XCallbackFailure(code: 4, message: "Invalid or missing token")
    static func unsupported(_ message: String) -> XCallbackFailure { .init(code: 5, message: message) }
    static func failed(_ message: String) -> XCallbackFailure { .init(code: 6, message: message) }

    /// What `x-error` says when the caller has no valid token: the code's meaning and nothing
    /// that came from the library.
    public static func genericMessage(forCode code: Int) -> String {
        switch code {
        case 1: "Invalid parameter"
        case 2: "Note not found"
        case 3: "Note is locked or read-only"
        case 4: "Invalid or missing token"
        case 5: "Action not supported"
        default: "The action failed"
        }
    }

    /// The failure a library or service error stands for.
    init(_ error: AutomationError) {
        switch error.code {
        case .noteNotFound, .notFound: self = .init(code: 2, message: error.message)
        case .noteLocked, .readOnly, .lockedNotes: self = .init(code: 3, message: error.message)
        case .usage, .ambiguous, .tagExists, .tagNotFound, .attachmentNotFound, .invalidURL:
            self = .init(code: 1, message: error.message)
        default: self = .init(code: 6, message: error.message)
        }
    }
}

/// A parsed `theonotes://x-callback-url/<action>?…` URL. Query values are percent-decoded with
/// `URLComponents` semantics: `+` stays a plus. The first occurrence of a
/// repeated parameter wins. `x-success`, `x-error` and `x-cancel` are not in `params`.
public struct XCallbackRequest: Sendable {
    public var action: XCallbackAction
    public var params: [String: String]
    public var success: URL?
    public var error: URL?
    public var cancel: URL?

    public init(
        action: XCallbackAction, params: [String: String] = [:], success: URL? = nil, error: URL? = nil,
        cancel: URL? = nil
    ) {
        self.action = action
        self.params = params
        self.success = success
        self.error = error
        self.cancel = cancel
    }

    /// The scheme the app emits (copied links, launch URLs, help text).
    public static let scheme = "theonotes"
    /// Schemes the parser accepts: the old one keeps links copied before the rename working.
    public static let acceptedSchemes: Set<String> = Set(AppIdentity.allCases.flatMap(\.urlSchemes))
    public static let host = "x-callback-url"

    public static func parse(_ url: URL) throws(XCallbackFailure) -> XCallbackRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let urlScheme = components.scheme?.lowercased(), acceptedSchemes.contains(urlScheme),
            components.host?.lowercased() == host
        else { throw .invalid("Not a \(scheme)://\(host)/ URL") }
        let name = components.path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let action = XCallbackAction(rawValue: name.lowercased()) else {
            throw .unsupported("Action not supported: \(name)")
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] where params[item.name] == nil {
            params[item.name] = item.value ?? ""
        }
        func callback(_ key: String) -> URL? {
            guard let raw = params.removeValue(forKey: key), !raw.isEmpty else { return nil }
            return URL(string: raw)
        }
        let success = callback("x-success")
        let error = callback("x-error")
        let cancel = callback("x-cancel")
        return XCallbackRequest(action: action, params: params, success: success, error: error, cancel: cancel)
    }

    /// `yes` is true, `no` false, anything else (or absent) nil.
    public func flag(_ k: String) -> Bool? {
        switch params[k]?.lowercased() {
        case "yes": true
        case "no": false
        default: nil
        }
    }
}

/// What the app should show once the executor is done.
public enum XCallbackUIIntent: Equatable, Sendable {
    case none
    case openNote(
        id: String, header: String?, newWindow: Bool, float: Bool, edit: Bool, find: String?, showWindow: Bool)
    case select(SidebarScope, search: String?, showWindow: Bool)
    case openWorkspace(String)
    case closeWorkspace
}

/// The result of one request: what to show, and what to hand back to the caller.
///
/// `success` nil with no `failure` calls nothing back; `[]` calls `x-success` without parameters.
public struct XCallbackOutcome: Sendable {
    public var ui: XCallbackUIIntent
    public var success: [(String, String)]?
    public var failure: XCallbackFailure?
    /// Whether `x-error` may carry `failure.message`. Off: only the code and its generic text
    ///. The executor turns it on for a request with a valid token; `failure`
    /// itself always keeps the detailed message for the app's own alert.
    public var detailedErrors: Bool
    /// An open `XCallbackReceipts` entry for this answer: settle it once the answer was handed back.
    public var receipt: String?

    public init(
        ui: XCallbackUIIntent, success: [(String, String)]?, failure: XCallbackFailure?, detailedErrors: Bool = false
    ) {
        self.ui = ui
        self.success = success
        self.failure = failure
        self.detailedErrors = detailedErrors
    }

    /// Schemes a callback is never opened for: a web page or file would receive
    /// note text.
    static let blockedSchemes: Set<String> = [
        "http", "https", "file", "ftp", "data", "javascript", "about", LegacyNames.urlScheme, "theonotes", LegacyNames.urlScheme + "-dev", "theonotes-dev",
        // Browser and bridge schemes: they hand the URL on to a web page, a
        // remote host or another app that is not the caller.
        "blob", "ws", "wss", "ssh", "sftp", "smb", "afp", "vnc", "tel", "sms", "mailto", "facetime",
    ]

    /// Prefixes of blocked scheme families: `x-apple-*`, `itms*`, `ms-*`, and the browsers' own.
    static let blockedSchemePrefixes = [
        "x-apple-", "itms", "ms-", "googlechrome", "firefox", "opera", "microsoft-edge", "brave",
    ]

    /// A callback is used only for a valid RFC 3986 scheme (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`)
    /// that is neither blocked nor in a blocked family.
    static func isAllowedScheme(_ scheme: String) -> Bool {
        let s = scheme.lowercased()
        guard let first = s.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first),
            s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return false }
        return !blockedSchemes.contains(s) && !blockedSchemePrefixes.contains { s.hasPrefix($0) }
    }

    private static let log = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "xcallback")

    /// `x-error` + `errorCode` / `errorMessage` for a failure, else `x-success` + the success
    /// parameters. nil when there is nothing to call or the scheme is blocked.
    public func callbackURL(for r: XCallbackRequest) -> URL? {
        let target: URL?
        let items: [(String, String)]
        if let failure {
            target = r.error
            let message = detailedErrors ? failure.message : XCallbackFailure.genericMessage(forCode: failure.code)
            items = [("errorCode", String(failure.code)), ("errorMessage", message)]
        } else if let success {
            target = r.success
            items = success
        } else {
            return nil
        }
        guard let target else { return nil }
        let scheme = target.scheme?.lowercased() ?? ""
        guard Self.isAllowedScheme(scheme) else {
            Self.log.error("callback dropped: scheme \(scheme, privacy: .public) is not allowed")
            return nil
        }
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return nil }
        let added = items.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&")
        if !added.isEmpty {
            if let existing = components.percentEncodedQuery, !existing.isEmpty {
                components.percentEncodedQuery = existing + "&" + added
            } else {
                components.percentEncodedQuery = added
            }
        }
        return components.url
    }

    /// Everything but unreserved characters is escaped, so `+`, `&` and `=` survive the trip.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
