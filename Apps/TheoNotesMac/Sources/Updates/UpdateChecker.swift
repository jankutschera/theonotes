// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The update check: reads one static file from our own site and compares the version in it
/// with the installed one. It runs only when the person asks for it; nothing here schedules, downloads or
/// installs anything. Foundation only, so the request code can be compiled and inspected on its own.

/// A dotted version of one to four whole numbers ("1.2", "1.2.0"). Anything else (a pre-release suffix, an
/// empty part, an unsubstituted build setting) is not a version. Missing trailing parts count as zero.
struct AppVersion: Comparable, Sendable {
    let parts: [Int]

    init?(_ text: String?) {
        guard let text else { return nil }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard (1...6).contains(piece.count), piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece)
            else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    private var padded: [Int] { parts + Array(repeating: 0, count: 4 - parts.count) }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.padded == rhs.padded }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.padded.lexicographicallyPrecedes(rhs.padded) }
}

/// What a check found.
enum UpdateOutcome: Equatable, Sendable {
    case upToDate(installed: String)
    case updateAvailable(version: String, installed: String, downloadPage: URL, notes: String?)
    case couldNotCheck(UpdateFailure)
}

enum UpdateFailure: Equatable, Sendable {
    /// The request did not get an answer (offline, timeout, name lookup, refused redirect).
    case unreachable
    /// An answer came, but it is not a usable release file (bad status, too large, wrong shape, foreign address).
    case unreadableAnswer
    /// This copy of the app cannot tell which version it is.
    case installedVersionUnknown
}

/// Where the bytes come from. The app uses `URLSessionUpdateFetcher`; tests use a fake.
protocol UpdateFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

enum UpdateFetchError: Error, Equatable {
    case unexpectedStatus(Int)
    case notHTTP
    case tooLarge
}

/// The shape of `https://theonotes.app/latest.json`. `build` is informational; only `version` is compared.
private struct LatestRelease: Decodable {
    let version: String
    let build: Int?
    let url: String
    let notes: String?
}

struct UpdateChecker: Sendable {
    /// The one address the app asks. A static file on our own site.
    static let endpoint = URL(string: "https://theonotes.app/latest.json")!
    static let siteHost = "theonotes.app"
    static let maxNotesLength = 400

    let fetcher: any UpdateFetching
    let endpoint: URL

    init(fetcher: any UpdateFetching = URLSessionUpdateFetcher(), endpoint: URL = UpdateChecker.endpoint) {
        self.fetcher = fetcher
        self.endpoint = endpoint
    }

    func check(installedVersion: String?) async -> UpdateOutcome {
        guard let installedText = installedVersion, let installed = AppVersion(installedText) else {
            return .couldNotCheck(.installedVersionUnknown)
        }
        let data: Data
        do {
            data = try await fetcher.fetch(endpoint)
        } catch is UpdateFetchError {
            return .couldNotCheck(.unreadableAnswer)
        } catch {
            return .couldNotCheck(.unreachable)
        }
        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data),
            let latest = AppVersion(release.version), let page = Self.downloadPage(release.url)
        else { return .couldNotCheck(.unreadableAnswer) }

        // Newer only. The same version, or an older one named by a stale or tampered file, is "up to date":
        // the app never offers a downgrade.
        guard latest > installed else { return .upToDate(installed: installedText) }
        return .updateAvailable(
            version: release.version, installed: installedText, downloadPage: page, notes: Self.cleanNotes(release.notes))
    }

    /// Only an https page on our own site is ever offered to the person: no other scheme, host,
    /// port or login part, so a damaged file cannot send anyone elsewhere.
    static func downloadPage(_ text: String) -> URL? {
        guard let url = URL(string: text), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "https", components.user == nil, components.password == nil, components.port == nil,
            let host = components.host?.lowercased(), host == siteHost || host.hasSuffix("." + siteHost)
        else { return nil }
        return url
    }

    private static func cleanNotes(_ notes: String?) -> String? {
        guard let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNotesLength))
    }
}
