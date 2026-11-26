// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Synchronization
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// A `URLProtocol` that serves canned responses by URL, so no test touches the network. Each test
/// uses hosts of its own: the registry is shared by every test that runs.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        /// A status, headers and a body sent in `chunks`.
        case respond(status: Int, headers: [String: String], chunks: [Data])
        case redirect(status: Int, to: String)
        /// Sends `chunk` again and again until the client stops the load.
        case endless(chunk: Data)
        /// Never answers.
        case stall
        /// Answers 200, sends `chunk`, then goes quiet.
        case partialThenStall(chunk: Data)
    }

    private static let behaviors = Mutex<[String: Behavior]>([:])
    private static let requests = Mutex<[String]>([])
    private static let chunksSent = Mutex<[String: Int]>([:])
    private static let stopped = Mutex<Set<String>>([])

    static func register(_ url: String, _ behavior: Behavior) {
        behaviors.withLock { $0[url] = behavior }
    }

    static func respond(_ url: String, body: Data = Data("ok".utf8), headers: [String: String] = [:]) {
        register(url, .respond(status: 200, headers: headers, chunks: [body]))
    }

    static func requested(_ url: String) -> Bool { requests.withLock { $0.contains(url) } }
    static func sent(_ url: String) -> Int { chunksSent.withLock { $0[url] ?? 0 } }
    static func wasStopped(_ url: String) -> Bool { stopped.withLock { $0.contains(url) } }

    private let running = Mutex(true)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let key = Optional(url.absoluteString) else { return }
        Self.requests.withLock { $0.append(key) }
        let behavior = Self.behaviors.withLock { $0[key] }
        switch behavior {
        case .respond(let status, let headers, let chunks)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
                Self.chunksSent.withLock { $0[key, default: 0] += 1 }
            }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let target)?:
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
        case .endless(let chunk)?:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // A serial queue of its own (an overcommit thread, see OffPoolExecutor): the global concurrent queue shares
            // the constrained pool with the cooperative threads, and in a busy parallel run it sent nothing for seconds.
            DispatchQueue(label: "test.stub-url-protocol.endless").async { [self] in
                // Bounded, so a client that never stops us cannot run away.
                for _ in 0..<20_000 where running.withLock({ $0 }) {
                    client?.urlProtocol(self, didLoad: chunk)
                    Self.chunksSent.withLock { $0[key, default: 0] += 1 }
                    usleep(1_000)
                }
            }
        case .partialThenStall(let chunk)?:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: chunk)
        case .stall?, nil:
            break
        }
    }

    override func stopLoading() {
        running.withLock { $0 = false }
        if let key = request.url?.absoluteString { Self.stopped.withLock { _ = $0.insert(key) } }
    }
}

/// Answers lookups from a table; a host that is not in it resolves to a public address.
final class StubResolver: HostResolver {
    static let publicAddress: [UInt8] = [93, 184, 216, 34]
    private let table: [String: [[UInt8]]]
    private let asked = Mutex<[String]>([])
    private let offPool = Mutex<[Bool]>([])
    private let cancelledHosts = Mutex<[String]>([])
    private let hang: Duration?
    private let hangOnly: Set<String>?

    /// `hang` delays every lookup, or only those of `hangOnly` when given; a hang ends early when
    /// the lookup is cancelled (recorded in `cancelled`).
    init(_ table: [String: [[UInt8]]] = [:], hang: Duration? = nil, hangOnly: Set<String>? = nil) {
        self.table = table
        self.hang = hang
        self.hangOnly = hangOnly
    }

    /// The hosts whose hanging lookup was cancelled.
    var cancelled: [String] { cancelledHosts.withLock { $0 } }

    var lookups: [String] { asked.withLock { $0 } }
    /// Per lookup: whether it ran on the fetch's own executor rather than the shared cooperative pool.
    var lookupsOffThePool: [Bool] { offPool.withLock { $0 } }

    func addresses(for host: String) async throws -> [[UInt8]] {
        asked.withLock { $0.append(host) }
        offPool.withLock { $0.append(OffPoolExecutor.isCurrent) }
        if let hang, hangOnly?.contains(host) ?? true {
            do {
                try await Task.sleep(for: hang)
            } catch {
                cancelledHosts.withLock { $0.append(host) }
                throw error
            }
        }
        if host == "unresolvable.example" { throw URLError(.cannotFindHost) }
        return table[host] ?? [Self.publicAddress]
    }
}

/// What the network would report: one public peer per transaction.
let publicPeer: @Sendable (URLSessionTaskMetrics) -> [String?] = { _ in ["93.184.216.34"] }

@Suite struct URLFetcherTests {
    private func fetcher(
        maxBytes: Int = 1_000_000, requestTimeout: TimeInterval = 5, totalTimeout: TimeInterval = 5,
        maxRedirects: Int = 5, resolver: StubResolver = StubResolver(), gate: LookupGate = LookupGate(limit: 4),
        peers: @escaping @Sendable (URLSessionTaskMetrics) -> [String?] = publicPeer
    ) -> HTTPSFetcher {
        HTTPSFetcher(
            maxBytes: maxBytes, requestTimeout: requestTimeout, totalTimeout: totalTimeout,
            maxRedirects: maxRedirects, protocolClasses: [StubURLProtocol.self], resolver: resolver, gate: gate,
            peerAddresses: peers)
    }

