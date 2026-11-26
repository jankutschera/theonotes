// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Fetches the bytes behind a URL for `attachments add-url` and `add_attachment_from_url`.
/// Injected through `AutomationContext.fetcher` so tests never touch the network.
public protocol URLFetcher: Sendable {
    /// The body and the file name the server or the URL suggests (nil when neither names one).
    /// Throws `AutomationError` (`fetch_failed`, `usage`, `invalid_url`); anything else is reported
    /// as `fetch_failed`.
    func fetch(_ url: URL) async throws -> (data: Data, suggestedName: String?)
}

/// What a fetched URL may be.
enum URLFetchPolicy {
    /// The URL a command line or tool argument names: `invalid_url` when it is no URL or names a
    /// local or private network address, `usage` for a scheme other than https (`http:`, `file:`,
    /// `data:`, `ftp:` and the rest).
    /// The longest URL a caller may name (final review M6): the URL an agent chooses is the one
    /// outbound channel, so a note cannot leave whole in a query string. Counted in bytes of the
    /// form the network sees (`absoluteString`, percent-encoded), never in grapheme clusters: a few
    /// clusters of combining marks or emoji encode to many times as many bytes.
    static let maxURLLength = 2048

    static func parse(_ raw: String) throws(AutomationError) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A cheap bound before parsing; encoding never makes a URL shorter.
        guard trimmed.utf8.count <= maxURLLength else { throw tooLong }
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw AutomationError(code: .invalidURL, message: "Invalid URL: \(raw)")
        }
        guard url.absoluteString.utf8.count <= maxURLLength else { throw tooLong }
        try check(url)
        return url
    }

    private static var tooLong: AutomationError {
        AutomationError(code: .invalidURL, message: "The URL is longer than \(maxURLLength) bytes (in its encoded form)")
    }

    static func check(_ url: URL) throws(AutomationError) {
        guard url.scheme?.lowercased() == "https" else {
            throw AutomationError(code: .usage, message: "Only https:// URLs are supported")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw AutomationError(code: .invalidURL, message: "Invalid URL: \(url.absoluteString)")
        }
        _ = try NetworkGuard.inspect(host)
    }

    /// `100 MB`, or bytes when the limit is no whole number of megabytes.
    static func describe(limit: Int) -> String {
        let megabyte = 1024 * 1024
        return limit % megabyte == 0 ? "\(limit / megabyte) MB" : "\(limit) bytes"
    }

    static func fetchFailed(_ reason: String) -> AutomationError {
        AutomationError(code: .fetchFailed, message: "Could not fetch the URL (\(reason))")
    }
}

/// The attachment name a URL, a `Content-Disposition` header or a caller suggests: the last path
/// component, with the app's filename rules (`AttachmentStore.usableName`); nil when nothing
/// usable is left (empty, only dots and blanks), so no hidden, empty or traversing name is ever used.
enum AttachmentName {
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let component = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let visible = String(String.UnicodeScalarView(component.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }))
        let stripped = visible.drop(while: { $0 == "." || $0 == " " })
        guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return AttachmentStore.usableName(component)
    }

    /// The last path component of `url`, percent-decoded.
    static func fromPath(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let last = components.percentEncodedPath.split(separator: "/").last.map(String.init)
        return clean(last.map { $0.removingPercentEncoding ?? $0 })
    }

    /// `filename*=UTF-8''…` (RFC 5987) before `filename="…"` / `filename=…` of a `Content-Disposition` value.
    static func fromContentDisposition(_ header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        var extended: String?
        for parameter in splitParameters(header).dropFirst() {
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parameter[parameter.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // charset'language'percent-encoded
                let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3 {
                    let encoding: String.Encoding = parts[0].lowercased() == "iso-8859-1" ? .isoLatin1 : .utf8
                    extended = percentDecoded(String(parts[2]), as: encoding)
                }
            } else if key == "filename" {
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                plain = value
            }
        }
        return clean(extended) ?? clean(plain)
    }

    /// `;`-separated parts, not splitting inside double quotes.
    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for c in header {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\", quoted {
                current.append(c)
                escaped = true
            } else if c == "\"" {
                quoted.toggle()
                current.append(c)
            } else if c == ";", !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    private static func percentDecoded(_ text: String, as encoding: String.Encoding) -> String? {
        var bytes: [UInt8] = []
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%") {
                guard let high = iterator.next(), let low = iterator.next(),
                    let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
                else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(data: Data(bytes), encoding: encoding)
    }
}
