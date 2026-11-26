// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The only code that makes the update request. A plain GET of the given address
///
/// - no header, body or query of ours; what goes on the wire besides the request line is what the system's
///   HTTP stack adds to every request (see docs/release/privacy-audit.md, D6);
/// - an ephemeral session: no cookie storage, no cache, no credential storage, nothing kept after the call;
/// - 10 seconds for the request and 10 seconds in total, no waiting for connectivity;
/// - redirects only within the same https host, the answer is at most 64 KiB and must be HTTP 200.
struct URLSessionUpdateFetcher: UpdateFetching {
    static let timeout: TimeInterval = 10
    static let maxBytes = 64 * 1024

    /// Tests put a stub here; the app leaves it empty.
    let protocolClasses: [AnyClass]

    init(protocolClasses: [AnyClass] = []) {
        self.protocolClasses = protocolClasses
    }

    static func makeConfiguration(protocolClasses: [AnyClass]) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = nil
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    func fetch(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: Self.makeConfiguration(protocolClasses: protocolClasses))
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false

        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else { throw UpdateFetchError.notHTTP }
        guard http.statusCode == 200 else { throw UpdateFetchError.unexpectedStatus(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maxBytes { throw UpdateFetchError.tooLarge }
        }
        return data
    }
}

/// Which redirects the update request follows: only to another path on the same https host.
enum UpdateRedirectRule {
    static func allows(from: URL, to: URL) -> Bool {
        to.scheme == "https" && to.host?.lowercased() == from.host?.lowercased()
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let from = task.originalRequest?.url, let to = request.url, UpdateRedirectRule.allows(from: from, to: to)
        else { return completionHandler(nil) }
        completionHandler(request)
    }
}
