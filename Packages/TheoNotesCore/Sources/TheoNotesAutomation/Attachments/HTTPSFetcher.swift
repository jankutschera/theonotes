// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation

/// Fetches over https with hard limits: at most
/// `maxRedirects` redirects, only to https; no local or private network address, for the URL and
/// every redirect target (names are resolved and every answer checked) and for every address
/// actually connected to (`NetworkGuard`); no proxy; no response over `maxBytes` (a longer body is
/// cut off as it arrives, never buffered whole); `requestTimeout` without a byte and `totalTimeout`
/// for the whole fetch, lookups included; an ephemeral session with no cookies, cache or credentials.
public struct HTTPSFetcher: URLFetcher {
    public static let maxBytes = 100 * 1024 * 1024
    public static let requestTimeout: TimeInterval = 15
    public static let totalTimeout: TimeInterval = 30
    public static let maxRedirects = 5

    let maxBytes: Int
    let requestTimeout: TimeInterval
    let totalTimeout: TimeInterval
    let maxRedirects: Int
    /// Tests put their `URLProtocol` stub here.
    let protocolClasses: [AnyClass]
    let resolver: any HostResolver
    let gate: LookupGate
    /// The addresses a finished transfer connected to, one per transaction (redirects included).
    /// Tests stand in for the network here; a stubbed protocol has no peer.
    let peerAddresses: @Sendable (URLSessionTaskMetrics) -> [String?]
    /// The monotonic clock of the fetch's deadline, in uptime nanoseconds: the clock its timers
    /// (`DispatchTime`) use, so a change of the wall clock moves neither. Tests stand in for it.
    let now: @Sendable () -> UInt64

    public init() {
        self.init(
            maxBytes: Self.maxBytes, requestTimeout: Self.requestTimeout, totalTimeout: Self.totalTimeout,
            maxRedirects: Self.maxRedirects, protocolClasses: [], resolver: SystemResolver())
    }

    init(
        maxBytes: Int, requestTimeout: TimeInterval, totalTimeout: TimeInterval, maxRedirects: Int,
        protocolClasses: [AnyClass], resolver: any HostResolver, gate: LookupGate = .shared,
        peerAddresses: @escaping @Sendable (URLSessionTaskMetrics) -> [String?] = { metrics in
            metrics.transactionMetrics.map(\.remoteAddress)
        },
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.maxBytes = maxBytes
        self.requestTimeout = requestTimeout
        self.totalTimeout = totalTimeout
        self.maxRedirects = maxRedirects
        self.protocolClasses = protocolClasses
        self.resolver = resolver
        self.gate = gate
        self.peerAddresses = peerAddresses
        self.now = now
    }

    /// No cookies, cache, credentials or proxy (a proxy resolves names itself, past
    /// the guard).
    static func makeConfiguration(
        requestTimeout: TimeInterval, totalTimeout: TimeInterval, protocolClasses: [AnyClass]
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        configuration.waitsForConnectivity = false
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    /// Runs on `OffPoolExecutor`, so the time limits measure the fetch and not a wait for a
    /// cooperative-pool thread.
    public func fetch(_ url: URL) async throws -> (data: Data, suggestedName: String?) {
        try await withTaskExecutorPreference(OffPoolExecutor.shared) { try await fetchOnExecutor(url) }
    }

    private func fetchOnExecutor(_ url: URL) async throws -> (data: Data, suggestedName: String?) {
        try URLFetchPolicy.check(url)
        // One absolute deadline, on the monotonic clock, for the lookup, the transfer and every
        // redirect check.
        let deadline = FetchDeadline(after: totalTimeout, now: now)
        try Task.checkCancellation()
        do {
            // Cancellation-aware: cancelling the fetch here ends the wait and the lookup.
            try await NetworkGuard.verify(
                host: url.host(percentEncoded: false) ?? "", resolver: resolver, gate: gate,
                timeout: deadline.remaining)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        let remaining = max(0.001, deadline.remaining)
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Theo Notes", forHTTPHeaderField: "User-Agent")
        let download = Download(
            request: request,
            configuration: Self.makeConfiguration(
                requestTimeout: requestTimeout, totalTimeout: remaining, protocolClasses: protocolClasses),
            limits: .init(maxBytes: maxBytes, maxRedirects: maxRedirects, idleTimeout: requestTimeout, deadline: deadline),
            resolver: resolver, gate: gate, peerAddresses: peerAddresses)
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) in
                download.start(continuation)
            }
        } onCancel: {
            download.fail(CancellationError())
        }
        let name =
            AttachmentName.fromContentDisposition(response.value(forHTTPHeaderField: "Content-Disposition"))
            ?? AttachmentName.fromPath(of: response.url ?? url)
        return (data, name)
    }
}

