// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotes

/// REL-R52 … REL-R59: the update check decides from one static JSON file. A fake fetcher stands in for the
/// network, so no test here makes a request.
@Suite struct UpdateCheckerTests {
    private struct FakeFetcher: UpdateFetching {
        let result: Result<Data, any Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private static func json(
        version: String = "1.2.0", url: String = "https://theonotes.app/download", notes: String? = nil
    ) -> Data {
        var fields = ["\"version\": \"\(version)\"", "\"build\": 4", "\"url\": \"\(url)\""]
        if let notes { fields.append("\"notes\": \"\(notes)\"") }
        return Data("{ \(fields.joined(separator: ", ")) }".utf8)
    }

    private func check(installed: String? = "1.0.0", _ result: Result<Data, any Error>) async -> UpdateOutcome {
        await UpdateChecker(fetcher: FakeFetcher(result: result)).check(installedVersion: installed)
    }

    @Test func aNewerVersionIsOfferedWithTheDownloadPage() async {
        let outcome = await check(.success(Self.json(version: "1.2.0", notes: "Faster search")))
        #expect(
            outcome
                == .updateAvailable(
                    version: "1.2.0", installed: "1.0.0", downloadPage: URL(string: "https://theonotes.app/download")!,
                    notes: "Faster search"))
    }

    @Test func theSameVersionIsUpToDate() async {
        #expect(await check(.success(Self.json(version: "1.0.0"))) == .upToDate(installed: "1.0.0"))
    }

    @Test func missingTrailingZerosDoNotMakeAnUpdate() async {
        #expect(await check(installed: "1.0", .success(Self.json(version: "1.0.0"))) == .upToDate(installed: "1.0"))
    }

    @Test func aDowngradeIsNeverOffered() async {
        // The file names an older version than the one installed (a stale or tampered file): up to date.
        #expect(await check(installed: "1.3.0", .success(Self.json(version: "1.2.9"))) == .upToDate(installed: "1.3.0"))
        #expect(await check(installed: "1.10.0", .success(Self.json(version: "1.9.0"))) == .upToDate(installed: "1.10.0"))
    }

    @Test func versionsCompareNumberwiseNotAsText() async {
        let outcome = await check(installed: "1.9.0", .success(Self.json(version: "1.10.0")))
        guard case .updateAvailable(let version, _, _, _) = outcome else {
            Issue.record("1.10.0 should be newer than 1.9.0, got \(outcome)")
            return
        }
        #expect(version == "1.10.0")
    }

    @Test(arguments: [
        "", "not json", "[]", "{}", "{\"version\": \"1.2.0\"}", "{\"url\": \"https://theonotes.app/download\"}",
        "{\"version\": 3, \"url\": \"https://theonotes.app/download\"}",
        "{\"version\": \"one.two\", \"url\": \"https://theonotes.app/download\"}",
        "{\"version\": \"1.2.0-beta\", \"url\": \"https://theonotes.app/download\"}",
        "{\"version\": \"1..2\", \"url\": \"https://theonotes.app/download\"}",
        "{\"version\": \"\", \"url\": \"https://theonotes.app/download\"}",
        "{\"version\": \"1.2.0\", \"url\": \"\"}",
    ])
    func malformedJSONIsAnUnreadableAnswer(body: String) async {
        #expect(await check(.success(Data(body.utf8))) == .couldNotCheck(.unreadableAnswer))
    }

    @Test(arguments: [
        "http://theonotes.app/download", "https://example.com/download", "https://theonotes.app.evil.com/download",
        "https://evil.com/theonotes.app", "https://user:pw" + "@theonotes.app/download", "javascript:alert(1)",
        "file:///Applications", "theonotes://x-callback-url/open", "https://theonotes.app:8443/download",
    ])
    func aDownloadAddressOutsideOurSiteIsRefused(url: String) async {
        #expect(await check(.success(Self.json(url: url))) == .couldNotCheck(.unreadableAnswer))
    }

    @Test func aSubdomainOfOurSiteIsAccepted() async {
        let outcome = await check(.success(Self.json(url: "https://www.theonotes.app/download")))
        guard case .updateAvailable(_, _, let page, _) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(page.host == "www.theonotes.app")
    }

