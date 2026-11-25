// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Darwin
import Foundation
import Synchronization

/// Answers for a host name: the raw bytes of each address (4 for IPv4, 16 for IPv6).
public protocol HostResolver: Sendable {
    func addresses(for host: String) async throws -> [[UInt8]]
}

/// `getaddrinfo` on a serial queue of its own per lookup (it blocks and cannot be cancelled;
/// `NetworkGuard.verify` bounds how long a caller waits for it, and `LookupGate` how many may be
/// stuck at once). A serial queue gets an overcommit thread: on `DispatchQueue.global()` a lookup
/// waited for the shared constrained pool, never started while it was busy, and kept its gate slot.
public struct SystemResolver: HostResolver {
    /// The blocking lookup: `getaddrinfo`, or a stand-in in tests (the dispatching stays real).
    /// Nil when the name does not resolve.
    let lookup: @Sendable (String) -> [[UInt8]]?

    public init() { self.init(lookup: Self.getaddrinfoLookup) }

    init(lookup: @escaping @Sendable (String) -> [[UInt8]]?) { self.lookup = lookup }

    public func addresses(for host: String) async throws -> [[UInt8]] {
        let lookup = lookup
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "com.truebrewbirdie.baerchen.dns").async {
                guard let found = lookup(host) else {
                    continuation.resume(throwing: URLError(.cannotFindHost))
                    return
                }
                continuation.resume(returning: found)
            }
        }
    }

    static func getaddrinfoLookup(_ host: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0 else { return nil }
        defer { freeaddrinfo(head) }
        var found: [[UInt8]] = []
        var next = head
        while let entry = next?.pointee {
            if let raw = entry.ai_addr {
                if entry.ai_family == AF_INET {
                    raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        found.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) })
                    }
                } else if entry.ai_family == AF_INET6 {
                    raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        found.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
                    }
                }
            }
            next = entry.ai_next
        }
        return found
    }
}

/// Limits how many host lookups are in flight at once. A lookup counts until its resolver call
/// returns, also after its caller timed out, so lookups that hang cannot pile up without bound.
public final class LookupGate: Sendable {
    /// Lookups allowed at once, process-wide (ruling M5-R105).
    public static let limit = 4
    public static let shared = LookupGate(limit: limit)

    private let limit: Int
    private let running = Mutex(0)
    /// Tests only: runs on the caller's task right after a slot was taken (to cancel it there).
    private let afterAcquire: (@Sendable () -> Void)?

    public convenience init(limit: Int) { self.init(limit: limit, afterAcquire: nil) }

    init(limit: Int, afterAcquire: (@Sendable () -> Void)?) {
        self.limit = limit
        self.afterAcquire = afterAcquire
    }

    func acquire() -> Bool {
        let taken = running.withLock { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        if taken { afterAcquire?() }
        return taken
    }

    /// Slots in use (tests).
    var inUse: Int { running.withLock { $0 } }

    func release() { running.withLock { $0 -= 1 } }
}

/// Keeps a fetch away from the machine's own services and the local network (rulings M5-R105 to
/// M5-R108): an agent driven by injected text must not pull a local page into a note. A host is
/// refused when it is `localhost`, a `.localhost` or `.local` name, a literal address in a blocked
/// range, or when any address it resolves to is in one. After the transfer the addresses actually
/// connected to are checked as well (`verifyPeer`).
enum NetworkGuard {
    static let refusal = AutomationError(
        code: .invalidURL, message: "Refusing to fetch a local or private network address")

    // MARK: Hosts

    /// What a URL's host stands for.
    struct Host {
        /// The name exactly as URLSession will look it up: lowercase, Unicode dots as `.`, a trailing
        /// dot kept (`svc.` and `svc` are different names to a resolver with a search list).
        var lookupName: String
        /// Set when the host is an address literal.
        var literal: [UInt8]?
    }