/// A fetch's end on the monotonic clock (uptime nanoseconds, the clock of `DispatchTime` timers).
struct FetchDeadline: Sendable {
    private let end: UInt64
    private let now: @Sendable () -> UInt64

    init(after seconds: TimeInterval, now: @escaping @Sendable () -> UInt64) {
        self.now = now
        end = now() &+ UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// Seconds left, never negative.
    var remaining: TimeInterval {
        let current = now()
        return current >= end ? 0 : Double(end - current) / 1_000_000_000
    }
}

/// One redirect waiting for its target's check: its completion runs at most once and never after
/// the fetch ended, and ending the fetch cancels the check (residual round, item 2).
final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (URLRequest?) -> Void)?
    private var check: Task<Void, Never>?

    init(_ completion: @escaping @Sendable (URLRequest?) -> Void) { self.completion = completion }

    /// Runs `check` off the pool: when it passes the redirect is followed; when it throws, `failed`
    /// gets the error (as an `AutomationError`) and the redirect is refused. Neither happens once the
    /// decision was abandoned.
    func start(
        _ request: URLRequest, check: @escaping @Sendable () async throws -> Void,
        failed: @escaping @Sendable (AutomationError) -> Void
    ) {
        let task = Task.detached(executorPreference: OffPoolExecutor.shared) { [self] in
            do {
                try await check()
                take()?(request)
            } catch {
                guard let completion = take() else { return }
                failed(error as? AutomationError ?? URLFetchPolicy.fetchFailed("redirected to an unsupported address"))
                completion(nil)
            }
        }
        let abandoned: Bool = lock.withLock {
            guard completion != nil else { return true }
            self.check = task
            return false
        }
        if abandoned { task.cancel() }
    }

    /// The fetch ended: the redirect is refused now if it is still open, and its check is cancelled.
    func abandon() {
        let (completion, check): ((@Sendable (URLRequest?) -> Void)?, Task<Void, Never>?) = lock.withLock {
            defer {
                self.completion = nil
                self.check = nil
            }
            return (self.completion, self.check)
        }
        check?.cancel()
        completion?(nil)
    }

    /// The completion, taken so that nobody else can call it.
    private func take() -> (@Sendable (URLRequest?) -> Void)? {
        lock.withLock {
            defer { completion = nil }
            return completion
        }
    }
}

