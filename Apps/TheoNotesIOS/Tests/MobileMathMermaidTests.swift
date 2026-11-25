// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Testing
import UIKit
import WebKit
@testable import BaerchenIOS

/// Uses the bundled production editor and native asset scheme, never a development server.
@Suite(.serialized) @MainActor
struct MobileMathMermaidTests {
    @Test func bundledMathAndMermaidRenderWithExactSourceAndStrictCSP() async throws {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let library = try MobileLibrary(paths: paths)
        defer { try? library.close(); try? FileManager.default.removeItem(at: paths.root) }
        let id = try library.createNote()
        let editor = MobileEditor(library: library)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = editor.webView
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try editor.open(id)
        try await wait {
            guard editor.ready && editor.editable else { return false }
            return (try? await editor.webView.evaluateJavaScript("document.querySelector('.cm-content')?.getAttribute('contenteditable')")) as? String == "true"
        }
        _ = try await editor.webView.evaluateJavaScript("window.__cspViolations=[]; document.addEventListener('securitypolicyviolation', e => window.__cspViolations.push(e.violatedDirective));")
        editor.command(.insertText, args: ["text": .string("plain")])
        try await wait { editor.session?.text == "plain" }
        let plainText = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').innerText")
        // iOS WebKit's TextIterator appends a terminal block boundary even for a plain
        // <div class="cm-line">plain</div>. Compare the same baseline boundary for rich notes.
        let boundary = String((plainText as? String ?? "").dropFirst("plain".count))
        #expect(boundary == "" || boundary == "\n")
        _ = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').cmTile.root.view.dispatch({selection:{anchor:0,head:5}})")
        let source = "start\n$\\frac{1}{2} + \\mathbb{R} + \\mathfrak{A}$\n\n$$\nx^2\n$$\n\n```mermaid\nflowchart TD\nA-->B\n```\nend"
        editor.command(.insertText, args: ["text": .string(source)])
        try await wait { editor.session?.text == source }
        try await wait {
            let rendered = try? await editor.webView.evaluateJavaScript("""
            (() => {
              const inline = document.querySelector('.cm-bc-math-inline')?.shadowRoot?.querySelector('svg');
              const math = document.querySelector('.cm-bc-block-mathBlock')?.shadowRoot?.querySelector('svg');
              const diagram = document.querySelector('.cm-bc-block-mermaid')?.shadowRoot?.querySelector('img');
              return !!inline && inline.querySelectorAll('[data-mml-node=mo]').length === 2 && inline.querySelectorAll('[data-mml-node=mi]').length === 2 && !!math && !!diagram && diagram.complete && diagram.naturalWidth > 0;
            })()
            """)
            return rendered as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(250))
        let screenshot = try await editor.webView.takeSnapshot(configuration: nil)
        let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("baerchen-rich-runtime.png")
        try screenshot.pngData()?.write(to: screenshotURL)
        print("MATH_RUNTIME_SCREENSHOT", screenshotURL.path)
        let text = try await editor.webView.evaluateJavaScript("document.querySelector('.cm-content').innerText")
        #expect(text as? String == source + boundary)
        let sourceLines = try await editor.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.cm-content > .cm-line'), line => line.textContent).join('\\n')")
        #expect(sourceLines as? String == source)
        let violations = try await editor.webView.evaluateJavaScript("window.__cspViolations")
        #expect((violations as? [String])?.isEmpty == true)
        try library.flush()
        #expect(try library.store.note(id: id)?.text == source)
    }

    @Test func exportedMathKeepsDarkThemeForegroundAndCompoundTerms() async throws {
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        let rendered = try await renderer.render(source: "$a+b$", attachments: [:], keepTags: true, wikiLinks: [:], foreground: "#ffffff")
        let expression = try NSRegularExpression(pattern: #"data:image/svg\+xml;charset=utf-8,([^"]+)"#)
        let match = try #require(expression.firstMatch(in: rendered.html, range: NSRange(rendered.html.startIndex..., in: rendered.html)))
        let range = try #require(Range(match.range(at: 1), in: rendered.html))
        let svg = try #require(String(rendered.html[range]).removingPercentEncoding)
        #expect(svg.contains("color: rgb(255, 255, 255)"))
        #expect(svg.contains("data-mml-node=\"mo\""))
        #expect(svg.contains("data-latex=\"a+b\""))
        for dark in [false, true] {
            let preferences = MobilePreferences()
            let background = try #require(preferences.theme(dark: dark).editor["color-callout-note-bg"])
            let document = MobileRenderedExport.document(body: rendered.html, title: "Math", preferences: preferences, dark: dark)
            #expect(document.contains(".callout-note{background:" + background))
        }
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<600 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for bundled math and Mermaid in WKWebView")
        throw CocoaError(.coderReadCorrupt)
    }
}