    /// The host of a URL as the guard and the lookup must see it, or the reason it is refused:
    /// `invalid_url` for a malformed host (`%` in a name that is no IPv6 literal), the refusal for a
    /// local name or a blocked literal. Case, brackets, an IPv6 zone and trailing dots never hide a
    /// local host. No lookup.
    static func inspect(_ rawHost: String) throws(AutomationError) -> Host {
        var name = rawHost
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        var literalBytes: [UInt8]?
        if name.contains(":") {
            // Only an IPv6 literal may carry a zone.
            let bare = name.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, bare, &v6) == 1 else {
                throw AutomationError(code: .invalidURL, message: "Invalid URL: host \(rawHost)")
            }
            literalBytes = withUnsafeBytes(of: v6) { Array($0) }
            name = bare
        } else if name.contains("%") {
            throw AutomationError(code: .invalidURL, message: "Invalid URL: host \(rawHost)")
        }
        name = String(String.UnicodeScalarView(name.lowercased().unicodeScalars.map { dots.contains($0) ? "." : $0 }))
        // A name's trailing dots do not change what it is for the checks below.
        var bare = name
        while bare.hasSuffix(".") { bare.removeLast() }
        if literalBytes == nil {
            var v4 = in_addr()
            if inet_aton(bare, &v4) != 0 { literalBytes = withUnsafeBytes(of: v4) { Array($0) } }
        }
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare.hasSuffix(".local") { throw refusal }
        if let literalBytes, isBlocked(literalBytes) { throw refusal }
        return Host(lookupName: name, literal: literalBytes)
    }

    /// The dots IDNA maps to `.`: ideographic, fullwidth and halfwidth ideographic full stops.
    private static let dots: Set<Unicode.Scalar> = ["\u{3002}", "\u{FF0E}", "\u{FF61}"]

    /// Checks `host`, then resolves it (at most `timeout` seconds, one of `gate`'s slots) and
    /// refuses it when any answer is blocked.
    static func verify(
        host rawHost: String, resolver: any HostResolver, gate: LookupGate, timeout: TimeInterval
    ) async throws(AutomationError) {
        let host = try inspect(rawHost)
        if host.literal != nil { return }
        let answers: [[UInt8]]
        do {
            answers = try await resolve(host.lookupName, with: resolver, gate: gate, timeout: timeout)
        } catch let error as AutomationError {
            throw error
        } catch is CancellationError {
            throw URLFetchPolicy.fetchFailed("cancelled")
        } catch {
            throw URLFetchPolicy.fetchFailed("could not resolve \(host.lookupName)")
        }
        guard !answers.isEmpty else { throw URLFetchPolicy.fetchFailed("could not resolve \(host.lookupName)") }
        if answers.contains(where: isBlocked) { throw refusal }
    }