    @Test(arguments: [URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.cannotFindHost)])
    func aNetworkErrorMeansTheServerWasNotReached(error: URLError) async {
        #expect(await check(.failure(error)) == .couldNotCheck(.unreachable))
    }

    @Test func aBadServerAnswerIsUnreadableNotUnreachable() async {
        #expect(await check(.failure(UpdateFetchError.unexpectedStatus(503))) == .couldNotCheck(.unreadableAnswer))
        #expect(await check(.failure(UpdateFetchError.tooLarge)) == .couldNotCheck(.unreadableAnswer))
    }

    @Test(arguments: [nil, "", "$(MARKETING_VERSION)", "dev"] as [String?])
    func anInstalledVersionThatCannotBeReadIsReported(installed: String?) async {
        #expect(await check(installed: installed, .success(Self.json())) == .couldNotCheck(.installedVersionUnknown))
    }

    @Test func overlongNotesAreCut() async {
        let outcome = await check(.success(Self.json(notes: String(repeating: "x", count: 5_000))))
        guard case .updateAvailable(_, _, _, let notes) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect((notes?.count ?? 0) <= UpdateChecker.maxNotesLength)
    }
}

/// The request itself (REL-R54): a plain GET with nothing of ours added, in a session that keeps no cookies,
/// cache or credentials. A URLProtocol stub stands in for the network.
@Suite(.serialized) struct UpdateRequestTests {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [URLRequest] = []
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data("{}".utf8)
        nonisolated(unsafe) static var redirectTo: URL?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen.append(request)
            if let target = Self.redirectTo, request.url != target {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                // A refused redirect leaves the redirect answer itself as the result, as the real stack does.
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func reset() {
            seen = []
            status = 200
            body = Data("{}".utf8)
            redirectTo = nil
        }
    }

    private let endpoint = URL(string: "https://theonotes.app/latest.json")!

    @Test func theRequestIsAPlainGetWithNoHeadersOfOurs() async throws {
        Stub.reset()
        Stub.body = Data("{\"ok\":true}".utf8)
        let data = try await URLSessionUpdateFetcher(protocolClasses: [Stub.self]).fetch(endpoint)
        #expect(data == Stub.body)
        let request = try #require(Stub.seen.first)
        #expect(Stub.seen.count == 1)
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect((request.allHTTPHeaderFields ?? [:]).isEmpty)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 10)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func theSessionKeepsNothingBetweenChecks() {
        let configuration = URLSessionUpdateFetcher.makeConfiguration(protocolClasses: [])
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpAdditionalHeaders == nil)
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func aNon200AnswerIsAnError() async {
        Stub.reset()
        Stub.status = 404
        await #expect(throws: UpdateFetchError.unexpectedStatus(404)) {
            try await URLSessionUpdateFetcher(protocolClasses: [Stub.self]).fetch(endpoint)
        }
    }

    @Test func anOversizedAnswerIsRefused() async {
        Stub.reset()
        Stub.body = Data(count: URLSessionUpdateFetcher.maxBytes + 1)
        await #expect(throws: UpdateFetchError.tooLarge) {
            try await URLSessionUpdateFetcher(protocolClasses: [Stub.self]).fetch(endpoint)
        }
    }

    @Test func aRedirectToAnotherSiteIsNotFollowed() async {
        Stub.reset()
        Stub.redirectTo = URL(string: "https://example.com/latest.json")
        await #expect(throws: UpdateFetchError.unexpectedStatus(302)) {
            try await URLSessionUpdateFetcher(protocolClasses: [Stub.self]).fetch(endpoint)
        }
        #expect(Stub.seen.map(\.url?.host) == ["theonotes.app"])
    }

    @Test func theRedirectRule() {
        let from = URL(string: "https://theonotes.app/latest.json")!
        #expect(UpdateRedirectRule.allows(from: from, to: URL(string: "https://theonotes.app/latest/")!))
        #expect(!UpdateRedirectRule.allows(from: from, to: URL(string: "https://example.com/latest.json")!))
        #expect(!UpdateRedirectRule.allows(from: from, to: URL(string: "http://theonotes.app/latest.json")!))
        #expect(!UpdateRedirectRule.allows(from: from, to: URL(string: "https://www.theonotes.app/latest.json")!))
    }
}

/// What the person is told (REL-R56) and what the menu item does with the answer.
@MainActor
@Suite struct UpdatesControllerTests {
    private final class Box: @unchecked Sendable {
        var shown: [UpdateAlertContent] = []
        var opened: [URL] = []
        var chooseDownload = false
    }

