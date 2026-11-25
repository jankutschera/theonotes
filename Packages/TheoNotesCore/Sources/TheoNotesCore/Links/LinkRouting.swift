// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// What the app does with a URL from a note.
public enum URLAction: Equatable, Sendable {
    /// http(s) with a host, or mailto: the system opens it (browser, mail).
    case openExternally(URL)
    /// `bear://x-callback-url/open-note?id=…[&header=…]`: the imported note (at `header`) if
    /// `external_ref` knows the Bear id, else the system opens `fallbackURL` (Bear). The fallback is
    /// rebuilt from the validated id and header only, never the note's URL, so no callback
    /// parameter leaves the app.
    case openBearNote(bearId: String, header: String?, fallbackURL: URL)
    /// Anything else (file:, javascript:, data:, other apps' schemes, relative links) never opens.
    case ignore
}

/// Only web and mail URLs leave the app; everything a note could use to launch local files or
/// other apps is ignored (security: notes are imported from anywhere).
public enum LinkRouting {
    public static func action(for raw: String) -> URLAction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return .ignore }
        switch scheme {
        case "http", "https":
            guard let host = url.host(), !host.isEmpty else { return .ignore }
            return .openExternally(url)
        case "mailto":
            return text.count > "mailto:".count ? .openExternally(url) : .ignore
        case "bear":
            return bearOpenNote(text)
        default:
            return .ignore
        }
    }

    static let maxBearIdLength = 128
    static let maxBearHeaderLength = 256

    /// Only `open-note` with exactly one `id` and at most one plain-text `header`. Anything else
    /// (x-success / x-error / x-cancel, other parameters, user, port, fragment) is ignored: the
    /// fallback goes to another app, which would act on those parameters.
    private static func bearOpenNote(_ text: String) -> URLAction {
        guard let parts = URLComponents(string: text), parts.host?.lowercased() == "x-callback-url",
              parts.path.lowercased() == "/open-note", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let items = parts.queryItems else { return .ignore }
        var id: String?
        var header: String?
        for item in items {
            switch item.name {
            case "id" where id == nil:
                id = item.value
            case "header" where header == nil:
                header = item.value ?? ""
            default:
                return .ignore
            }
        }
        guard let id, isPlainText(id, maxLength: maxBearIdLength) else { return .ignore }
        if let header, !isPlainText(header, maxLength: maxBearHeaderLength) { return .ignore }
        var query = "id=" + strictlyEncoded(id)
        if let header { query += "&header=" + strictlyEncoded(header) }
        guard let fallback = URL(string: "bear://x-callback-url/open-note?" + query) else { return .ignore }
        return .openBearNote(bearId: id, header: header, fallbackURL: fallback)
    }

    /// Non-empty, bounded, no control characters.
    private static func isPlainText(_ s: String, maxLength: Int) -> Bool {
        !s.isEmpty && s.count <= maxLength && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Percent-encodes everything but RFC 3986 unreserved characters (so `&`, `=`, `#` and `+` too).
    private static func strictlyEncoded(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
