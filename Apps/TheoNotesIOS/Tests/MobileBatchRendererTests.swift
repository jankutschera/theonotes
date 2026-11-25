// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import TheoNotesCore
import Foundation
import Testing
@testable import BaerchenIOS

@Suite(.serialized) @MainActor struct MobileBatchRendererTests {
    @Test func headlessRenderNeedsNoSelectedNoteAndKeepsFullRichContent() async throws {
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        let source = "# Batch export\n[[Other|Alias]]\n\n> [!NOTE]\n> Callout\n\n$$\nx^2\n$$\n\n```mermaid\ngraph TD; A-->B\n```\n\n" + String(repeating: "Paragraph.\n\n", count: 600) + "Final sentinel[^a]\n\n[^a]: Footnote text"
        let rendered = try await renderer.render(source: source, attachments: [:], keepTags: true, wikiLinks: ["Other": "../Sibling/Other.html"])
        #expect(rendered.html.contains("Final sentinel"))
        #expect(rendered.html.contains("Footnote text"))
        #expect(rendered.html.contains("../Sibling/Other.html"))
        #expect(rendered.html.contains("alt=\"x^2\""))
        #expect(rendered.html.contains("data:image/svg+xml"))
        #expect(rendered.html.contains("diagram"))
        #expect(rendered.text.contains("Callout"))
    }
    @Test func cancellationDiscardsHeadlessRenderer() async throws {
        let renderer = MobileBatchRenderer()
        defer { renderer.cancel() }
        let task = Task { try await renderer.render(source: "# Private fixture", attachments: [:], keepTags: true, wikiLinks: [:]) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled export should not return source") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