    private struct Fixed: UpdateFetching {
        let result: Result<Data, any Error>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    private func controller(_ result: Result<Data, any Error>, installed: String? = "1.0.0", box: Box)
        -> UpdatesController
    {
        UpdatesController(
            checker: UpdateChecker(fetcher: Fixed(result: result)), installedVersion: installed,
            prompt: { content in
                box.shown.append(content)
                return box.chooseDownload
            }, openURL: { box.opened.append($0) })
    }

    private let newer = Data(#"{"version":"2.0.0","build":9,"url":"https://theonotes.app/download"}"#.utf8)

    @Test func upToDateSaysSoAndOffersNoDownload() async throws {
        let box = Box()
        let c = controller(.success(Data(#"{"version":"1.0.0","url":"https://theonotes.app/download"}"#.utf8)), box: box)
        await c.checkForUpdates()
        let content = try #require(box.shown.first)
        #expect(content.title == "You\u{2019}re up to date")
        #expect(content.message.contains("1.0.0"))
        #expect(content.downloadPage == nil)
        #expect(box.opened.isEmpty)
    }

    @Test func aNewVersionOffersTheDownloadPageAndOpensItOnlyWhenChosen() async {
        let box = Box()
        await controller(.success(newer), box: box).checkForUpdates()
        #expect(box.shown.first?.title == "Version 2.0.0 is available")
        #expect(box.shown.first?.message.contains("1.0.0") == true)
        #expect(box.shown.first?.downloadPage == URL(string: "https://theonotes.app/download"))
        #expect(box.opened.isEmpty, "declining must open nothing")

        box.chooseDownload = true
        await controller(.success(newer), box: box).checkForUpdates()
        #expect(box.opened == [URL(string: "https://theonotes.app/download")!])
    }

    @Test func aFailureIsExplainedInPlainWordsAndOpensNothing() async {
        let box = Box()
        box.chooseDownload = true
        await controller(.failure(URLError(.notConnectedToInternet)), box: box).checkForUpdates()
        let content = box.shown.first
        #expect(content?.title == "Couldn\u{2019}t check for updates")
        #expect(content?.message.contains("theonotes.app") == true)
        #expect(content?.downloadPage == nil)
        #expect(box.opened.isEmpty)
    }

    @Test func eachFailureHasItsOwnWords() {
        let texts = [UpdateFailure.unreachable, .unreadableAnswer, .installedVersionUnknown].map {
            UpdateAlertContent(for: .couldNotCheck($0)).message
        }
        #expect(Set(texts).count == 3)
    }

    @Test func theCopyNeverMentionsTheForbiddenWord() {
        let page = URL(string: "https://theonotes.app/download")!
        let outcomes: [UpdateOutcome] = [
            .upToDate(installed: "1.0.0"),
            .updateAvailable(version: "2.0.0", installed: "1.0.0", downloadPage: page, notes: nil),
            .couldNotCheck(.unreachable), .couldNotCheck(.unreadableAnswer), .couldNotCheck(.installedVersionUnknown),
        ]
        for outcome in outcomes {
            let content = UpdateAlertContent(for: outcome)
            let text = (content.title + content.message).lowercased()
            #expect(!text.contains("adhd") && !text.contains("adhs"))
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        func open() {
            lock.lock()
            opened = true
            lock.unlock()
        }
        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }
    }

    private struct GatedFetcher: UpdateFetching {
        let gate: Gate
        let data: Data
        func fetch(_ url: URL) async throws -> Data {
            while !gate.isOpen { await Task.yield() }
            return data
        }
    }

    @Test func aSecondClickWhileACheckRunsDoesNothing() async {
        let box = Box()
        let gate = Gate()
        let c = UpdatesController(
            checker: UpdateChecker(fetcher: GatedFetcher(gate: gate, data: newer)), installedVersion: "1.0.0",
            prompt: { content in
                box.shown.append(content)
                return false
            }, openURL: { box.opened.append($0) })
        let first = Task { await c.checkForUpdates() }
        while !c.isChecking { await Task.yield() }
        await c.checkForUpdates()
        gate.open()
        await first.value
        #expect(box.shown.count == 1)
        #expect(!c.isChecking)
    }
}
