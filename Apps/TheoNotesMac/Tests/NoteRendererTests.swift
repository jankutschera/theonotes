// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import TheoNotesCore
import Foundation
import PDFKit
import Testing
import WebKit
@testable import TheoNotes

/// M8 Task 11: the offscreen renderer (the export page in a hidden `WKWebView`), the paginated PDF
/// through WebKit's print operation saved to a file, the PDFKit outline, and File ▸ Print….
/// R34: these tests use a window and WebKit printing; check the screen lock before reading a
/// failure (`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`).
@MainActor
@Suite(.serialized) final class NoteRendererTests {
    let root: URL
    let environment: AppEnvironment

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TheoNotesRenderer-\(UUID().uuidString)")
        environment = try AppEnvironment(paths: AppPaths(root: root))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var builder: RenderRequestBuilder { RenderRequestBuilder(store: environment.store, paths: environment.paths) }

    private func request(
        _ note: Note, themeId: String? = nil, wikiLinks: WikiLinkTargets = .sameNote
    ) throws -> RenderRequest {
        let look = environment.appearance.exportLook(themeId: themeId)
        return try builder.request(
            for: note, mode: .document, theme: look.theme, appearance: look.appearance, typography: look.typography,
            attachments: .assetURLs, wikiLinks: wikiLinks, keepTags: true)
    }

    private func pdfURL() -> URL {
        root.appendingPathComponent("out-\(UUID().uuidString).pdf")
    }

    // MARK: - Render

    @Test func rendersADocumentWithMathAndMermaidSVG() async throws {
        let note = try environment.store.create(text: """
            Maths and diagrams

            Inline $E = mc^2$ here.

            $$
            \\int_0^1 x\\,dx = \\tfrac12
            $$

            ```mermaid
            flowchart LR
              A[Start] --> B{Choice}
            ```

            ## After
            """)
        let renderer = NoteRenderer(environment: environment)
        let result = try await renderer.render(try request(note))
        #expect(result.html.contains("<span class=\"bc-math\"><svg"))
        #expect(result.html.contains("<div class=\"bc-math bc-math-display\"><svg"))
        #expect(result.html.contains("<figure class=\"bc-mermaid\"><img alt=\"\" src=\"data:image/svg+xml"))
        #expect(result.headings == [RenderedHeading(level: 2, text: "After", anchor: "h-1")])
    }

    // MARK: - PDF

    /// A note of about three screens: many paragraphs between a first and a last one.
    private static let longText: String = {
        var lines = ["Long note", "", "First paragraph alpha begins the note."]
        for n in 1...90 {
            lines += ["", "Paragraph \(n) carries filler text so that the note runs over more than one printed page."]
        }
        lines += ["", "Last paragraph omega ends the note."]
        return lines.joined(separator: "\n")
    }()

    @Test func writePDFIsPaginatedAndHasTheText() async throws {
        let note = try environment.store.create(text: Self.longText)
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        let pages = try await renderer.writePDF(try request(note, themeId: ThemeCatalog.defaultDarkId), to: url)
        let document = try #require(PDFDocument(url: url))
        #expect(pages >= 2)
        #expect(document.pageCount == pages)
        let text = document.string ?? ""
        #expect(text.contains("First paragraph alpha"))
        #expect(text.contains("Last paragraph omega"))
        // The dark theme's background is printed (shouldPrintBackgrounds): page 1 is mostly dark.
        let page = try #require(document.page(at: 0))
        let luminance = try #require(Self.meanLuminance(of: page))
        #expect(luminance < 0.5, "page 1 mean luminance \(luminance)")
    }