    private func failure(_ work: () async throws -> Void) async -> AutomationError? {
        do {
            try await work()
            return nil
        } catch let error as AutomationError {
            return error
        } catch {
            return AutomationError(code: .internal, message: "\(error)")
        }
    }

    // MARK: Limits

    @Test func limitsAreTheDocumentedOnes() {
        #expect(HTTPSFetcher.maxBytes == 100 * 1024 * 1024)
        #expect(HTTPSFetcher.totalTimeout == 30 && HTTPSFetcher.requestTimeout == 15)
        #expect(HTTPSFetcher.maxRedirects == 5)
    }

    // MARK: Fetching

    @Test func returnsTheBodyAndTheNameOfTheURLsLastPathComponent() async throws {
        let url = "https://fetch-basic.example/files/My%20Photo.jpg"
        StubURLProtocol.register(url, .respond(status: 200, headers: [:], chunks: [Data([1, 2]), Data([3])]))
        let fetched = try await fetcher().fetch(URL(string: url)!)
        #expect(fetched.data == Data([1, 2, 3]))
        #expect(fetched.suggestedName == "My Photo.jpg")
    }

    @Test func contentDispositionBeatsTheURL() async throws {
        let url = "https://fetch-disposition.example/download"
        StubURLProtocol.respond(url, headers: ["Content-Disposition": #"attachment; filename="report.pdf""#])
        #expect(try await fetcher().fetch(URL(string: url)!).suggestedName == "report.pdf")
    }

    @Test func aURLWithoutAFileNameSuggestsNone() async throws {
        let url = "https://fetch-noname.example/"
        StubURLProtocol.respond(url)
        #expect(try await fetcher().fetch(URL(string: url)!).suggestedName == nil)
    }

    @Test func nonSuccessStatusIsFetchFailedWithTheCode() async {
        let url = "https://fetch-404.example/x.jpg"
        StubURLProtocol.register(url, .respond(status: 404, headers: [:], chunks: [Data("no".utf8)]))
        let error = await failure { _ = try await fetcher().fetch(URL(string: url)!) }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (HTTP 404)")
    }

    @Test func onlyHTTPSIsFetchedAndNothingIsRequestedOtherwise() async {
        for raw in [
            "http://fetch-scheme.example/x", "file:///etc/passwd", "data:text/plain,hi", "ftp://fetch-scheme.example/x",
            "javascript:alert(1)",
        ] {
            let error = await failure { _ = try await fetcher().fetch(URL(string: raw)!) }
            #expect(error?.code == .usage, "\(raw)")
            #expect(error?.message == "Only https:// URLs are supported", "\(raw)")
            #expect(!StubURLProtocol.requested(raw))
        }
    }

    @Test func parsingARawURLSeparatesBadURLsFromBadSchemes() {
        func code(_ raw: String) -> ErrorCode? {
            do {
                _ = try URLFetchPolicy.parse(raw)
                return nil
            } catch { return error.code }
        }
        #expect(code("https://example.com/a.jpg") == nil)
        #expect(code("  https://example.com/a.jpg ") == nil)
        #expect(code("http://example.com/a.jpg") == .usage)
        #expect(code("HTTPS://example.com/a.jpg") == nil)
        #expect(code("file:///etc/passwd") == .usage)
        #expect(code("data:text/plain;base64,aGk=") == .usage)
        #expect(code("ftp://example.com/x") == .usage)
        #expect(code("") == .invalidURL)
        #expect(code("not a url") == .invalidURL)
        #expect(code("example.com/a.jpg") == .invalidURL)
        #expect(code("https://") == .invalidURL)
    }

    /// The URL an agent chooses is the one outbound channel (final review M6): capped at 2048
    /// characters, so a note cannot be carried out whole in a query string.
    @Test func aURLLongerThan2048CharactersIsRefused() {
        let prefix = "https://example.com/?q="
        let atCap = prefix + String(repeating: "a", count: URLFetchPolicy.maxURLLength - prefix.count)
        #expect(URLFetchPolicy.maxURLLength == 2048 && atCap.count == 2048)
        #expect((try? URLFetchPolicy.parse(atCap)) != nil)
        #expect((try? URLFetchPolicy.parse("  " + atCap + "\n")) != nil)
        do {
            _ = try URLFetchPolicy.parse(atCap + "a")
            Issue.record("a 2049-character URL was accepted")
        } catch {
            #expect(error.code == .invalidURL && error.message == "The URL is longer than 2048 bytes (in its encoded form)")
        }
    }

    /// The cap is on what the network sees: `String.count` counts grapheme clusters, so a URL of
    /// few clusters (combining marks, emoji, non-ASCII letters) could carry a percent-encoded form
    /// many times longer.
    @Test func theCapCountsThePercentEncodedFormNotGraphemeClusters() throws {
        let prefix = "https://example.com/?q="
        let cases = [
            ("precomposed letters", prefix + String(repeating: "\u{E9}", count: 1_000)),
            ("combining marks", prefix + "a" + String(repeating: "\u{301}", count: 700)),
            ("emoji", prefix + String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 40)),
        ]
        for (name, raw) in cases {
            // Short in clusters and in raw UTF-8 bytes: only the encoded form is over the cap.
            #expect(raw.count <= URLFetchPolicy.maxURLLength && raw.utf8.count <= URLFetchPolicy.maxURLLength, "\(name)")
            let encoded = try #require(URL(string: raw)).absoluteString
            #expect(encoded.utf8.count > URLFetchPolicy.maxURLLength, "\(name)")
            do {
                _ = try URLFetchPolicy.parse(raw)
                Issue.record("\(name) was accepted")
            } catch {
                #expect(error.code == .invalidURL && error.message == "The URL is longer than 2048 bytes (in its encoded form)", "\(name)")
            }
        }
        // A raw string over the cap in bytes is refused before it is parsed.
        let wide = prefix + String(repeating: "\u{E9}", count: 1_100)
        #expect(wide.count <= URLFetchPolicy.maxURLLength && wide.utf8.count > URLFetchPolicy.maxURLLength)
        #expect((try? URLFetchPolicy.parse(wide)) == nil)
    }

    // MARK: Redirects

    @Test func followsUpToFiveRedirects() async throws {
        for i in 0..<5 {
            StubURLProtocol.register(
                "https://fetch-r5.example/\(i)", .redirect(status: 302, to: "https://fetch-r5.example/\(i + 1)"))
        }
        StubURLProtocol.respond("https://fetch-r5.example/5", body: Data("end".utf8))
        let fetched = try await fetcher().fetch(URL(string: "https://fetch-r5.example/0")!)
        #expect(fetched.data == Data("end".utf8))
    }

    @Test func aSixthRedirectFails() async {
        for i in 0..<6 {
            StubURLProtocol.register(
                "https://fetch-r6.example/\(i)", .redirect(status: 302, to: "https://fetch-r6.example/\(i + 1)"))
        }
        StubURLProtocol.respond("https://fetch-r6.example/6")
        let error = await failure { _ = try await fetcher().fetch(URL(string: "https://fetch-r6.example/0")!) }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (too many redirects)")
        #expect(!StubURLProtocol.requested("https://fetch-r6.example/6"))
    }

    @Test func neverFollowsARedirectToAnotherScheme() async {
        for target in ["file:///etc/passwd", "ftp://fetch-rscheme.example/x", "data:text/plain,hi"] {
            StubURLProtocol.register("https://fetch-rscheme.example/go", .redirect(status: 302, to: target))
            let error = await failure { _ = try await fetcher().fetch(URL(string: "https://fetch-rscheme.example/go")!) }
            #expect(error?.code == .fetchFailed, "\(target)")
            #expect(!StubURLProtocol.requested(target), "\(target)")
        }
    }

    @Test func neverFollowsARedirectDownToHTTP() async {
        StubURLProtocol.register(
            "https://fetch-down.example/go", .redirect(status: 301, to: "http://fetch-down.example/plain"))
        StubURLProtocol.respond("http://fetch-down.example/plain")
        let error = await failure { _ = try await fetcher().fetch(URL(string: "https://fetch-down.example/go")!) }
        #expect(error?.code == .fetchFailed)
        #expect(!StubURLProtocol.requested("http://fetch-down.example/plain"))
    }

    @Test func everyRedirectStatusIsFollowed() async throws {
        for status in [301, 302, 303, 307, 308] {
            let from = "https://fetch-status\(status).example/go"
            StubURLProtocol.register(from, .redirect(status: status, to: "https://fetch-status\(status)-b.example/f.bin"))
            StubURLProtocol.respond("https://fetch-status\(status)-b.example/f.bin", body: Data([UInt8(status % 256)]))
            let fetched = try await fetcher().fetch(URL(string: from)!)
            #expect(fetched.data == Data([UInt8(status % 256)]), "\(status)")
        }
    }

    @Test func theNameComesFromTheFinalURLAfterRedirects() async throws {
        StubURLProtocol.register("https://short-link.example/x", .redirect(status: 302, to: "https://cdn-final.example/a/photo.jpg"))
        StubURLProtocol.respond("https://cdn-final.example/a/photo.jpg", body: Data([1]))
        #expect(try await fetcher().fetch(URL(string: "https://short-link.example/x")!).suggestedName == "photo.jpg")
    }

    @Test func anEmptySuccessfulResponseIsFetchFailed() async {
        for (name, chunks) in [("none", [Data]()), ("one-empty", [Data()])] {
            let url = "https://fetch-empty-\(name).example/x"
            StubURLProtocol.register(url, .respond(status: 200, headers: [:], chunks: chunks))
            let error = await failure { _ = try await fetcher().fetch(URL(string: url)!) }
            #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (empty response)", "\(name)")
        }
    }

    @Test func oneCallbackLargerThanTheCapIsRefusedWholesale() async {
        let url = "https://fetch-onebig.example/x"
        StubURLProtocol.register(url, .respond(status: 200, headers: [:], chunks: [Data(repeating: 1, count: 5_000)]))
        let error = await failure { _ = try await fetcher(maxBytes: 1_000).fetch(URL(string: url)!) }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (larger than 1000 bytes)")
    }

    // MARK: Idle timeout (apart from the total)

    @Test func aServerThatGoesQuietTripsTheIdleTimeoutLongBeforeTheTotal() async {
        for (name, behavior) in [
            ("silent", StubURLProtocol.Behavior.stall), ("midbody", .partialThenStall(chunk: Data([1, 2, 3]))),
        ] {
            let url = "https://fetch-idle-\(name).example/x"
            StubURLProtocol.register(url, behavior)
            let (error, elapsed) = await timed {
                await failure { _ = try await fetcher(requestTimeout: 0.3, totalTimeout: 60).fetch(URL(string: url)!) }
            }
            #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (timed out)", "\(name)")
            #expect(elapsed < 5, "\(name)")
        }
    }

    // MARK: Proxy

    @Test func theSessionNeverUsesAProxy() {
        let configuration = HTTPSFetcher.makeConfiguration(requestTimeout: 15, totalTimeout: 30, protocolClasses: [])
        #expect(configuration.connectionProxyDictionary != nil)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.httpCookieStorage == nil && configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 15 && configuration.timeoutIntervalForResource == 30)
    }

    // MARK: Peer address

    @Test func aResponseFromABlockedOrUnknownPeerNeverReachesTheCaller() async throws {
        let url = "https://peer-check.example/x"
        StubURLProtocol.respond(url, body: Data("private page".utf8))
        let refused: [(String, [String?])] = [
            ("loopback", ["127.0.0.1"]), ("private", ["10.0.0.8"]), ("missing", [nil]), ("none", []),
            ("redirect hop", ["93.184.216.34", "192.168.1.1"]), ("mapped", ["::ffff:127.0.0.1"]),
            ("v6 link-local zone", ["fe80::1%en0"]), ("nonsense", ["not an address"]),
            ("one missing", ["93.184.216.34", nil]),
        ]
        for (name, peers) in refused {
            let error = await failure { _ = try await fetcher(peers: { _ in peers }).fetch(URL(string: url)!) }
            #expect(error?.code == .invalidURL && error?.message == "Refusing to fetch a local or private network address", "\(name)")
        }
        // No peer information at all is as bad: the default reads it from the transfer, and a stubbed
        // protocol has none.
        let unknown = HTTPSFetcher(
            maxBytes: 1_000, requestTimeout: 5, totalTimeout: 5, maxRedirects: 5, protocolClasses: [StubURLProtocol.self],
            resolver: StubResolver(), gate: LookupGate(limit: 4))
        let noPeer = await failure { _ = try await unknown.fetch(URL(string: url)!) }
        #expect(noPeer?.code == .invalidURL)
        // Public peers, v4 and v6, pass.
        let ok = try await fetcher(peers: { _ in ["93.184.216.34", "2606:4700::1111"] }).fetch(URL(string: url)!)
        #expect(ok.data == Data("private page".utf8))
    }

    // MARK: Local network

    private static let refusal = "Refusing to fetch a local or private network address"

    @Test func localAndPrivateAddressLiteralsAndNamesAreRefused() {
        let blocked = [
            "https://localhost/x", "https://LOCALHOST./x", "https://app.localhost/x", "https://printer.local/x",
            "https://127.0.0.1/x", "https://127.255.255.254/x", "https://10.0.0.1/x", "https://172.16.0.1/x",
            "https://172.31.255.255/x", "https://192.168.1.1/x", "https://169.254.169.254/latest/meta-data",
            "https://100.64.0.1/x", "https://100.127.255.255/x", "https://0.0.0.0/x", "https://0.1.2.3/x",
            "https://224.0.0.1/x", "https://239.255.255.250/x", "https://255.255.255.255/x",
            "https://2130706433/x", "https://0x7f.1/x", "https://0177.0.0.1/x", "https://127.1/x",
            "https://[::1]/x", "https://[::]/x", "https://[fe80::1]/x", "https://[febf::1]/x", "https://[fc00::1]/x",
            "https://[fd12:3456::1]/x", "https://[ff02::1]/x", "https://[::ffff:127.0.0.1]/x",
            "https://[::ffff:7f00:1]/x", "https://[::ffff:10.1.2.3]/x", "https://[::127.0.0.1]/x",
            "https://[64:ff9b::7f00:1]/x", "https://[64:ff9b::a9fe:a9fe]/x", "https://[64:ff9b:1:c0a8:1:100::]/x",
            "https://[64:ff9b::808:808]/x", "https://[100::1]/x", "https://[3fff::1]/x", "https://[5f00::1]/x",
            "https://[::ffff:10.0.0.1]/x", "https://192.88.99.1/x",
        ]
        for raw in blocked {
            do {
                _ = try URLFetchPolicy.parse(raw)
                Issue.record("\(raw) was accepted")
            } catch {
                #expect(error.code == .invalidURL && error.message == Self.refusal, "\(raw): \(error)")
            }
        }
        for raw in [
            "https://example.com/x", "https://8.8.8.8/x", "https://172.15.0.1/x", "https://172.32.0.1/x",
            "https://100.63.0.1/x", "https://100.128.0.1/x", "https://169.253.0.1/x", "https://192.169.0.1/x",
            "https://223.255.255.255/x", "https://[2606:4700::1111]/x", "https://[::ffff:8.8.8.8]/x",
            "https://notlocalhost.example/x", "https://local.example/x",
            "https://[::ffff:8.8.8.8]/x", "https://[2a00:1450::1]/x",
        ] {
            #expect((try? URLFetchPolicy.parse(raw)) != nil, "\(raw)")
        }
    }

    @Test func aLocalLiteralIsRefusedByTheFetcherWithoutALookupOrARequest() async {
        let resolver = StubResolver()
        let error = await failure { _ = try await fetcher(resolver: resolver).fetch(URL(string: "https://127.0.0.1/x")!) }
        #expect(error?.code == .invalidURL && error?.message == Self.refusal)
        #expect(resolver.lookups.isEmpty && !StubURLProtocol.requested("https://127.0.0.1/x"))
    }

    @Test func aNameThatResolvesToALocalAddressIsRefusedBeforeAnyRequest() async {
        let url = "https://guard-rebind.example/x"
        StubURLProtocol.respond(url)
        let cases: [(String, [[UInt8]])] = [
            ("loopback", [[127, 0, 0, 1]]),
            ("private", [[10, 1, 2, 3]]),
            ("mixed", [StubResolver.publicAddress, [192, 168, 0, 5]]),
            ("mixed-last", [[192, 168, 0, 5], StubResolver.publicAddress]),
            ("v6 loopback", [Array(repeating: 0, count: 15) + [1]]),
            ("v6 unique-local", [[0xFD] + Array(repeating: 0, count: 15)]),
            ("v6 link-local", [[0xFE, 0x80] + Array(repeating: 0, count: 14)]),
            ("v6 mapped", [Array(repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1]]),
            ("v6 nat64", [[0x00, 0x64, 0xFF, 0x9B] + Array(repeating: 0, count: 8) + [169, 254, 169, 254]]),
            ("multicast", [[224, 0, 0, 251]]),
        ]
        for (name, answers) in cases {
            let resolver = StubResolver(["guard-rebind.example": answers])
            let error = await failure { _ = try await fetcher(resolver: resolver).fetch(URL(string: url)!) }
            #expect(error?.code == .invalidURL && error?.message == Self.refusal, "\(name)")
            #expect(resolver.lookups == ["guard-rebind.example"], "\(name)")
        }
        #expect(!StubURLProtocol.requested(url))
    }

    @Test func aNameThatResolvesToPublicAddressesIsFetched() async throws {
        let url = "https://guard-public.example/x.bin"
        StubURLProtocol.respond(url, body: Data([1]))
        let v6Public: [UInt8] = [0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 11) + [0x11]
        let mappedPublic: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF, 8, 8, 8, 8]
        let resolver = StubResolver(["guard-public.example": [[8, 8, 8, 8], v6Public, mappedPublic]])
        #expect(try await fetcher(resolver: resolver).fetch(URL(string: url)!).data == Data([1]))
    }