/// One fetch: collects the body chunk by chunk and ends it as soon as a limit is hit.
private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Limits {
        var maxBytes: Int
        var maxRedirects: Int
        var idleTimeout: TimeInterval
        /// The fetch's absolute end, shared with its first lookup.
        var deadline: FetchDeadline

        var remaining: TimeInterval { deadline.remaining }
    }

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let limits: Limits
    private let resolver: any HostResolver
    private let gate: LookupGate
    private let peerAddresses: @Sendable (URLSessionTaskMetrics) -> [String?]

    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var session: URLSession?
    private var deadline: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    /// The redirect whose target is being checked; ending the fetch abandons it.
    private var pendingRedirect: RedirectDecision?
    private var finished = false
    // Only the serial delegate queue touches these.
    private var body = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private var peerChecked = false
    private var peerFailure: AutomationError?

    init(
        request: URLRequest, configuration: URLSessionConfiguration, limits: Limits, resolver: any HostResolver,
        gate: LookupGate, peerAddresses: @escaping @Sendable (URLSessionTaskMetrics) -> [String?]
    ) {
        self.request = request
        self.configuration = configuration
        self.limits = limits
        self.resolver = resolver
        self.gate = gate
        self.peerAddresses = peerAddresses
    }

    func start(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        lock.lock()
        defer { lock.unlock() }
        // Cancelled before the fetch began.
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(
            configuration: configuration, delegate: self, delegateQueue: OffPoolExecutor.delegateQueue())
        self.session = session
        let deadline = DispatchWorkItem { [weak self] in self?.fail(URLFetchPolicy.fetchFailed("timed out")) }
        self.deadline = deadline
        OffPoolExecutor.timers.asyncAfter(deadline: .now() + limits.remaining, execute: deadline)
        armIdle()
        session.dataTask(with: request).resume()
    }

    /// (Re)starts the wait for the next byte; the lock is held.
    private func armIdle() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fail(URLFetchPolicy.fetchFailed("timed out")) }
        idle = item
        OffPoolExecutor.timers.asyncAfter(deadline: .now() + limits.idleTimeout, execute: item)
    }

    /// Something arrived: the idle wait starts over. False once the fetch is over.
    private func touch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        armIdle()
        return true
    }

    /// Ends the fetch with `error` (the first ending wins) and stops the transfer.
    func fail(_ error: any Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        let redirect = pendingRedirect
        pendingRedirect = nil
        deadline?.cancel()
        idle?.cancel()
        lock.unlock()
        redirect?.abandon()
        session?.invalidateAndCancel()
        continuation?.resume(throwing: error)
    }

    private func succeed(_ data: Data, _ response: HTTPURLResponse) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        let redirect = pendingRedirect
        pendingRedirect = nil
        deadline?.cancel()
        idle?.cancel()
        lock.unlock()
        redirect?.abandon()
        session?.finishTasksAndInvalidate()
        continuation?.resume(returning: (data, response))
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard touch() else { return completionHandler(nil) }
        redirects += 1
        guard redirects <= limits.maxRedirects else {
            fail(URLFetchPolicy.fetchFailed("too many redirects"))
            return completionHandler(nil)
        }
        // The target must pass what the first URL had to pass: https, and no local address
        // (the name is resolved, every answer checked) before the redirect is followed.
        guard let target = request.url else {
            fail(URLFetchPolicy.fetchFailed("redirected to an unsupported address"))
            return completionHandler(nil)
        }
        do throws(AutomationError) {
            try URLFetchPolicy.check(target)
        } catch {
            fail(error.code == .invalidURL ? error : URLFetchPolicy.fetchFailed("redirected to an unsupported address"))
            return completionHandler(nil)
        }
        let host = target.host(percentEncoded: false) ?? ""
        let resolver = resolver
        let gate = gate
        let timeout = limits.remaining
        let decision = RedirectDecision(completionHandler)
        let over: Bool = lock.withLock {
            guard !finished else { return true }
            pendingRedirect = decision
            return false
        }
        if over { return decision.abandon() }
        decision.start(
            request,
            check: { try await NetworkGuard.verify(host: host, resolver: resolver, gate: gate, timeout: timeout) },
            failed: { [weak self] error in self?.fail(error) })
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard touch() else { return completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else {
            fail(URLFetchPolicy.fetchFailed("not an HTTP response"))
            return completionHandler(.cancel)
        }
        guard (200..<300).contains(http.statusCode) else {
            fail(URLFetchPolicy.fetchFailed("HTTP \(http.statusCode)"))
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > Int64(limits.maxBytes) {
            fail(tooLarge)
            return completionHandler(.cancel)
        }
        // A declared length within the cap is reserved once, so appending never regrows the buffer.
        if http.expectedContentLength > 0 { body.reserveCapacity(Int(http.expectedContentLength)) }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard touch() else { return }
        // Checked before the append: one huge callback must not be allocated first.
        guard data.count <= limits.maxBytes - body.count else {
            body = Data()
            fail(tooLarge)
            return
        }
        body.append(data)
    }

    ///: every transaction (redirects included) must have connected to an address
    /// that passes the guard. The request may already have reached the target by now; what is
    /// refused is the response entering a note.
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        peerChecked = true
        do throws(AutomationError) {
            let addresses = peerAddresses(metrics)
            if addresses.isEmpty { throw NetworkGuard.refusal }
            for address in addresses { try NetworkGuard.verifyPeer(address) }
        } catch {
            peerFailure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let timedOut = (error as? URLError)?.code == .timedOut
            fail(URLFetchPolicy.fetchFailed(timedOut ? "timed out" : error.localizedDescription))
        } else if let response {
            if !peerChecked || peerFailure != nil {
                body = Data()
                fail(peerFailure ?? NetworkGuard.refusal)
            } else if body.isEmpty {
                fail(URLFetchPolicy.fetchFailed("empty response"))
            } else {
                succeed(body, response)
            }
        } else {
            fail(URLFetchPolicy.fetchFailed("no response"))
        }
    }

    private var tooLarge: AutomationError {
        URLFetchPolicy.fetchFailed("larger than \(URLFetchPolicy.describe(limit: limits.maxBytes))")
    }
}
