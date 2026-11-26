// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import os
import PDFKit
import WebKit

let rendererLogger = Logger(subsystem: "com.truebrewbirdie.baerchen", category: "renderer")

enum RenderError: Error, Equatable {
    /// The export page did not load, or does not offer `window.baerchenExport`.
    case pageUnavailable
    /// The page's web content process ended during the call; the page is being reloaded.
    case pageCrashed
    /// The page answered with something that is not a `RenderResult`.
    case invalidResult
    case printFailed(String)
    /// A page load, render or PDF job did not finish within its `NoteRenderer.Timeouts` bound.
    case timedOut
    /// The calling task was cancelled.
    case cancelled
}

/// Renders notes with the export page (`baerchen-asset://editor/export.html`, M8 Task 10) in one
/// hidden `WKWebView` inside an offscreen borderless window, and turns the rendered page into a
/// paginated PDF (WebKit's print operation saved to a file, backgrounds printed, then a PDFKit
/// outline) or prints it.
///
/// Calls run one at a time: the page shows one note, and a PDF or a print job is made from what
/// it shows; a call keeps the turn until its job has ended. Every wait on WebKit is bounded
/// (`Timeouts`) and ends when the calling task is cancelled; the page is then reloaded or stopped
/// so the next call starts clean. If the web content process ends, the page is reloaded
/// and the call in flight fails with `RenderError.pageCrashed`.
@MainActor
final class NoteRenderer: NSObject, WKNavigationDelegate {
    static let pageURL = URL(string: "\(AssetSchemeHandler.scheme)://\(AssetSchemeHandler.host)/export.html")!
    static let defaultRenderScript = "return await window.baerchenExport.render(request)"

    /// Upper bounds of the waits on WebKit. The interactive print panel has none: it waits for the user.
    struct Timeouts {
        /// Navigation plus the page's renderer becoming available.
        var pageLoad = Duration.seconds(20)
        /// One `render` call in the page (MathJax and Mermaid included).
        var render = Duration.seconds(120)
        /// WebKit's print operation writing the PDF.
        var pdf = Duration.seconds(180)
    }

    let webView: WKWebView
    private let window: NSWindow
    private let timeouts: Timeouts
    /// The script that renders `request` in the page (tests replace it with one that never settles).
    var renderScript = NoteRenderer.defaultRenderScript

    private enum PageState {
        case idle, loading, ready
    }

    private var pageState = PageState.idle
    /// The load in progress or done; callbacks of any other navigation are ignored.
    private(set) var currentNavigation: WKNavigation?
    /// Number of times the page was (re)loaded (tests).
    private(set) var pageLoads = 0
    /// Whether a call holds the renderer (tests).
    private(set) var isBusy = false
    private var waitingForTurn: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
    /// Steps that wait for WebKit (page load, script, print job), by id.
    private var pending: [UUID: Step] = [:]
    private var pageWaiters: [UUID] = []
    private var operations: [ObjectIdentifier: UUID] = [:]

    /// Calls waiting for WebKit right now (tests).
    var waitingSteps: Int { pending.count }

    /// What a WebKit callback answered.
    private enum Answer: Sendable {
        case done
        /// A script's result as JSON.
        case json(Data)
        /// Whether a print operation completed.
        case completed(Bool)
    }

    /// What to do with the page when a step is given up (timeout or cancellation).
    private enum Recovery {
        /// Stop a load that timed out; the next call loads the page again.
        case stopLoading
        /// The page may be stuck (its own render queue, a print job): load it again now.
        case reloadPage
    }

    /// One WebKit callback the current call waits for; it resumes once.
    private final class Step {
        private var continuation: CheckedContinuation<Answer, any Error>?
        let recovery: Recovery
        var timer: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Answer, any Error>, recovery: Recovery) {
            self.continuation = continuation
            self.recovery = recovery
        }