    @Test func unresolvableOrSlowLookupsFailTheFetch() async {
        let gone = await failure {
            _ = try await fetcher().fetch(URL(string: "https://unresolvable.example/x")!)
        }
        #expect(gone?.code == .fetchFailed)
        #expect(gone?.message == "Could not fetch the URL (could not resolve unresolvable.example)")
        let empty = await failure {
            _ = try await fetcher(resolver: StubResolver(["empty-answer.example": []]))
                .fetch(URL(string: "https://empty-answer.example/x")!)
        }
        #expect(empty?.code == .fetchFailed)
        let (slow, elapsed) = await timed {
            await failure {
                _ = try await fetcher(totalTimeout: 0.3, resolver: StubResolver(hang: .seconds(30)))
                    .fetch(URL(string: "https://slow-lookup.example/x")!)
            }
        }
        #expect(slow?.code == .fetchFailed && slow?.message == "Could not fetch the URL (timed out)")
        #expect(elapsed < 5)
    }

    @Test func aRedirectToAHostThatResolvesLocallyIsRefusedAndNotFollowed() async {
        StubURLProtocol.register(
            "https://guard-redir.example/go", .redirect(status: 302, to: "https://guard-inner.example/secret"))
        StubURLProtocol.respond("https://guard-inner.example/secret", body: Data("private page".utf8))
        let resolver = StubResolver(["guard-inner.example": [[127, 0, 0, 1]]])
        let error = await failure {
            _ = try await fetcher(resolver: resolver).fetch(URL(string: "https://guard-redir.example/go")!)
        }
        #expect(error?.code == .invalidURL && error?.message == Self.refusal)
        #expect(resolver.lookups == ["guard-redir.example", "guard-inner.example"])
        #expect(!StubURLProtocol.requested("https://guard-inner.example/secret"))
    }