    @Test func pdfOutlineHasOneEntryPerHeadingNested() async throws {
        let note = try environment.store.create(text: """
            Outline

            # Alpha

            Text under alpha.

            ## Alpha one

            More text.

            ## Alpha two

            # Beta

            ### Beta deep

            The end.
            """)
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        _ = try await renderer.writePDF(try request(note), to: url)
        let document = try #require(PDFDocument(url: url))
        let outline = try #require(document.outlineRoot)
        #expect(Self.tree(outline) == [
            .init(label: "Alpha", children: [.init(label: "Alpha one"), .init(label: "Alpha two")]),
            .init(label: "Beta", children: [.init(label: "Beta deep")]),
        ])
        #expect(Self.allEntries(outline).allSatisfy { $0.destination?.page != nil })
        // Destinations follow the text: each one is at or below the previous on the same page, or later.
        let points = Self.allEntries(outline).compactMap { entry -> (Int, CGFloat)? in
            guard let destination = entry.destination, let page = destination.page else { return nil }
            return (document.index(for: page), destination.point.y)
        }
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(a.0 < b.0 || (a.0 == b.0 && a.1 >= b.1))
        }
    }

    @Test func outlineSkipsHeadingsItCannotFind() throws {
        let document = try #require(Self.textPDF("Intro\nFound heading\nBody\nFound heading\n"))
        PDFOutline.add([
            RenderedHeading(level: 1, text: "Found heading", anchor: "h-1"),
            RenderedHeading(level: 2, text: "Nowhere in the text", anchor: "h-2"),
            RenderedHeading(level: 2, text: "Found heading", anchor: "h-3"),
        ], to: document)
        let outline = try #require(document.outlineRoot)
        #expect(Self.tree(outline) == [.init(label: "Found heading", children: [.init(label: "Found heading")])])
        // The second "Found heading" points at the second match, not the first again.
        let first = try #require(outline.child(at: 0)?.destination)
        let second = try #require(outline.child(at: 0)?.child(at: 0)?.destination)
        #expect(first.point.y > second.point.y)
    }

    /// The probe of does WebKit keep an in-note heading link as a PDF link annotation?
    @Test func pdfKeepsInternalHeadingLinks() async throws {
        var lines = ["Links", "", "# First", "", "Go to [[/Second]] now."]
        for n in 1...40 { lines += ["", "Spacer paragraph \(n) pushes the second heading further down the page."] }
        lines += ["", "# Second", "", "Arrived."]
        let note = try environment.store.create(text: lines.joined(separator: "\n"))
        let req = try request(note)
        #expect(req.wikiLinks == [RenderWikiLink(href: "#h-2")])
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        _ = try await renderer.writePDF(req, to: url)
        let document = try #require(PDFDocument(url: url))
        let links = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
            .filter { $0.type == "Link" }
        let inDocument = links.filter { link in
            link.destination?.page != nil || ((link.action as? PDFActionGoTo)?.destination.page != nil)
        }
        #expect(!inDocument.isEmpty, "link annotations: \(links.count), with an in-document destination: \(inDocument.count)")
        // The link and the outline entry both go to the page of the heading "Second" (its last
        // occurrence), not to the mention of it in the link text on page 1.
        let heading = try #require(document.findString("Second", fromSelection: nil, withOptions: .backwards))
        let headingPage = document.index(for: try #require(heading.pages.first))
        #expect(headingPage > 0)
        let linkTarget = inDocument.first.flatMap { $0.destination?.page ?? ($0.action as? PDFActionGoTo)?.destination.page }
        #expect(linkTarget.map { document.index(for: $0) } == headingPage)
        let outline = try #require(document.outlineRoot)
        let second = try #require(Self.allEntries(outline).first { $0.label == "Second" })
        #expect(second.destination?.page.map { document.index(for: $0) } == headingPage)
    }

    @Test func attachmentImageIsInThePDF() async throws {
        let note = try environment.store.create(text: "Picture")
        let name = try AttachmentStore(paths: environment.paths, database: environment.database)
            .add(data: try #require(Self.redPNG()), filename: "red square.png", to: note.id)
        #expect(name == "red square.png")
        let saved = try environment.store.updateText(
            id: note.id, text: "Picture\n\n![](red%20square.png)\n", expectedRevision: note.revision)
        let req = try request(saved)
        #expect(req.attachmentSources[name]?.hasPrefix("baerchen-asset://attachment/") == true)
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        _ = try await renderer.writePDF(req, to: url)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        #expect(Self.hasRedPixels(page), "the red attachment image is not on page 1")
    }

    // MARK: - Crash

    @Test func crashedPageIsReloadedForTheNextCall() async throws {
        let note = try environment.store.create(text: "Crash\n\n## Part\n")
        let req = try request(note)
        let renderer = NoteRenderer(environment: environment)
        // A first render brings the page up.
        _ = try await renderer.render(req)
        let inFlight = Task { try await renderer.render(req) }
        // The task runs up to its wait for the page's answer, which needs another main-loop turn.
        for _ in 0..<1000 where !renderer.isBusy { await Task.yield() }
        try #require(renderer.isBusy)
        renderer.webViewWebContentProcessDidTerminate(renderer.webView)
        await #expect(throws: RenderError.pageCrashed) { _ = try await inFlight.value }
        let next = try await renderer.render(req)
        #expect(next.headings == [RenderedHeading(level: 2, text: "Part", anchor: "h-1")])
        #expect(renderer.pageLoads == 2)
    }

    // MARK: - Turns, timeouts, cancellation, navigations

    /// A render that never settles. The promise is kept reachable: WebKit fails a call whose
    /// pending promise was garbage-collected ("A JavaScript exception occurred", observed).
    static let hangingScript = "window.__hang ??= new Promise(() => {}); return await window.__hang"

    /// Yields until `renderer` holds a call that waits for WebKit (a page load, script or print job).
    private func untilWaiting(_ renderer: NoteRenderer) async throws {
        for _ in 0..<10_000 where renderer.waitingSteps == 0 { await Task.yield() }
        try #require(renderer.waitingSteps > 0)
    }

    @Test func aSecondCallWaitsForTheTurn() async throws {
        let first = try environment.store.create(text: Self.longText)
        let second = try environment.store.create(text: "Second note\n\nOnly in the second note.\n")
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        let log = Log()
        let pdf = Task {
            let pages = try await renderer.writePDF(try request(first), to: url)
            log.events.append("pdf")
            return pages
        }
        try await untilWaiting(renderer)
        let render = Task {
            let result = try await renderer.render(try request(second))
            log.events.append("render")
            return result
        }
        _ = try await pdf.value
        let rendered = try await render.value
        #expect(log.events == ["pdf", "render"])
        #expect(rendered.html.contains("Only in the second note."))
        // The PDF was made from the first note alone: the render did not replace the page under it.
        let text = try #require(PDFDocument(url: url)).string ?? ""
        #expect(text.contains("Last paragraph omega"))
        #expect(!text.contains("Only in the second note."))
    }

    @Test(.timeLimit(.minutes(1))) func aRenderThatNeverSettlesTimesOutAndTheNextOneWorks() async throws {
        let note = try environment.store.create(text: "Slow\n\n## Part\n")
        let req = try request(note)
        var timeouts = NoteRenderer.Timeouts()
        timeouts.render = .milliseconds(500)
        let renderer = NoteRenderer(environment: environment, timeouts: timeouts)
        _ = try await renderer.render(req)
        renderer.renderScript = Self.hangingScript
        await #expect(throws: RenderError.timedOut) { _ = try await renderer.render(req) }
        #expect(!renderer.isBusy)
        #expect(renderer.waitingSteps == 0)
        // The page, whose own render queue is stuck, was reloaded.
        #expect(renderer.pageLoads == 2)
        renderer.renderScript = NoteRenderer.defaultRenderScript
        let next = try await renderer.render(req)
        #expect(next.headings == [RenderedHeading(level: 2, text: "Part", anchor: "h-1")])
    }

    @Test(.timeLimit(.minutes(1))) func cancellingARenderReleasesTheRenderer() async throws {
        let note = try environment.store.create(text: "Cancel\n\n## Part\n")
        let req = try request(note)
        let renderer = NoteRenderer(environment: environment)
        _ = try await renderer.render(req)
        renderer.renderScript = Self.hangingScript
        let hanging = Task { try await renderer.render(req) }
        try await untilWaiting(renderer)
        hanging.cancel()
        await #expect(throws: RenderError.cancelled) { _ = try await hanging.value }
        #expect(!renderer.isBusy)
        renderer.renderScript = NoteRenderer.defaultRenderScript
        let next = try await renderer.render(req)
        #expect(next.headings == [RenderedHeading(level: 2, text: "Part", anchor: "h-1")])
    }

    @Test func aLateFailureFromAnOldNavigationIsIgnored() async throws {
        let note = try environment.store.create(text: "Reload\n\n## Part\n")
        let req = try request(note)
        let renderer = NoteRenderer(environment: environment)
        _ = try await renderer.render(req)
        let old = try #require(renderer.currentNavigation)
        // A crash reloads the page; a render waits for the new load.
        renderer.webViewWebContentProcessDidTerminate(renderer.webView)
        #expect(renderer.currentNavigation !== old)
        let waiting = Task { try await renderer.render(req) }
        try await untilWaiting(renderer)
        // The old navigation's failure arrives late: it must not fail the new load.
        renderer.webView(renderer.webView, didFailProvisionalNavigation: old, withError: URLError(.cancelled))
        renderer.webView(renderer.webView, didFail: old, withError: URLError(.cancelled))
        let result = try await waiting.value
        #expect(result.headings == [RenderedHeading(level: 2, text: "Part", anchor: "h-1")])
    }

    /// 200 headings, each followed by a link to another heading: every outline entry and every link
    /// lands on its heading's page. The time limit is a hang guard, not a perf gate (R29).
    @Test(.timeLimit(.minutes(5))) func manyHeadingsAndLinksKeepTheirTargets() async throws {
        let count = 200
        var lines = ["Stress"]
        for n in 1...count {
            lines += ["", "# Heading \(n)", "", "Jump to [[/Heading \(count + 1 - n)]] from here.", "",
                      "Filler text for heading \(n) so that the pages fill up with ordinary paragraphs."]
        }
        let note = try environment.store.create(text: lines.joined(separator: "\n"))
        let req = try request(note)
        #expect(req.wikiLinks.count == count)
        #expect(req.wikiLinks.allSatisfy { $0 != nil })
        let renderer = NoteRenderer(environment: environment)
        let url = pdfURL()
        let started = ContinuousClock.now
        let pages = try await renderer.writePDF(req, to: url)
        let elapsed = ContinuousClock.now - started
        let document = try #require(PDFDocument(url: url))
        #expect(pages >= 20, "pages: \(pages)")
        let outline = try #require(document.outlineRoot)
        let entries = Self.allEntries(outline)
        #expect(entries.map(\.label) == (1...count).map { "Heading \($0)" })
        var headingPage: [String: Int] = [:]
        for entry in entries {
            let page = try #require(entry.destination?.page)
            headingPage[entry.label ?? ""] = document.index(for: page)
            // The entry is on the heading, not on a mention of it: every mention is a link's text.
            let point = try #require(entry.destination?.point)
            let onALink = page.annotations.contains { $0.type == "Link" && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
            #expect(!onALink, "\(entry.label ?? "") points into a link")
        }
        var checked = 0
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            for link in page.annotations where link.type == "Link" {
                let label = page.selection(for: link.bounds)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let target = link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page
                #expect(target.map { document.index(for: $0) } == headingPage[label], "link \(label)")
                checked += 1
            }
        }
        #expect(checked == count)
        print("manyHeadingsAndLinksKeepTheirTargets: \(pages) pages in \(elapsed)")
    }

    @MainActor final class Log {
        var events: [String] = []
    }

    // MARK: - Print command

    @Test func printIsDisabledForLockedOrMultiSelection() {
        let open = PrintTarget.Note(id: "a", isLocked: false)
        let locked = PrintTarget.Note(id: "l", isLocked: true)
        let other = PrintTarget.Note(id: "b", isLocked: false)
        // The focused editor's note wins over the selection.
        #expect(PrintTarget.noteId(focusedEditorNote: open, selection: [other, locked]) == "a")
        #expect(PrintTarget.noteId(focusedEditorNote: locked, selection: [other]) == nil)
        // Otherwise exactly one unlocked selected note.
        #expect(PrintTarget.noteId(focusedEditorNote: nil, selection: [other]) == "b")
        #expect(PrintTarget.noteId(focusedEditorNote: nil, selection: [locked]) == nil)
        #expect(PrintTarget.noteId(focusedEditorNote: nil, selection: [open, other]) == nil)
        #expect(PrintTarget.noteId(focusedEditorNote: nil, selection: []) == nil)
    }

    @Test func exportLookUsesTheLightSlotByDefault() throws {
        let settings = TheoNotesCore.Settings(db: environment.database)
        try settings.set(.appearanceMode, to: .dark)
        let light = environment.appearance.exportLook(themeId: nil)
        let expected = try #require(ThemeCatalog.theme(id: ThemeCatalog.defaultLightId))
        #expect(light.appearance == .light)
        #expect(light.theme == expected.editorVariables)
        let dark = environment.appearance.exportLook(themeId: ThemeCatalog.defaultDarkId)
        #expect(dark.appearance == .dark)
        #expect(dark.theme == ThemeCatalog.theme(id: ThemeCatalog.defaultDarkId)?.editorVariables)
        // An unknown id falls back to the light slot.
        #expect(environment.appearance.exportLook(themeId: "no-such-theme").theme == expected.editorVariables)
    }

    // MARK: - Helpers

    struct Entry: Equatable {
        var label: String
        var children: [Entry] = []
    }

    static func tree(_ outline: PDFOutline) -> [Entry] {
        (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.map {
            Entry(label: $0.label ?? "", children: tree($0))
        }
    }

    static func allEntries(_ outline: PDFOutline) -> [PDFOutline] {
        (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }.flatMap { [$0] + allEntries($0) }
    }

    /// A one-page PDF with `text` drawn line by line from the top (Core Text through NSString drawing).
    static func textPDF(_ text: String) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (n, line) in text.split(separator: "\n").enumerated() {
            (String(line) as NSString).draw(
                at: NSPoint(x: 72, y: 700 - CGFloat(n) * 40), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    static func bitmap(of page: PDFPage) -> NSBitmapImageRep? {
        let image = page.thumbnail(of: NSSize(width: 200, height: 260), for: .mediaBox)
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    static func meanLuminance(of page: PDFPage) -> Double? {
        guard let rep = bitmap(of: page), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    static func hasRedPixels(_ page: PDFPage) -> Bool {
        guard let rep = bitmap(of: page) else { return false }
        var red = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // Colour management shifts the pure red a little (about 0.92, 0.2, 0.15 observed).
                if c.redComponent > 0.7, c.greenComponent < 0.4, c.blueComponent < 0.4 { red += 1 }
            }
        }
        return red > 20
    }

    /// A 120 × 120 pure red PNG.
    static func redPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 120, height: 120).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