    /// An address URLSession reports having connected to (`URLSessionTaskTransactionMetrics.remoteAddress`):
    /// missing, unreadable or blocked is the refusal.
    static func verifyPeer(_ address: String?) throws(AutomationError) {
        guard let address else { throw refusal }
        // The family first: brackets and a %zone belong to IPv6 literals only.
        let bytes: [UInt8]
        if address.contains(":") {
            var name = address
            if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
            if let zone = name.firstIndex(of: "%") {
                guard name.index(after: zone) < name.endIndex else { throw refusal }  // an empty zone is malformed
                name = String(name[..<zone])
            }
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, name, &v6) == 1 else { throw refusal }
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            var v4 = in_addr()
            guard inet_pton(AF_INET, address, &v4) == 1 else { throw refusal }
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        }
        if isBlocked(bytes) { throw refusal }
    }

    /// One lookup's outcome: the first of answer, timeout and cancellation wins, resumes the caller
    /// once, and cancels the lookup task and the timer (a cancellable resolver then returns and frees
    /// its slot). An outcome that comes before the continuation or the task is kept and applied when
    /// they arrive.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[[UInt8]], any Error>?
        private var outcome: Result<[[UInt8]], any Error>?
        private var lookup: Task<Void, Never>?
        private var timer: DispatchWorkItem?

        /// False when the outcome is already known: the caller was resumed with it.
        @discardableResult
        func attach(_ continuation: CheckedContinuation<[[UInt8]], any Error>) -> Bool {
            let ready: Result<[[UInt8]], any Error>? = lock.withLock {
                if outcome == nil { self.continuation = continuation }
                return outcome
            }
            guard let ready else { return true }
            continuation.resume(with: ready)
            return false
        }

        /// No outcome yet.
        var isOpen: Bool { lock.withLock { outcome == nil } }

        func track(_ lookup: Task<Void, Never>, timer: DispatchWorkItem) {
            let over: Bool = lock.withLock {
                guard outcome == nil else { return true }
                self.lookup = lookup
                self.timer = timer
                return false
            }
            if over {
                lookup.cancel()
                timer.cancel()
            }
        }

        func finish(_ result: Result<[[UInt8]], any Error>) {
            let (continuation, lookup, timer): (CheckedContinuation<[[UInt8]], any Error>?, Task<Void, Never>?, DispatchWorkItem?) =
                lock.withLock {
                    guard outcome == nil else { return (nil, nil, nil) }
                    outcome = result
                    defer {
                        self.continuation = nil
                        self.lookup = nil
                        self.timer = nil
                    }
                    return (self.continuation, self.lookup, self.timer)
                }
            lookup?.cancel()
            timer?.cancel()
            continuation?.resume(with: result)
        }
    }

    /// The resolver's answer, a timeout or the caller's cancellation (whichever comes first), or
    /// `busy` at once when `gate` has no free slot. The lookup is cancelled when the caller stops
    /// waiting; a lookup that ignores that (`getaddrinfo`) keeps its slot until it returns.
    private static func resolve(
        _ host: String, with resolver: any HostResolver, gate: LookupGate, timeout: TimeInterval
    ) async throws -> [[UInt8]] {
        try Task.checkCancellation()
        guard gate.acquire() else { throw URLFetchPolicy.fetchFailed("busy") }
        // A cancellation or a spent deadline that came while the slot was taken: give it back and
        // start nothing (a started `getaddrinfo` cannot be stopped and would hold the slot).
        if Task.isCancelled {
            gate.release()
            throw CancellationError()
        }
        guard timeout > 0 else {
            gate.release()
            throw URLFetchPolicy.fetchFailed("timed out")
        }
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Ended already (cancelled in between): `attach` resumed the caller; launch nothing.
                guard once.attach(continuation) else {
                    gate.release()
                    return
                }
                let lookup = Task.detached(executorPreference: OffPoolExecutor.shared) {
                    defer { gate.release() }
                    // Ended before this task ran: the resolver is never called.
                    guard once.isOpen else { return }
                    do {
                        once.finish(.success(try await resolver.addresses(for: host)))
                    } catch {
                        once.finish(.failure(error))
                    }
                }
                let timer = DispatchWorkItem { once.finish(.failure(URLFetchPolicy.fetchFailed("timed out"))) }
                OffPoolExecutor.timers.asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
                once.track(lookup, timer: timer)
            }
        } onCancel: {
            once.finish(.failure(CancellationError()))
        }
    }

    // MARK: Addresses

    /// 4 bytes: IPv4; 16 bytes: IPv6. Everything that is not global unicast space is blocked
    /// (M5-R105, M5-R108).
    static func isBlocked(_ address: [UInt8]) -> Bool {
        address.count == 4 ? isBlockedV4(address) : address.count == 16 ? isBlockedV6(address) : true
    }

    private static func isBlockedV4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1], a[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return true  // this network (0.0.0.0/8), private, loopback
        case (100, 64...127, _): return true  // carrier-grade NAT 100.64.0.0/10
        case (169, 254, _): return true  // link-local
        case (172, 16...31, _): return true
        case (192, 0, 0), (192, 0, 2): return true  // IETF protocol assignments, TEST-NET-1
        case (192, 88, 99): return true  // 6to4 relay anycast, deprecated
        case (192, 168, _): return true
        case (198, 18...19, _): return true  // benchmarking 198.18.0.0/15
        case (198, 51, 100), (203, 0, 113): return true  // TEST-NET-2, TEST-NET-3
        case (224...255, _, _): return true  // multicast 224.0.0.0/4, reserved 240.0.0.0/4, broadcast
        default: return false
        }
    }

    /// An allowlist: an IPv6 address passes only in global unicast space 2000::/3, less the
    /// special-purpose blocks inside it; IPv4-mapped addresses are judged by their IPv4. Everything
    /// else (NAT64 in both forms, 100::/64, unique-local, link-local, multicast, `::`, `::1`,
    /// IPv4-compatible) is refused.
    private static func isBlockedV6(_ a: [UInt8]) -> Bool {
        // IPv4-mapped ::ffff:a.b.c.d.
        if a[0..<10].allSatisfy({ $0 == 0 }), a[10] == 0xFF, a[11] == 0xFF { return isBlockedV4(Array(a[12..<16])) }
        guard a[0] & 0xE0 == 0x20 else { return true }
        if a[0] == 0x20, a[1] == 0x01, a[2] & 0xFE == 0x00 { return true }  // 2001::/23: IETF protocol assignments, Teredo, ORCHID
        if a[0] == 0x20, a[1] == 0x01, a[2] == 0x0D, a[3] == 0xB8 { return true }  // 2001:db8::/32 documentation
        if a[0] == 0x20, a[1] == 0x02 { return true }  // 2002::/16 6to4
        if a[0] == 0x3F, a[1] == 0xFF, a[2] & 0xF0 == 0x00 { return true }  // 3fff::/20 documentation
        return false
    }
}