    @Test func aRedirectToALocalLiteralOrNameIsRefusedAndNotFollowed() async {
        let targets = [
            "https://127.0.0.1/secret", "https://[::1]/secret", "https://169.254.169.254/latest",
            "https://thing.local/x", "https://localhost/x",
        ]
        for target in targets {
            StubURLProtocol.register("https://guard-redir2.example/go", .redirect(status: 302, to: target))
            StubURLProtocol.respond(target)
            let error = await failure { _ = try await fetcher().fetch(URL(string: "https://guard-redir2.example/go")!) }
            #expect(error?.code == .invalidURL && error?.message == Self.refusal, "\(target)")
            #expect(!StubURLProtocol.requested(target), "\(target)")
        }
    }

    @Test func aRedirectToAPublicHostIsLookedUpAndFollowed() async throws {
        StubURLProtocol.register(
            "https://guard-ok.example/go", .redirect(status: 302, to: "https://guard-ok2.example/file"))
        StubURLProtocol.respond("https://guard-ok2.example/file", body: Data([9]))
        let resolver = StubResolver()
        #expect(try await fetcher(resolver: resolver).fetch(URL(string: "https://guard-ok.example/go")!).data == Data([9]))
        #expect(resolver.lookups == ["guard-ok.example", "guard-ok2.example"])
    }

