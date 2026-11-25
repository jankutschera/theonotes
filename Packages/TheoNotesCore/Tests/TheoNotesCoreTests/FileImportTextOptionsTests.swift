// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import GRDB
import Testing
@testable import TheoNotesCore

/// A14: "use the first line as the title" and "keep #1-style text as text". Defaults are off.
@Suite struct FileImportTextOptionsTests {
    let tmp: TempPaths
    let scratch: Scratch
    let db: AppDatabase
    let store: NoteStore

    init() throws {
        tmp = try TempPaths()
        scratch = try Scratch()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func importText(_ name: String, _ text: String, _ options: FileImportOptions) throws -> Note {
        let file = try scratch.write(name, text)
        let importer = FileImporter(store: store, paths: tmp.paths, temporaryDirectory: scratch.temp)
        let report = try importer.importItems([file], options: options, progress: { _, _ in }, isCancelled: { false })
        #expect(report.errors == [])
        return try #require(try db.pool.read { try Note.fetchOne($0, sql: "SELECT * FROM note") })
    }

    private func tags(_ note: Note) -> [String] { NoteParser.metadata(for: note.text).tags }

    // MARK: - First line as the title

    @Test func theFirstLineBecomesAHeading() throws {
        let note = try importText("a.txt", "Shopping list\nmilk\n", FileImportOptions(titleFromFirstLine: true))
        #expect(note.text == "# Shopping list\nmilk\n")
    }

    @Test func blankLinesAndFrontMatterComeFirst() throws {
        let note = try importText("a.md", "---\nk: v\n---\n\n\nPlan\nbody\n", FileImportOptions(titleFromFirstLine: true))
        #expect(note.text == "---\nk: v\n---\n\n\n# Plan\nbody\n")
    }

    @Test func anExistingHeadingTagLineOrBlockIsLeftAlone() throws {
        for text in ["# Already\nbody\n", "## Two\nbody\n", "#work\nbody\n", "- item\nbody\n", "```\ncode\n```\n", "> quote\n", "1. one\n"] {
            try db.pool.write { try $0.execute(sql: "DELETE FROM note") }
            let note = try importText("a.md", text, FileImportOptions(titleFromFirstLine: true))
            #expect(note.text == text, "\(text.debugDescription)")
        }
    }

    @Test(arguments: [
        "---\n\nbody\n", "***\nbody\n", "___\nbody\n", "$$\nx\n$$\n", "<div>x</div>\nbody\n", "<!-- c -->\nbody\n",
        "[^1]: note\nbody\n", "![](photo.png)\ntext\n", ">quote\n", "> quote\n", "    indented code\nbody\n",
        "\tindented code\nbody\n", "Title\n=====\nbody\n", "Title\n-----\nbody\n", "Title\n=\nbody\n",
    ])
    func linesThatAreNotTitlesStayByteForByte(_ text: String) {
        #expect(FileImporter.makingFirstLineTheTitle(text) == text, "\(text.debugDescription)")
    }

    @Test func onlyLeadingSpacesGoAndATrailingHardBreakStays() {
        #expect(FileImporter.makingFirstLineTheTitle("  Title  \nbody\n") == "# Title  \nbody\n")
        #expect(FileImporter.makingFirstLineTheTitle("Title\n---- x\n") == "# Title\n---- x\n")
    }

    @Test func theFirstLineWinsOverTheFileName() throws {
        let note = try importText("Meeting.md", "Agenda\nbody\n", FileImportOptions(titleFromFilename: true, titleFromFirstLine: true))
        #expect(note.text == "# Agenda\nbody\n")
    }

    @Test func bothOffLeavesTheTextAlone() throws {
        #expect(try importText("a.txt", "Shopping list\nmilk\n", FileImportOptions()).text == "Shopping list\nmilk\n")
    }

    // MARK: - #1-style text

    @Test func escapingKeepsNumberedHashTextAsText() {
        #expect(FileImporter.escapingNumberedTags(in: "see #1st and #2026-07-09 now") == "see \\#1st and \\#2026-07-09 now")
        // Pure numbers are not tags to begin with, a closed #…# is a deliberate tag, letters stay tags.
        #expect(FileImporter.escapingNumberedTags(in: "#1 #2021# #work/a1 `#9a`") == "#1 #2021# #work/a1 `#9a`")
    }

    @Test func aNumberedHashIsATagUnlessTheOptionIsOn() throws {
        let text = "Race\n\nfinished #3rd today #sport\n"
        let off = try importText("a.md", text, FileImportOptions())
        #expect(tags(off).sorted() == ["3rd", "sport"])
        try db.pool.write { try $0.execute(sql: "DELETE FROM note") }
        let on = try importText("a.md", text, FileImportOptions(keepHashNumbersAsText: true))
        #expect(tags(on) == ["sport"])
        #expect(on.text == "Race\n\nfinished \\#3rd today #sport\n")
    }
}
