// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// M8 Task 10: the render request/result mirror of `web/editor/src/export/protocol.ts` and the
/// builder that fills it from the store.
@Suite struct RenderProtocolTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/bridge/render-request.json")

    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    let attachments: AttachmentStore
    let builder: RenderRequestBuilder

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
        attachments = AttachmentStore(paths: tmp.paths, database: db)
        builder = RenderRequestBuilder(store: store, paths: tmp.paths)
    }

    private func request(
        _ note: Note, mode: RenderMode = .document, attachments: AttachmentSources = .none,
        wikiLinks: WikiLinkTargets = .none, keepTags: Bool = true,
        theme: [String: String] = [:], typography: EditorTypography = EditorTypography()
    ) throws -> RenderRequest {
        try builder.request(
            for: note, mode: mode, theme: theme, appearance: .light, typography: typography,
            attachments: attachments, wikiLinks: wikiLinks, keepTags: keepTags)
    }

    @Test func fixtureDecodesAndReencodes() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let decoded = try JSONDecoder().decode(RenderRequest.self, from: data)
        #expect(decoded.v == 1)
        #expect(decoded.mode == .document)
        #expect(decoded.appearance == .light)
        #expect(decoded.typography.fontText == "Iowan Old Style")
        #expect(decoded.typography.lineWidth == 680)
        #expect(decoded.wikiLinks == [RenderWikiLink(href: "Other%20note.html#h-2"), nil])
        #expect(decoded.attachmentSizes == ["photo 2.jpg": 20480, "report.pdf": 1_048_576])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let again = try JSONSerialization.jsonObject(with: encoder.encode(decoded)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        #expect(again != nil && again == expected, "\(String(describing: again)) != \(String(describing: expected))")

        let result = try JSONDecoder().decode(
            RenderResult.self,
            from: Data(#"{"html":"<p>x</p>","headings":[{"level":2,"text":"T","anchor":"h-1"}]}"#.utf8))
        #expect(result == RenderResult(html: "<p>x</p>", headings: [RenderedHeading(level: 2, text: "T", anchor: "h-1")]))
    }

    /// The cases of `Fixtures/bridge/render-request-cases.json`; `parseRenderRequest` runs the same ones.
    @Test func swiftAndTypeScriptAgreeOnEveryCase() throws {
        let directory = Self.fixtureURL.deletingLastPathComponent()
        let base = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        let file = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("render-request-cases.json"))) as? [String: Any])
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.count >= 20)
        for item in cases {
            let name = try #require(item["name"] as? String)
            var patched = base
            for (key, value) in item["set"] as? [String: Any] ?? [:] { patched[key] = value }
            for key in item["remove"] as? [String] ?? [] { patched[key] = nil }
            let data = try JSONSerialization.data(withJSONObject: patched)
            let accepted = (try? JSONDecoder().decode(RenderRequest.self, from: data)) != nil
            #expect(accepted == (item["accepts"] as? Bool), "\(name)")
        }
    }

    @Test func attachmentSizesAreOptionalAndOmittedWhenNil() throws {
        var request = RenderRequest(noteId: "n", title: "T", text: "x", mode: .document)
        request.attachmentSizes = nil
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["attachmentSizes"] == nil)
        #expect(try JSONDecoder().decode(RenderRequest.self, from: data).attachmentSizes == nil)
        // The initializer's default still sends a map (possibly empty).
        let sent = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(RenderRequest(noteId: "n", title: "T", text: "x", mode: .document))) as? [String: Any])
        #expect((sent["attachmentSizes"] as? [String: Int]) == [:])
    }

    @Test func builderResolvesWikiLinksPerOccurrenceWithHeadingAnchors() throws {
        let b = try store.create(text: "B\n\n# First\n\n## Second\n")
        let a = try store.create(text: "A\n\n[[B]] [[B/Second]] [[/Own]] [[Missing]] [[B/Nope]]\n\n# Own\n")
        let linked = try request(a, wikiLinks: .exported([b.id: "B.html"]))
        #expect(linked.wikiLinks == [
            RenderWikiLink(href: "B.html"),
            RenderWikiLink(href: "B.html#h-2"),
            RenderWikiLink(href: "#h-1"),
            nil,
            RenderWikiLink(href: "B.html"),
        ])
        // Same note only: links to other notes stay plain.
        let same = try request(a, wikiLinks: .sameNote)
        #expect(same.wikiLinks == [nil, nil, RenderWikiLink(href: "#h-1"), nil, nil])
        let none = try request(a, wikiLinks: .none)
        #expect(none.wikiLinks == [nil, nil, nil, nil, nil])
        // A link to a note that was not exported has no href; one to the note itself is a fragment.
        let selfLinked = try store.create(text: "S\n\n[[S/Part]] [[S]]\n\n## Part\n")
        let own = try request(selfLinked, wikiLinks: .exported([:]))
        #expect(own.wikiLinks == [RenderWikiLink(href: "#h-1"), nil])
    }

    @Test func builderInlinesImagesOnlyAndKeepsFilesRelative() throws {
        let note = try store.create(text: "N")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let image = try attachments.add(data: png, filename: "photo 2.png", to: note.id)
        let sheet = try attachments.add(data: Data(count: 2048), filename: "Q1 (final).pdf", to: note.id)
        let vector = try attachments.add(data: Data("<svg/>".utf8), filename: "logo.svg", to: note.id)
        let text = "N\n\n![](photo%202.png)\n\n[Q1 (final).pdf](Q1%20%28final%29.pdf)<!-- {\"embed\":\"true\"} -->\n\n![](logo.svg)\n"
        let saved = try store.updateText(id: note.id, text: text, expectedRevision: note.revision)

        let inline = try request(saved, attachments: .inlineImages(folder: "N files"))
        #expect(inline.attachmentSources[image] == "data:image/png;base64,\(png.base64EncodedString())")
        // Not an image, and an image type the page does not accept inline: relative.
        #expect(inline.attachmentSources[sheet] == "N%20files/Q1%20%28final%29.pdf")
        #expect(inline.attachmentSources[vector] == "N%20files/logo.svg")
        #expect(inline.attachmentSizes == [image: 7, sheet: 2048, vector: 6])

        let relative = try request(saved, attachments: .relative(folder: "N"))
        #expect(relative.attachmentSources[image] == "N/photo%202.png")
        #expect(relative.attachmentSources[sheet] == "N/Q1%20%28final%29.pdf")

        let assets = try request(saved, attachments: .assetURLs)
        #expect(assets.attachmentSources[image] == "baerchen-asset://attachment/\(note.id)/photo%202.png")
        #expect(assets.attachmentSources[sheet] == "baerchen-asset://attachment/\(note.id)/Q1%20%28final%29.pdf")

        let none = try request(saved, attachments: .none)
        #expect(none.attachmentSources.isEmpty)
        #expect(none.attachmentSizes == [image: 7, sheet: 2048, vector: 6])
    }

    @Test func builderAppliesKeepTags() throws {
        let note = try store.create(text: "Title\n\nBody #work text #a/b here\n\n#top #second\n\nEnd [[Other]]\n")
        let kept = try request(note, keepTags: true)
        #expect(kept.text == note.text)
        let stripped = try request(note, keepTags: false)
        #expect(stripped.text == "Title\n\nBody text here\n\n\nEnd [[Other]]\n")
        // The stored note is untouched.
        #expect(try store.note(id: note.id)?.text == note.text)
    }

    @Test func builderRefusesALockedNote() throws {
        var locked = try store.create(text: "Secret")
        locked.isLocked = true
        locked.text = ""
        locked.encryptedPayload = Data([1, 2, 3])
        #expect(throws: ExportError.noteLocked(id: locked.id)) {
            try request(locked)
        }
    }

    @Test func builderSanitizesThemeAndFontsLikeSetSettings() throws {
        let note = try store.create(text: "N")
        let built = try request(
            note,
            theme: ["--bc-color-bg": "#102030", "--bc-nonsense": "#ffffff", "--bc-color-text": "red;} x{y"],
            typography: EditorTypography(fontSize: 18, fontText: "Iowan Old Style", fontCode: "A\"B"))
        #expect(built.theme == ["--bc-color-bg": "#102030"])
        #expect(built.typography.fontSize == 18)
        #expect(built.typography.fontText == "Iowan Old Style")
        #expect(built.typography.fontCode == nil)
        #expect(built.title == "N")
        #expect(built.noteId == note.id)
        #expect(built.v == 1)
    }
}