    // MARK: Scheduling (I3)

    /// The fetch's time limits are wall-clock timers; the work they bound must not wait for a
    /// cooperative-pool thread. At the start of a parallel test run (or under any other backlog of
    /// synchronous work) that wait alone used to exceed the limits.
    @Test func lookupsRunOnTheOffPoolExecutorNotTheSharedPool() async throws {
        StubURLProtocol.register("https://sched-a.example/go", .redirect(status: 302, to: "https://sched-b.example/f"))
        StubURLProtocol.respond("https://sched-b.example/f", body: Data([5]))
        let resolver = StubResolver()
        #expect(try await fetcher(resolver: resolver).fetch(URL(string: "https://sched-a.example/go")!).data == Data([5]))
        #expect(resolver.lookups == ["sched-a.example", "sched-b.example"])
        #expect(resolver.lookupsOffThePool == [true, true])
    }

    // MARK: Size

    @Test func aBodyOverTheCapFailsAndTheTransferIsCutOff() async throws {
        let url = "https://fetch-big.example/endless.bin"
        StubURLProtocol.register(url, .endless(chunk: Data(repeating: 7, count: 1_000)))
        let error = await failure { _ = try await fetcher(maxBytes: 10_000).fetch(URL(string: url)!) }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (larger than 10000 bytes)")
        // Aborted as the cap was crossed: the stub was told to stop, and sent only a few of its 20 000 chunks.
        let stopped = try await withTaskExecutorPreference(OffPoolExecutor.shared) {
            try await waitUntilAsync(seconds: 5) { StubURLProtocol.wasStopped(url) }
        }
        #expect(stopped)
        #expect(StubURLProtocol.sent(url) < 2_000)
    }

