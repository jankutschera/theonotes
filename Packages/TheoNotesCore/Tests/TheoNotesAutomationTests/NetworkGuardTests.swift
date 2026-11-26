// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesAutomation

/// The address classes, host identity and lookup admission of `NetworkGuard`.
@Suite struct NetworkGuardTests {
    private static let refusal = "Refusing to fetch a local or private network address"

    private func rejection(_ raw: String) -> AutomationError? {
        do {
            _ = try URLFetchPolicy.parse(raw)
            return nil
        } catch { return error }
    }

    private func bytes(_ literal: String) -> [UInt8] {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        precondition(inet_pton(AF_INET6, literal, &v6) == 1, literal)
        return withUnsafeBytes(of: v6) { Array($0) }
    }

    // MARK: Ranges

    @Test func everyNonGlobalRangeIsBlocked() {
        let blocked = [
            "0.0.0.0", "0.255.255.255", "10.0.0.1", "100.64.0.1", "100.127.255.255", "127.0.0.1", "169.254.1.1",
            "172.16.0.1", "172.31.255.255", "192.0.0.1", "192.0.2.5", "192.168.0.1", "198.18.0.1", "198.19.255.255",
            "198.51.100.7", "203.0.113.9", "224.0.0.1", "239.255.255.255", "240.0.0.1", "250.1.2.3", "255.255.255.255",
            "::", "::1", "fe80::1", "febf::1", "fec0::1", "feff::1", "fc00::1", "fdff::1", "ff02::1",
            "2001:db8::1", "2001:0db8:ffff::1", "2001::1", "2001:0:4136:e378:8000:63bf:3fff:fdd2",
            "2002:7f00:1::", "2002:0a00:0001::1", "2002:c0a8:0101::1", "2002:a9fe:a9fe::",
            "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::127.0.0.1", "::10.1.2.3",
            "64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe", "64:ff9b::c0a8:1", "192.88.99.1",
            // Allowlist: whatever is outside 2000::/3, or a special block inside it.
            "64:ff9b:1:c0a8:1:100::", "64:ff9b:1::1", "64:ff9b::8.8.8.8", "64:ff9b::808:808", "100::1", "100::",
            "3fff::1", "3fff:0fff::1", "5f00::1", "fbff::1", "::8.8.8.8", "::808:808", "1::1", "4000::1", "7fff::1",
            "2001:1::1", "2001:1ff::1", "2001:2::1", "2001:10::1", "2001:20::1", "2002:0808:0808::1", "2002::",
            "0:0:0:0:0:fffe::1",
        ]
        for literal in blocked { #expect(NetworkGuard.isBlocked(bytes(literal)), "\(literal)") }
        let global = [
            "8.8.8.8", "93.184.216.34", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
            "192.0.1.1", "192.0.3.1", "192.88.98.1", "192.88.100.1", "192.169.0.1", "198.17.255.255", "198.20.0.1", "198.51.99.1", "198.51.101.1",
            "203.0.112.1", "203.0.114.1", "223.255.255.255", "2606:4700::1111", "2001:4860:4860::8888",
            "2001:200::1", "2001:ffff::1", "2003::1", "3ffe::1", "3ffe:ffff::1", "3fff:1000::1", "2000::1",
            "::ffff:8.8.8.8", "2a00:1450::1",
        ]
        for literal in global { #expect(!NetworkGuard.isBlocked(bytes(literal)), "\(literal)") }
        #expect(NetworkGuard.isBlocked([1, 2, 3]))
    }

    // MARK: Host identity

    @Test func hostsAreSeenAsTheLookupWillSeeThem() throws {
        // A trailing dot is kept for the lookup (`svc.` is not `svc`), case and Unicode dots are folded.
        #expect(try NetworkGuard.inspect("svc.").lookupName == "svc.")
        #expect(try NetworkGuard.inspect("SVC.Example.COM").lookupName == "svc.example.com")
        #expect(try NetworkGuard.inspect("example\u{3002}com").lookupName == "example.com")
        #expect(try NetworkGuard.inspect("example\u{FF0E}com\u{FF61}").lookupName == "example.com.")
        #expect(try NetworkGuard.inspect("example.com").literal == nil)
        #expect(try NetworkGuard.inspect("8.8.8.8").literal == [8, 8, 8, 8])
        #expect(try NetworkGuard.inspect("[2606:4700::1111]").literal?.count == 16)
        // The hosts of RFC 8215 local-use NAT64 and plain NAT64 are refused outright.
        for host in ["64:ff9b:1:c0a8:1:100::", "[64:ff9b:1:c0a8:1:100::]", "64:ff9b::8.8.8.8", "100::1", "3fff::1", "5f00::1"] {
            do {
                _ = try NetworkGuard.inspect(host)
                Issue.record("\(host) was accepted")
            } catch {
                #expect(error.code == .invalidURL && error.message == Self.refusal, "\(host)")
            }
        }
        #expect(try NetworkGuard.inspect("[::ffff:8.8.8.8]").literal?.count == 16)
        do {
            _ = try NetworkGuard.inspect("::ffff:10.0.0.1")
            Issue.record("a mapped private address was accepted")
        } catch {
            #expect(error.code == .invalidURL)
        }
        // A zone is dropped from an IPv6 literal, and from nothing else.
        #expect(try NetworkGuard.inspect("2606:4700::1111%en0").literal == bytes("2606:4700::1111"))
    }

    @Test func aPercentSignOutsideAnIPv6LiteralIsAMalformedHost() {
        for host in ["printer%x.local", "example.com%25", "ex%ample.com", "a%.example", "1.2.3.4%en0"] {
            do {
                _ = try NetworkGuard.inspect(host)
                Issue.record("\(host) was accepted")
            } catch {
                #expect(error.code == .invalidURL, "\(host)")
            }
        }
        // ... and a zone-looking tail cannot hide a local name behind a prefix.
        #expect(rejection("https://printer%25x.local/")?.code == .invalidURL)
        #expect(rejection("https://printer%25x.local/secret") != nil)
    }

    @Test func spellingsOfLocalHostsAreAllRefused() throws {
        let raw = [
            "https://svc.localhost/", "https://localhost./", "https://localhost../", "https://LOCALHOST/",
            "https://localhost%2e/", "https://local%68ost/", "https://localhost\u{3002}/",
            "https://%31%32%37.0.0.1/", "https://127%2e0%2e0%2e1/", "https://1%32%37.0.0.1/", "https://127.0.0.1./",
            "https://user@127.0.0.1/", "https://user:pw@10.0.0.1:8443/x?y#z", "https://127.0.0.1:8443/",
            "https://[::1]:8443/", "https://[fe80::1%25en0]/", "https://[fe80::1%25lo0]:9/", "https://[FD00::1]/",
            "https://[0:0:0:0:0:ffff:7f00:1]/", "https://0x7f000001/", "https://017700000001/", "https://0/",
            "https://[2002:7f00:1::]/", "https://[2001:db8::1]/", "https://[fec0::1]/", "https://[2001::1]/",
            "https://240.0.0.1/", "https://198.18.0.1/", "https://192.0.2.1/",
        ]
        for url in raw {
            guard let error = rejection(url) else {
                Issue.record("\(url) was accepted")
                continue
            }
            #expect(error.code == .invalidURL, "\(url): \(error)")
        }
        // The host is what comes after the userinfo; a local-looking userinfo or path does not matter.
        for url in [
            "https://127.0.0.1@example.com/", "https://localhost:pw@example.com:8443/", "https://example.com/127.0.0.1",
            "https://example.com:8443/", "https://[2606:4700::1111%25en0]/", "https://svc./", "https://ex\u{FF0E}com/",
        ] {
            #expect(rejection(url) == nil, "\(url)")
        }
        #expect(rejection("https://localhost/")?.message == Self.refusal)
    }

    @Test func theLookupGetsTheExactNameIncludingTheTrailingDot() async {
        let resolver = StubResolver(["svc.": [[10, 0, 0, 8]], "svc": [StubResolver.publicAddress]])
        let gate = LookupGate(limit: 4)
        do {
            try await NetworkGuard.verify(host: "svc.", resolver: resolver, gate: gate, timeout: 5)
            Issue.record("svc. resolved privately and was accepted")
        } catch {
            #expect(error.code == .invalidURL && error.message == Self.refusal)
        }
        #expect(resolver.lookups == ["svc."])
        do {
            try await NetworkGuard.verify(host: "svc", resolver: resolver, gate: gate, timeout: 5)
        } catch {
            Issue.record("svc was refused: \(error)")
        }
        #expect(resolver.lookups == ["svc.", "svc"])
    }

    // MARK: Peer

    @Test func peerAddressesMustBeKnownAndGlobal() {
        func refused(_ address: String?) -> Bool {
            do {
                try NetworkGuard.verifyPeer(address)
                return false
            } catch { return error.code == .invalidURL && error.message == Self.refusal }
        }
        let bad: [String?] = [
            nil, "", "x", "127.0.0.1", "10.1.1.1", "::1", "[::1]", "fe80::1%en0", "::ffff:192.168.1.1", "0.0.0.0",
            "2002:7f00:1::", "64:ff9b:1:c0a8:1:100::", "64:ff9b::8.8.8.8", "100::1", "3fff::1", "5f00::1",
            // A zone or brackets on an IPv4 address, or garbage after it, never parse as that address.
            "8.8.8.8%garbage", "8.8.8.8%en0", "8.8.8.8%", "[8.8.8.8]", "8.8.8.8 ", " 8.8.8.8", "8.8.8.8:80", "8.8.8",
            "2606:4700::1111%", "[2606:4700::1111", "2606:4700::1111]",
        ]
        for address in bad {
            #expect(refused(address), "\(address ?? "nil")")
        }
        for address in [
            "8.8.8.8", "93.184.216.34", "2606:4700::1111", "[2606:4700::1111]", "2606:4700::1111%en0", "::ffff:8.8.8.8",
        ] {
            #expect(!refused(address), "\(address)")
        }
    }

    // MARK: Lookup admission

    @Test func atMostFourLookupsMayBeStuckAndTheFifthFailsFast() async throws {
        let gate = LookupGate(limit: LookupGate.limit)
        #expect(LookupGate.limit == 4)
        // Each lookup hangs until the test releases it, but its caller gives up after 0.2 s; the slot
        // stays taken. (A hang of fixed length raced the test's own progress under load.)
        let hanging = HeldResolver()
        for i in 0..<4 {
            do {
                try await NetworkGuard.verify(host: "hang\(i).example", resolver: hanging, gate: gate, timeout: 0.2)
                Issue.record("lookup \(i) did not time out")
            } catch {
                #expect(error.code == .fetchFailed && error.message == "Could not fetch the URL (timed out)", "\(i)")
            }
        }
        let started = Date()
        do {
            try await NetworkGuard.verify(host: "fifth.example", resolver: StubResolver(), gate: gate, timeout: 5)
            Issue.record("the fifth lookup was admitted")
        } catch {
            #expect(error.code == .fetchFailed && error.message == "Could not fetch the URL (busy)")
        }
        #expect(Date().timeIntervalSince(started) < 0.15)
        #expect(hanging.lookups == 4)
        // Slots come back as the hung lookups return.
        hanging.release()
        #expect(try await waitUntilAsync(seconds: 5) { gate.acquire() })
        gate.release()
        do {
            try await NetworkGuard.verify(host: "later.example", resolver: StubResolver(), gate: gate, timeout: 5)
        } catch {
            Issue.record("a lookup after the hung ones returned was refused: \(error)")
        }
    }

    /// The real resolver's dispatching (its blocking lookup stood in for) must not depend on the
    /// shared pools: with the global queue's workers and every cooperative thread held, lookups still
    /// answer. On `DispatchQueue.global()` they never started, so four of them held every gate slot
    /// while their callers reported timeouts (residual round, item 1). Bounded: 3 s per lookup.
    @Test func systemResolverAnswersWhileTheSharedPoolsAreHeld() async {
        let width = ProcessInfo.processInfo.activeProcessorCount * 2
        let release = DispatchSemaphore(value: 0)
        for _ in 0..<width { DispatchQueue.global().async { _ = release.wait(timeout: .now() + 10) } }
        let resolver = SystemResolver(lookup: { _ in [StubResolver.publicAddress] })
        let outcomes = Mutex<[Bool]>([])
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<width {
                group.addTask {
                    let done = DispatchSemaphore(value: 0)
                    Task.detached(executorPreference: OffPoolExecutor.shared) {
                        if (try? await resolver.addresses(for: "held\(i).example")) == [StubResolver.publicAddress] {
                            done.signal()
                        }
                    }
                    let answered = heldWait(done, seconds: 3)
                    outcomes.withLock { $0.append(answered) }
                }
            }
        }
        for _ in 0..<width { release.signal() }
        #expect(outcomes.withLock { $0 } == Array(repeating: true, count: width))
    }

    /// Cancellation that lands after the slot was taken and before the lookup starts: no lookup is
    /// started (a `getaddrinfo` could not be stopped and would hold the slot), the slot is free again
    /// and the caller is told at once (last round, item 2).
    @Test func aLookupCancelledBeforeItStartsNeverRunsAndFreesItsSlot() async {
        let calls = Mutex(0)
        let resolver = SystemResolver(lookup: { _ in
            calls.withLock { $0 += 1 }
            return [StubResolver.publicAddress]
        })
        let gate = LookupGate(limit: 1, afterAcquire: { withUnsafeCurrentTask { $0?.cancel() } })
        let error: AutomationError? = await Task(executorPreference: OffPoolExecutor.shared) {
            do throws(AutomationError) {
                try await NetworkGuard.verify(host: "cancel-early.example", resolver: resolver, gate: gate, timeout: 5)
                return nil
            } catch {
                return error
            }
        }.value
        // Long enough for a lookup that was started anyway to reach the blocking call.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (cancelled)")
        #expect(calls.withLock { $0 } == 0, "the blocking lookup ran although the caller was cancelled")
        #expect(gate.inUse == 0)
    }

    @Test func aFinishedLookupFreesItsSlotAtOnce() async throws {
        let gate = LookupGate(limit: 1)
        for i in 0..<5 {
            try await NetworkGuard.verify(host: "quick\(i).example", resolver: StubResolver(), gate: gate, timeout: 5)
        }
    }

    @Test func theSystemResolverAnswersForALiteralWithoutTheNetwork() async throws {
        let answers = try await SystemResolver().addresses(for: "127.0.0.1")
        #expect(answers == [[127, 0, 0, 1]])
        let loopback = try await SystemResolver().addresses(for: "localhost")
        #expect(loopback.contains([127, 0, 0, 1]) || loopback.contains(Array(repeating: 0, count: 15) + [1]))
    }
}

/// Blocks the calling thread, as a synchronous test on the pool does.
private func heldWait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
    semaphore.wait(timeout: .now() + seconds) == .success
}

/// A resolver whose lookups hang until `release()`, then answer a public address.
private final class HeldResolver: HostResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var asked = 0

    var lookups: Int { lock.withLock { asked } }

    func addresses(for host: String) async throws -> [[UInt8]] {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                asked += 1
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return [StubResolver.publicAddress]
    }

    func release() {
        let held = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in held { continuation.resume() }
    }
}
