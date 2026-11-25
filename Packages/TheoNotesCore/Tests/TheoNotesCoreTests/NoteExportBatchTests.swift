// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

struct NoteExportBatchTests {
    private func note(_ id: String, title: String, text: String) -> Note {
        Note(id: id, text: text, title: title, titleKey: TitleKey.make(title), createdAt: .now, modifiedAt: .now)
    }
    @Test func duplicateTitlesKeepSeparateAttachmentsAndOnlyRewriteParsedDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        try Data("first".utf8).write(to: one); try Data("second".utf8).write(to: two)
        let source = "![](photo%20one.png)\n`![](photo%20one.png)`\n[[Other]]"
        let wrapper = try NoteExport.batch(notes: [note("1", title: "../Same", text: source), note("2", title: "../same", text: source)], format: .markdown) { id, _ in id == "1" ? one : two }
        let files = try #require(wrapper.fileWrappers)
        #expect(files.count == 4)
        let docs = files.filter { $0.key.hasSuffix(".md") }.sorted { $0.key < $1.key }
        #expect(docs.count == 2)
        for (name, file) in docs {
            #expect(!name.contains("/"))
            let source = String(decoding: try #require(file.regularFileContents), as: UTF8.self)
            #expect(source.contains("`![](photo%20one.png)`"))
            #expect(source.contains("[[Other]]"))
            let assets = try #require(files[String(name.dropLast(3)) + ".assets"]?.fileWrappers)
            #expect(assets["photo one.png"] != nil, "Asset names: \(Array(assets.keys))")
            #expect(source.contains(".assets/photo%20one.png)"))
        }
    }
    @Test func tagTreeKeepsNestedFoldersAndSanitizedFolderCollisionsDistinct() throws {
        let notes = [note("1", title: "Alpha", text: "#work/team/a:b"), note("2", title: "Beta", text: "#work/team/a\\b")]
        let result = try NoteExport.batch(notes: notes, format: .textBundle, tagRoot: "work") { _, _ in nil }
        let work = try #require(result.fileWrappers?["work"]?.fileWrappers)
        #expect(work["team"] != nil)
        // Every emitted path component stays within the portable export root.
        func verify(_ wrapper: FileWrapper) {
            guard wrapper.isDirectory else { return }
            for (name, child) in wrapper.fileWrappers ?? [:] {
                #expect(name != "." && name != ".." && !name.contains("/") && !name.contains("\\"))
                verify(child)
            }
        }
        verify(result)
    }
    @Test func unicodeQuotePathsSurviveVerifiedZIPRoundTripWithOriginalAssetNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = root.appendingPathComponent("opaque-decrypted-cache")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: asset)
        let note = note("1", title: "A \"quoted\" 🐻", text: "#work/研究\n![](photo%20one.png)")
        var paths: [String: String] = [:]
        let wrapper = try NoteExport.batch(notes: [note], format: .markdown, tagRoot: "work", paths: &paths) { _, _ in asset }
        let directory = root.appendingPathComponent("source")
        try wrapper.write(to: directory, options: .atomic, originalContentsURL: nil)
        let archive = root.appendingPathComponent("notes.zip")
        try PortableZIP.create(from: directory, at: archive)
        let extracted = root.appendingPathComponent("extracted")
        try PortableZIP.extract(archive, to: extracted)
        let path = try #require(paths[note.id])
        let document = extracted.appendingPathComponent(path)
        #expect(try String(contentsOf: document, encoding: .utf8).contains(".assets/photo%20one.png)"))
        let image = document.deletingPathExtension().appendingPathExtension("assets").appendingPathComponent("photo one.png")
        #expect(try Data(contentsOf: image) == bytes)
        let bundles = try NoteExport.batch(notes: [note], format: .textBundle) { _, _ in asset }
        let bundle = try #require(bundles.fileWrappers?.values.first)
        #expect(try #require(bundle.fileWrappers?["assets"]?.fileWrappers?["photo one.png"]?.regularFileContents) == bytes)
    }

    @Test func renderedFileExtensionsAreReservedBeforeTagFoldersAreCreated() throws {
        let notes = [note("1", title: "A", text: "#work"), note("2", title: "B", text: "#work/A.html")]
        var paths: [String: String] = [:]
        let result = try NoteExport.batch(notes: notes, format: .markdown, tagRoot: "work", fileExtension: "html", paths: &paths) { _, _ in nil }
        #expect(paths["1"] == "work/A.html")
        let work = try #require(result.fileWrappers?["work"])
        #expect(work.fileWrappers?["A.html"]?.isRegularFile == true)
        for (id, path) in paths {
            var item = result
            for component in path.split(separator: "/") { item = try #require(item.fileWrappers?[String(component)]) }
            #expect(item.isRegularFile, "Manifest path for \(id) remains a file")
        }
    }

    @Test func lockedOrMissingAttachmentsFailInsteadOfSilentlyDroppingContents() throws {
        var locked = note("1", title: "Private", text: "secret"); locked.isLocked = true
        #expect(throws: StoreError.self) { try NoteExport.batch(notes: [locked], format: .markdown) { _, _ in nil } }
        #expect(throws: CocoaError.self) { try NoteExport.batch(notes: [note("2", title: "Missing", text: "[file](missing.pdf)<!-- {\"embed\":\"true\"} -->")], format: .markdown) { _, _ in nil } }
    }
}