    @Test func aDeclaredLengthOverTheCapFailsBeforeAnyBody() async {
        let url = "https://fetch-declared.example/x"
        StubURLProtocol.register(
            url, .respond(status: 200, headers: ["Content-Length": "50000"], chunks: [Data("tiny".utf8)]))
        let error = await failure { _ = try await fetcher(maxBytes: 1_000).fetch(URL(string: url)!) }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (larger than 1000 bytes)")
    }

    @Test func aBodyExactlyAtTheCapPasses() async throws {
        let url = "https://fetch-exact.example/x"
        StubURLProtocol.respond(url, body: Data(repeating: 1, count: 1_000))
        #expect(try await fetcher(maxBytes: 1_000).fetch(URL(string: url)!).data.count == 1_000)
    }

    // MARK: Time

    @Test func aServerThatNeverAnswersTimesOut() async {
        let url = "https://fetch-stall.example/x"
        StubURLProtocol.register(url, .stall)
        let (error, elapsed) = await timed { await failure { _ = try await fetcher(totalTimeout: 0.3).fetch(URL(string: url)!) } }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (timed out)")
        #expect(elapsed < 5)
    }

    @Test func cancellingTheTaskStopsTheFetch() async throws {
        let url = "https://fetch-cancel.example/x"
        StubURLProtocol.register(url, .stall)
        let fetcher = fetcher(totalTimeout: 20)
        let (requested, elapsed, stopped) = try await withTaskExecutorPreference(OffPoolExecutor.shared) {
            let task = Task(executorPreference: OffPoolExecutor.shared) { try await fetcher.fetch(URL(string: url)!) }
            let requested = try await waitUntilAsync(seconds: 5) { StubURLProtocol.requested(url) }
            task.cancel()
            let started = Date()
            _ = await task.result
            let elapsed = Date().timeIntervalSince(started)
            return (requested, elapsed, try await waitUntilAsync(seconds: 5) { StubURLProtocol.wasStopped(url) })
        }
        #expect(requested)
        #expect(elapsed < 5)
        #expect(stopped)
    }