        func finish(_ result: Result<Answer, any Error>) {
            timer?.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    /// Only the paths are kept, so the environment that owns this renderer is not retained.
    init(environment: AppEnvironment, timeouts: Timeouts = Timeouts()) {
        self.timeouts = timeouts
        let attachments = AttachmentStore(paths: environment.paths, database: environment.database)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(attachments: attachments, thumbnails: Thumbnails(paths: environment.paths)),
            forURLScheme: AssetSchemeHandler.scheme)
        // The theme's background, code blocks, callouts and highlights are part of the printed look.
        configuration.preferences.shouldPrintBackgrounds = true
        configuration.websiteDataStore = .nonPersistent()
        let frame = NSRect(x: 0, y: 0, width: 816, height: 1056)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(
            contentRect: frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: [.borderless], backing: .buffered,
            defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.ignoresMouseEvents = true
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    isolated deinit {
        window.close()
    }

    // MARK: - Public

    /// Renders `request` in the page and returns its HTML and headings.
    func render(_ request: RenderRequest) async throws -> RenderResult {
        try await exclusively { try await self.show(request) }
    }

    /// Renders `request` and writes it to `url` as a paginated PDF with an outline; returns the page count.
    func writePDF(_ request: RenderRequest, to url: URL, mayProceed: @MainActor () -> Bool = { true }) async throws -> Int {
        try await exclusively {
            let result = try await self.show(request)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("TheoNotesPDF-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let printed = folder.appendingPathComponent("print.pdf")
            let operation = self.webView.printOperation(with: Self.savingInfo(to: printed))
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            guard try await self.run(operation, timeout: self.timeouts.pdf),
                  let printedDocument = PDFDocument(url: printed), printedDocument.pageCount > 0 else {
                throw RenderError.printFailed("WebKit wrote no PDF")
            }
            let document = Self.rebuilt(printedDocument)
            PDFOutline.add(result.headings, to: document)
            // App Lock: asked again right before the file is written.
            guard mayProceed() else { throw RenderError.cancelled }
            guard document.write(to: url) else { throw RenderError.printFailed("The PDF could not be written") }
            return document.pageCount
        }
    }

    /// File ▸ Print…: renders `request` and runs the print panel as a sheet on `window`. The
    /// renderer keeps the turn until the panel is done, so no other call can change the page under
    /// it, and has no time bound for it. Returns whether something was printed. There is no public
    /// way to get the print operation itself: one run after the turn ended could print another
    /// note.
    func print(_ request: RenderRequest, for window: NSWindow, mayProceed: @MainActor () -> Bool = { true }) async throws -> Bool {
        try await exclusively {
            _ = try await self.show(request)
            // App Lock: checked right before the print panel would open.
            guard mayProceed() else { throw RenderError.cancelled }
            let operation = self.webView.printOperation(with: NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo())
            operation.jobTitle = request.title.isEmpty ? "Untitled" : request.title
            return try await self.run(operation, sheetOn: window, timeout: nil)
        }
    }

    // MARK: - Turns

    private func exclusively<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        if isBusy { try await waitForTurn() }
        isBusy = true
        defer {
            if waitingForTurn.isEmpty { isBusy = false } else { waitingForTurn.removeFirst().continuation.resume() }
        }
        if Task.isCancelled { throw RenderError.cancelled }
        return try await body()
    }

    /// Waits until the call holding the turn hands it over; a cancelled waiter leaves the queue.
    private func waitForTurn() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waitingForTurn.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leaveQueue(id) }
        }
    }

    private func leaveQueue(_ id: UUID) {
        guard let index = waitingForTurn.firstIndex(where: { $0.id == id }) else { return }
        waitingForTurn.remove(at: index).continuation.resume(throwing: RenderError.cancelled)
    }

    /// Waits for one WebKit callback, at most `timeout`, and gives up when the task is cancelled;
    /// `start` gets the step's id to finish.
    private func step(timeout: Duration?, recovery: Recovery, _ start: (UUID) -> Void) async throws -> Answer {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let step = Step(continuation, recovery: recovery)
                pending[id] = step
                if let timeout {
                    step.timer = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self?.abandon(id, .timedOut)
                    }
                }
                start(id)
                if Task.isCancelled { abandon(id, .cancelled) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.abandon(id, .cancelled) }
        }
    }

    private func finish(_ id: UUID, _ result: Result<Answer, any Error>) {
        pending.removeValue(forKey: id)?.finish(result)
    }

    /// Gives up step `id` with `error` and puts the page into a state the next call can use.
    private func abandon(_ id: UUID, _ error: RenderError) {
        guard let step = pending.removeValue(forKey: id) else { return }
        rendererLogger.error("renderer gave up a wait: \(String(describing: error), privacy: .public)")
        pageWaiters.removeAll { $0 == id }
        operations = operations.filter { $0.value != id }
        step.finish(.failure(error))
        switch step.recovery {
        case .stopLoading:
            // A cancelled caller leaves the load running for the next call.
            guard error == .timedOut else { return }
            webView.stopLoading()
            currentNavigation = nil
            pageState = .idle
        case .reloadPage:
            loadPage()
        }
    }

    // MARK: - Page

    private func loadPage() {
        pageState = .loading
        pageLoads += 1
        currentNavigation = webView.load(URLRequest(url: Self.pageURL))
    }

    private func ensurePage() async throws {
        if pageState == .ready { return }
        if pageState == .idle { loadPage() }
        _ = try await step(timeout: timeouts.pageLoad, recovery: .stopLoading) { pageWaiters.append($0) }
    }

    private func pageFinished(_ result: Result<Answer, any Error>) {
        let waiters = pageWaiters
        pageWaiters = []
        waiters.forEach { finish($0, result) }
    }

    /// Renders `request` in the page (loading it first if needed).
    private func show(_ request: RenderRequest) async throws -> RenderResult {
        try await ensurePage()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let answer = try await step(timeout: timeouts.render, recovery: .reloadPage) { id in
            webView.callAsyncJavaScript(renderScript, arguments: ["request": json], in: nil, in: .page) { [weak self] result in
                self?.finish(id, result.map { value in
                    guard JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value) else { return .done }
                    return .json(data)
                })
            }
        }
        guard case .json(let data) = answer, let result = try? JSONDecoder().decode(RenderResult.self, from: data) else {
            throw RenderError.invalidResult
        }
        return result
    }

    // MARK: - Printing

    /// The pages of `printed` moved into a new `PDFDocument`, with its attributes. PDFKit (macOS 27)
    /// writes no outline for a document it read from a file or data, only for one it built
    ///. The moved pages keep their link annotations, but an in-document destination does
    /// not reliably follow its page (observed: sometimes page 1 instead of 3), so each one is set
    /// again by page index.
    static func rebuilt(_ printed: PDFDocument) -> PDFDocument {
        struct Target {
            var page: Int
            var annotation: Int
            var destinationPage: Int
            var point: CGPoint
            var isAction: Bool
        }
        var targets: [Target] = []
        for index in 0..<printed.pageCount {
            guard let page = printed.page(at: index) else { continue }
            for (n, annotation) in page.annotations.enumerated() {
                let action = annotation.action as? PDFActionGoTo
                guard let destination = annotation.destination ?? action?.destination,
                      let target = destination.page else { continue }
                targets.append(Target(
                    page: index, annotation: n, destinationPage: printed.index(for: target), point: destination.point,
                    isAction: annotation.destination == nil))
            }
        }
        let document = PDFDocument()
        document.documentAttributes = printed.documentAttributes
        let pages = (0..<printed.pageCount).compactMap { printed.page(at: $0) }
        for (index, page) in pages.enumerated() { document.insert(page, at: index) }
        for target in targets {
            guard let page = document.page(at: target.page), target.annotation < page.annotations.count,
                  let destinationPage = document.page(at: target.destinationPage) else { continue }
            let destination = PDFDestination(page: destinationPage, at: target.point)
            let annotation = page.annotations[target.annotation]
            if target.isAction {
                annotation.action = PDFActionGoTo(destination: destination)
            } else {
                annotation.destination = destination
            }
        }
        return document
    }

    /// Print info that saves the job as a PDF at `url`, with the shared paper size.
    static func savingInfo(to url: URL) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        return info
    }

    /// Runs `operation` document-modally (on `sheetOn`, else the offscreen window), at most
    /// `timeout`, and returns whether it completed. Given up, the page is reloaded and a late
    /// completion is ignored.
    private func run(_ operation: NSPrintOperation, sheetOn host: NSWindow? = nil, timeout: Duration?) async throws -> Bool {
        let answer = try await step(timeout: timeout, recovery: .reloadPage) { id in
            operations[ObjectIdentifier(operation)] = id
            operation.runModal(
                for: host ?? window, delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard case .completed(let completed) = answer else { return false }
        return completed
    }

    /// AppKit calls this on the print operation's own thread (WebKit's operations may spawn one).
    @objc nonisolated private func printOperationDidRun(
        _ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        let operation = ObjectIdentifier(operation)
        Task { @MainActor in self.printOperationFinished(operation, success: success) }
    }

    private func printOperationFinished(_ operation: ObjectIdentifier, success: Bool) {
        guard let id = operations.removeValue(forKey: operation) else { return }
        finish(id, .success(.completed(success)))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation else { return }
        Task { await self.awaitRenderer(navigation) }
    }

    /// The page's module may still be evaluating at `didFinish` (observed on a loaded machine), so
    /// `window.baerchenExport` is polled until the page-load bound.
    private func awaitRenderer(_ navigation: WKNavigation?) async {
        let deadline = ContinuousClock.now.advanced(by: timeouts.pageLoad)
        func isCurrent() -> Bool { currentNavigation === navigation && pageState == .loading }
        while isCurrent() {
            let found = try? await webView.evaluateJavaScript("typeof window.baerchenExport?.render === 'function'")
            guard isCurrent() else { return }
            if found as? Bool == true {
                pageState = .ready
                return pageFinished(.success(.done))
            }
            guard ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard isCurrent() else { return }
        rendererLogger.error("export page loaded without its renderer")
        pageState = .idle
        currentNavigation = nil
        pageFinished(.failure(RenderError.pageUnavailable))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        pageFailed(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        pageFailed(navigation, error)
    }

    /// Only the current load's failure counts: a late one from a load a reload replaced is ignored.
    private func pageFailed(_ navigation: WKNavigation?, _ error: any Error) {
        guard navigation === currentNavigation, pageState == .loading else { return }
        rendererLogger.error("export page failed to load: \(error.localizedDescription, privacy: .public)")
        pageState = .idle
        currentNavigation = nil
        pageFinished(.failure(RenderError.pageUnavailable))
    }

    /// Only the export page loads; every other navigation (a link in a rendered note) is cancelled.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isPage = navigationAction.targetFrame?.isMainFrame == true
            && url?.scheme?.lowercased() == AssetSchemeHandler.scheme
            && url?.host?.lowercased() == AssetSchemeHandler.host && url?.path == Self.pageURL.path
        decisionHandler(isPage ? .allow : .cancel)
    }

    /// The call in flight fails with `pageCrashed`; the page reloads for the next call.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rendererLogger.error("export page web content process terminated; reloading")
        pageWaiters = []
        operations = [:]
        let failed = pending.values
        pending = [:]
        failed.forEach { $0.finish(.failure(RenderError.pageCrashed)) }
        loadPage()
    }
}

extension AppearanceController {
    /// The look of an exported or printed note: the theme with id `themeId`, or the
    /// light-slot theme (Settings ▸ Appearance) when nil or unknown; the typography as Settings has it.
    func exportLook(themeId: String?) -> (theme: [String: String], appearance: EditorAppearance, typography: EditorTypography) {
        let theme = themeId.flatMap(ThemeCatalog.theme(id:))
            ?? ThemeResolver.resolve(
                mode: .light, systemIsDark: false, increaseContrast: false, lightThemeId: snapshot.lightTheme,
                darkThemeId: snapshot.darkTheme)
        return (theme.editorVariables, theme.appearance == .dark ? .dark : .light, editorLook.typography)
    }
}