    // MARK: Cancellation and the fetch's lifetime (residual round, item 2)

    @Test func cancellingDuringTheFirstLookupReturnsPromptlyAndFreesTheSlot() async throws {
        let gate = LookupGate(limit: 1)
        let resolver = StubResolver(hang: .seconds(30))
        let fetcher = fetcher(totalTimeout: 20, resolver: resolver, gate: gate)
        let url = URL(string: "https://cancel-dns.example/x")!
        let (asked, elapsed, wasCancellation, freed) = try await withTaskExecutorPreference(OffPoolExecutor.shared) {
            let task = Task(executorPreference: OffPoolExecutor.shared) { try await fetcher.fetch(url) }
            let asked = try await waitUntilAsync(seconds: 5) { resolver.lookups.contains("cancel-dns.example") }
            task.cancel()
            let started = Date()
            let result = await task.result
            let elapsed = Date().timeIntervalSince(started)
            var wasCancellation = false
            if case .failure(let error) = result { wasCancellation = error is CancellationError }
            let freed = try await waitUntilAsync(seconds: 2) { gate.acquire() }
            return (asked, elapsed, wasCancellation, freed)
        }
        if freed { gate.release() }
        #expect(asked && elapsed < 2, "\(elapsed) s")
        #expect(wasCancellation)
        #expect(freed, "the cancelled lookup kept its gate slot")
        #expect(resolver.cancelled == ["cancel-dns.example"])
        #expect(!StubURLProtocol.requested(url.absoluteString))
    }

    /// The total time runs out while a redirect target is being looked up: the fetch ends at once,
    /// the lookup is cancelled, and the redirect is never followed later.
    @Test func aTimeoutDuringRedirectVerificationEndsTheFetchAndNeverFollowsLater() async throws {
        StubURLProtocol.register(
            "https://redir-hang.example/go", .redirect(status: 302, to: "https://redir-hang-target.example/f"))
        StubURLProtocol.respond("https://redir-hang-target.example/f", body: Data([1]))
        let resolver = StubResolver(hang: .seconds(30), hangOnly: ["redir-hang-target.example"])
        let (error, elapsed) = await timed {
            await failure {
                _ = try await fetcher(totalTimeout: 0.5, resolver: resolver).fetch(URL(string: "https://redir-hang.example/go")!)
            }
        }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (timed out)")
        #expect(elapsed < 3, "\(elapsed) s")
        let cancelled = try await withTaskExecutorPreference(OffPoolExecutor.shared) {
            try await waitUntilAsync(seconds: 3) { resolver.cancelled == ["redir-hang-target.example"] }
        }
        #expect(cancelled, "the redirect's lookup outlived the fetch: \(resolver.cancelled)")
        #expect(!StubURLProtocol.requested("https://redir-hang-target.example/f"))
    }

    /// The fetch's deadline lives on the monotonic clock its timers use (uptime), injected here: a
    /// clock that jumps 60 s right after the deadline was set ends a 30 s fetch at once, before any
    /// lookup or request. A wall-clock deadline would not see it (last round, item 1).
    @Test func theDeadlineIsMeasuredOnTheMonotonicFetchClock() async {
        let url = "https://clock-jump.example/x"
        StubURLProtocol.respond(url, body: Data([1]))
        let calls = Mutex(0)
        let start = DispatchTime.now().uptimeNanoseconds
        let jumping: @Sendable () -> UInt64 = {
            calls.withLock { count in
                defer { count += 1 }
                return count == 0 ? start : start + 60_000_000_000
            }
        }
        let resolver = StubResolver()
        let fetcher = HTTPSFetcher(
            maxBytes: 1_000, requestTimeout: 5, totalTimeout: 30, maxRedirects: 5,
            protocolClasses: [StubURLProtocol.self], resolver: resolver, gate: LookupGate(limit: 4),
            peerAddresses: publicPeer, now: jumping)
        let (error, elapsed) = await timed { await failure { _ = try await fetcher.fetch(URL(string: url)!) } }
        #expect(error?.code == .fetchFailed && error?.message == "Could not fetch the URL (timed out)")
        #expect(elapsed < 5)
        #expect(resolver.lookups.isEmpty && !StubURLProtocol.requested(url))
    }

    @Test func aRedirectDecisionCompletesOnceAndNeverAfterTheFetchEnded() async throws {
        let request = URLRequest(url: URL(string: "https://decision.example/next")!)
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var completions: [URL?] = []
            var failures = 0
            var checkCancelled = false
        }
        func decision(_ calls: Calls) -> RedirectDecision {
            RedirectDecision { next in calls.lock.withLock { calls.completions.append(next?.url) } }
        }
        func hangingCheck(_ calls: Calls) -> @Sendable () async throws -> Void {
            {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    calls.lock.withLock { calls.checkCancelled = true }
                    throw error
                }
            }
        }
        try await withTaskExecutorPreference(OffPoolExecutor.shared) {
            // Abandoned while its check hangs: refused at once, exactly once; the check is cancelled
            // and its failure reports nothing.
            let hung = Calls()
            let a = decision(hung)
            a.start(request, check: hangingCheck(hung), failed: { _ in hung.lock.withLock { hung.failures += 1 } })
            a.abandon()
            #expect(try await waitUntilAsync(seconds: 3) { hung.lock.withLock { hung.checkCancelled } })
            try await Task.sleep(for: .milliseconds(100))
            a.abandon()
            #expect(hung.lock.withLock { hung.completions } == [nil] && hung.lock.withLock { hung.failures } == 0)

            // A passing check follows once; ending the fetch afterwards adds nothing.
            let passed = Calls()
            let b = decision(passed)
            b.start(request, check: {}, failed: { _ in passed.lock.withLock { passed.failures += 1 } })
            #expect(try await waitUntilAsync(seconds: 3) { !passed.lock.withLock { passed.completions }.isEmpty })
            b.abandon()
            #expect(passed.lock.withLock { passed.completions } == [request.url])

            // A failing check reports once and refuses once.
            let refused = Calls()
            let c = decision(refused)
            c.start(
                request, check: { throw URLFetchPolicy.fetchFailed("no") },
                failed: { _ in refused.lock.withLock { refused.failures += 1 } })
            #expect(try await waitUntilAsync(seconds: 3) { !refused.lock.withLock { refused.completions }.isEmpty })
            c.abandon()
            #expect(refused.lock.withLock { refused.completions } == [nil] && refused.lock.withLock { refused.failures } == 1)

            // Abandoned before its check started: refused once, the check is cancelled at once.
            let early = Calls()
            let d = decision(early)
            d.abandon()
            d.start(request, check: hangingCheck(early), failed: { _ in early.lock.withLock { early.failures += 1 } })
            #expect(try await waitUntilAsync(seconds: 3) { early.lock.withLock { early.checkCancelled } })
            #expect(early.lock.withLock { early.completions } == [nil] && early.lock.withLock { early.failures } == 0)
        }
    }

    // MARK: Names

    @Test func attachmentNamesAreSafeLastPathComponents() {
        #expect(AttachmentName.clean("photo.jpg") == "photo.jpg")
        #expect(AttachmentName.clean("../../etc/passwd") == "passwd")
        #expect(AttachmentName.clean(#"..\..\windows\system.ini"#) == "system.ini")
        #expect(AttachmentName.clean(".bashrc") == "bashrc")
        #expect(AttachmentName.clean("a\u{0}b\nc.txt") == "abc.txt")
        #expect(AttachmentName.clean("..") == nil)
        #expect(AttachmentName.clean(".") == nil)
        #expect(AttachmentName.clean("") == nil)
        #expect(AttachmentName.clean("   ") == nil)
        #expect(AttachmentName.clean("/") == nil)
        #expect(AttachmentName.clean(nil) == nil)
        let long = String(repeating: "x", count: 400) + ".png"
        let cleaned = AttachmentName.clean(long)
        #expect(cleaned?.utf8.count ?? 999 <= 200 && cleaned?.hasSuffix(".png") == true)
    }

    @Test func contentDispositionNamesAreRead() {
        func name(_ header: String?) -> String? { AttachmentName.fromContentDisposition(header) }
        #expect(name(#"attachment; filename="a b.pdf""#) == "a b.pdf")
        #expect(name("attachment; filename=plain.txt") == "plain.txt")
        #expect(name(#"inline; filename="semi;colon.txt""#) == "semi;colon.txt")
        #expect(name("attachment; filename=\"fallback.txt\"; filename*=UTF-8''na%C3%AFve%20caf%C3%A9.txt") == "na\u{EF}ve caf\u{E9}.txt")
        #expect(name("attachment; filename*=iso-8859-1''caf%E9.txt") == "caf\u{E9}.txt")
        #expect(name(#"attachment; filename="../../etc/passwd""#) == "passwd")
        #expect(name(#"attachment; filename="..""#) == nil)
        #expect(name("attachment") == nil)
        #expect(name(nil) == nil)
    }

    @Test func aURLsLastPathComponentIsDecoded() {
        #expect(AttachmentName.fromPath(of: URL(string: "https://x.example/a/b%20c.png?x=1#f")!) == "b c.png")
        #expect(AttachmentName.fromPath(of: URL(string: "https://x.example/a/..%2F..%2Fsecret.txt")!) == "secret.txt")
        #expect(AttachmentName.fromPath(of: URL(string: "https://x.example/")!) == nil)
        #expect(AttachmentName.fromPath(of: URL(string: "https://x.example")!) == nil)
        #expect(AttachmentName.fromPath(of: URL(string: "https://x.example/.hidden")!) == "hidden")
    }
}

/// `work` and how long it took, both on the fetch's executor: a test of a fetch's timing must not
/// measure its own wait for a cooperative-pool thread (I3).
func timed<T: Sendable>(_ work: () async -> T) async -> (T, TimeInterval) {
    await withTaskExecutorPreference(OffPoolExecutor.shared) {
        let started = Date()
        let value = await work()
        return (value, Date().timeIntervalSince(started))
    }
}

/// Polls an async-safe condition; the test thread stays free.
func waitUntilAsync(seconds: Double, _ condition: @Sendable () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
