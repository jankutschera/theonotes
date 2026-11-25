// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

/// Synthetic Apple Notes exports built at run time from our own text: Markdown files with
/// attachment files next to them. Apple documents only that File > Export as > Markdown writes
/// Markdown files; where the attachments go and how a note links them is not documented, so the
/// importer reads any standard relative link and these trees cover the usual spellings (ANX-R3).
@Suite struct AppleNotesExportImporterTests {
    let tmp: TempPaths
    let scratch: Scratch
    let db: AppDatabase
    let store: NoteStore
    let now = Date(timeIntervalSince1970: 1_792_670_400)

    init() throws {
        tmp = try TempPaths()
        scratch = try Scratch()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func importer(limits: AppleNotesExportImporter.Limits = .standard) -> AppleNotesExportImporter {
        AppleNotesExportImporter(
            store: store, paths: tmp.paths, now: { [now] in now }, temporaryDirectory: scratch.temp, limits: limits)
    }

    @discardableResult
    private func run(
        _ urls: [URL], _ options: FileImportOptions = FileImportOptions(),
        limits: AppleNotesExportImporter.Limits = .standard,
        progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }
    ) throws -> FileImportReport {
        try importer(limits: limits).importItems(urls, options: options, progress: progress, isCancelled: isCancelled)
    }

    /// A file of `megabytes` MB that takes no disk space (a hole), so a test can link a huge
    /// attachment without writing it.
    @discardableResult
    private func writeSparse(_ relative: String, megabytes: Int) throws -> URL {
        let url = try scratch.write(relative, Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(megabytes) << 20)
        try handle.close()
        return url
    }

    private func allNotes() throws -> [Note] {
        try db.pool.read { try Note.fetchAll($0, sql: "SELECT * FROM note ORDER BY createdAt, id") }
    }

    private func note(containing text: String) throws -> Note {
        try #require(try allNotes().first { $0.text.contains(text) })
    }

    private func tags(_ note: Note) -> [String] { NoteParser.metadata(for: note.text).tags }

    private func attachmentNames(_ note: Note) -> [String] {
        let dir = tmp.paths.attachments.appendingPathComponent(note.id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
    private let pdf = Data("%PDF-1.4 synthetic".utf8)

    private func zip(_ tree: URL, _ entries: [String], to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-q", "-r", "-X", archive.path] + entries
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: - Real macOS 26 export shape (ANX-R30 ... ANX-R40)

    private let uuidA = "80142F90-E80B-46E7-839C-6010AE085E23"
    private let uuidB = "3BD0C4E2-012F-4DAF-80C2-08CA80FBA445"

    /// The tree File > Export as > Markdown wrote on macOS 26: a folder per note named after the
    /// title, `<Title>.md` and `Attachments/<UUID>.<ext>` in it, the PDF linked with image syntax.
    private func writePerNoteFolder(_ parent: String, title: String, body: String, attachments: [String: Data] = [:]) throws {
        let base = parent.isEmpty ? title : parent + "/" + title
        try scratch.write("\(base)/\(title).md", body)
        for (name, data) in attachments { try scratch.write("\(base)/Attachments/\(name)", data) }
    }

    @Test func testAPerNoteFolderAddsNoTagLevelAndTheParentFolderStillDoes() throws {
        _ = try scratch.dir("Notes Export")
        try writePerNoteFolder(
            "Notes Export", title: "pdf markdown export",
            body: "pdf markdown export  \n  \n![Invoice-KOTHIX-00061](Attachments/\(uuidA).pdf)  \n",
            attachments: ["\(uuidA).pdf": pdf])
        try writePerNoteFolder(
            "Notes Export", title: "Esso Mesoyi",
            body: "![Esso Mesoyi](Attachments/\(uuidB).pdf)  \n", attachments: ["\(uuidB).pdf": pdf])

        let report = try run([scratch.url.appendingPathComponent("Notes Export")])

        #expect(report.errors.isEmpty)
        #expect(report.created == 2)
        #expect(tags(try note(containing: "pdf markdown export")) == ["apple-notes/Notes Export"])
        #expect(tags(try note(containing: "Esso Mesoyi")) == ["apple-notes/Notes Export"])
        #expect(!report.warnings.contains { $0.contains("not linked") })
    }

    @Test func testChoosingThePerNoteFolderItselfGivesTheBareTag() throws {
        try writePerNoteFolder(
            "", title: "Esso Mesoyi", body: "![Esso Mesoyi](Attachments/\(uuidB).pdf)  \n",
            attachments: ["\(uuidB).pdf": pdf])

        let report = try run([scratch.url.appendingPathComponent("Esso Mesoyi")])

        #expect(report.created == 1)
        #expect(tags(try note(containing: "Esso Mesoyi")) == ["apple-notes"])
    }

    @Test func testAZipOfOnePerNoteFolderGivesTheBareTag() throws {
        try writePerNoteFolder(
            "", title: "Esso Mesoyi", body: "![Esso Mesoyi](Attachments/\(uuidB).pdf)  \n",
            attachments: ["\(uuidB).pdf": pdf])
        let archive = scratch.url.appendingPathComponent("one.zip")
        try zip(scratch.url, ["Esso Mesoyi"], to: archive)

        try run([archive])

        #expect(tags(try note(containing: "Esso Mesoyi")) == ["apple-notes"])
    }

    @Test func testPerNoteFoldersInsideARealNotesFolderKeepThatFolder() throws {
        _ = try scratch.dir("Export")
        try writePerNoteFolder("Export/Work", title: "Plan", body: "Plan  \n")
        try writePerNoteFolder("Export/Work", title: "Review", body: "Review  \n")

        try run([scratch.url.appendingPathComponent("Export")])

        #expect(tags(try note(containing: "Plan")) == ["apple-notes/Export/Work"])
        #expect(tags(try note(containing: "Review")) == ["apple-notes/Export/Work"])
    }

    @Test func testAFolderWithAnotherNoteOrFolderIsNotAPerNoteFolder() throws {
        _ = try scratch.dir("Export")
        try scratch.write("Export/Work/Work.md", "# Work\n")
        try scratch.write("Export/Work/Other.md", "# Other\n")
        try scratch.write("Export/Home/Home.md", "# Home\n")
        try scratch.write("Export/Home/Garden/Garden.md", "# Garden\n")
        try scratch.write("Export/Chores/Plan.md", "# Chores plan\n")

        try run([scratch.url.appendingPathComponent("Export")])

        #expect(tags(try note(containing: "# Work")) == ["apple-notes/Export/Work"])
        #expect(tags(try note(containing: "# Other")) == ["apple-notes/Export/Work"])
        #expect(tags(try note(containing: "# Home")) == ["apple-notes/Export/Home"])
        #expect(tags(try note(containing: "# Garden")) == ["apple-notes/Export/Home"])
        #expect(tags(try note(containing: "# Chores plan")) == ["apple-notes/Export/Chores"])
    }

    @Test func testAnAttachmentIsStoredUnderItsDisplayNameAndTheLinkFollows() throws {
        _ = try scratch.dir("Notes Export")
        try writePerNoteFolder(
            "Notes Export", title: "pdf markdown export",
            body: "pdf markdown export  \n  \n![Invoice-KOTHIX-00061](Attachments/\(uuidA).pdf)  \n",
            attachments: ["\(uuidA).pdf": pdf])

        let report = try run([scratch.url.appendingPathComponent("Notes Export")])

        let stored = try note(containing: "pdf markdown export")
        #expect(report.attachmentsCopied == 1)
        #expect(attachmentNames(stored) == ["Invoice-KOTHIX-00061.pdf"])
        #expect(stored.text.contains("](Invoice-KOTHIX-00061.pdf)"))
        #expect(!stored.text.contains(uuidA))
    }

    @Test func testDisplayNamesAreSanitizedKeptUniqueAndFallBackToTheFileName() throws {
        _ = try scratch.dir("Export")
        let ids = (1...6).map { "00000000-0000-0000-0000-00000000000\($0)" }
        let body = """
            ![Q3/Q4: plan](Attachments/\(ids[0]).pdf)  
            ![Same](Attachments/\(ids[1]).pdf)  
            ![Same](Attachments/\(ids[2]).pdf)  
            ![](Attachments/\(ids[3]).pdf)  
            ![  ](Attachments/\(ids[4]).png)  
            ![Photo.png](Attachments/\(ids[5]).png)  

            """
        try writePerNoteFolder(
            "Export", title: "Mixed", body: body,
            attachments: Dictionary(uniqueKeysWithValues: ids.enumerated().map {
                ("\($1).\($0 >= 4 ? "png" : "pdf")", $0 >= 4 ? png : pdf + Data([UInt8($0)]))
            }))

        let report = try run([scratch.url.appendingPathComponent("Export")])

        #expect(report.errors.isEmpty)
        #expect(attachmentNames(try note(containing: "Q3")) == [
            "\(ids[3]).pdf", "\(ids[4]).png", "Photo.png", "Q3-Q4- plan.pdf", "Same 2.pdf", "Same.pdf",
        ])
    }

    @Test func testAFileWithAMeaningfulNameKeepsItWhateverTheLinkSays() throws {
        _ = try scratch.dir("Export")
        try scratch.write("Export/Taxes.md", "[Sheet](files/figures.xlsx)\n")
        try scratch.write("Export/files/figures.xlsx", "x")

        try run([scratch.url.appendingPathComponent("Export")])

        #expect(attachmentNames(try note(containing: "Sheet")) == ["figures.xlsx"])
    }

    @Test func testTrailingSpacesOfTheExportSurviveExactly() throws {
        _ = try scratch.dir("Notes Export")
        try writePerNoteFolder("Notes Export", title: "Hard breaks", body: "Hard breaks  \n  \nsecond line  \nthird  \n")

        try run([scratch.url.appendingPathComponent("Notes Export")])

        let stored = try note(containing: "Hard breaks")
        #expect(stored.text.hasPrefix("Hard breaks  \n  \nsecond line  \nthird  \n"))
    }

    @Test func testALinkLineKeepsItsTwoTrailingSpaces() throws {
        _ = try scratch.dir("Notes Export")
        try writePerNoteFolder(
            "Notes Export", title: "Esso Mesoyi", body: "![Esso Mesoyi](Attachments/\(uuidB).pdf)  \n",
            attachments: ["\(uuidB).pdf": pdf])

        try run([scratch.url.appendingPathComponent("Notes Export")])

        let line = try #require(try note(containing: "Esso Mesoyi").text.split(separator: "\n", omittingEmptySubsequences: false).first)
        #expect(line.hasPrefix("[Esso Mesoyi](Esso%20Mesoyi.pdf)"))
        #expect(line.hasSuffix("  "))
    }

    // MARK: - Notes, folders and tags

    @Test func testEveryMarkdownFileIsANoteTaggedWithTheChosenFolder() throws {
        let export = try scratch.dir("Kitchen Export")
        try scratch.write("Kitchen Export/Soup.md", "# Soup\n\nBoil water.\n")
        try scratch.write("Kitchen Export/Bread.md", "# Bread\n\nBake it.\n")

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(report.created == 2)
        #expect(tags(try note(containing: "Boil water")) == ["apple-notes/Kitchen Export"])
        #expect(tags(try note(containing: "Bake it")) == ["apple-notes/Kitchen Export"])
    }

    @Test func testSubfoldersBecomeNestedTags() throws {
        _ = try scratch.dir("Export")
        try scratch.write("Export/Top.md", "# Top\n")
        try scratch.write("Export/Work/Plan.md", "# Plan\n")
        try scratch.write("Export/Work/2026/Review.md", "# Review\n")

        try run([scratch.url.appendingPathComponent("Export")])

        #expect(tags(try note(containing: "# Top")) == ["apple-notes/Export"])
        #expect(tags(try note(containing: "# Plan")) == ["apple-notes/Export/Work"])
        #expect(tags(try note(containing: "# Review")) == ["apple-notes/Export/Work/2026"])
    }

    @Test func testFolderNamesWithSpacesAndHashesStillMakeTags() throws {
        _ = try scratch.dir("Export")
        try scratch.write("Export/Big Plans #1/Idea.md", "# Idea\n")

        let report = try run([scratch.url.appendingPathComponent("Export")])

        #expect(report.errors.isEmpty)
        #expect(tags(try note(containing: "# Idea")) == ["apple-notes/Export/Big Plans -1"])
    }

    @Test func testAFolderNameThatCannotBeATagKeepsTheNoteInTheNearestUsableTag() throws {
        _ = try scratch.dir("Export")
        try scratch.write("Export/ok/ /Lost.md", "# Lost\n")

        let report = try run([scratch.url.appendingPathComponent("Export")])

        #expect(report.created == 1)
        #expect(tags(try note(containing: "# Lost")) == ["apple-notes/Export/ok"])
        #expect(report.warnings.contains { $0.contains("cannot become a tag") })
    }

    @Test func testAChosenMarkdownFileGetsTheBareTag() throws {
        let file = try scratch.write("Loose.md", "# Loose\n")

        try run([file])

        #expect(tags(try note(containing: "# Loose")) == ["apple-notes"])
    }

    @Test func testHiddenItemsMacosxSymlinksAndOtherFilesAreNotNotes() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Real.md", "# Real\n")
        try scratch.write("Export/.hidden.md", "# Hidden\n")
        try scratch.write("Export/__MACOSX/Ghost.md", "# Ghost\n")
        try scratch.write("Export/readme.pdf", pdf)
        let outside = try scratch.write("outside.md", "# Outside\n")
        try FileManager.default.createSymbolicLink(
            at: export.appendingPathComponent("Link.md"), withDestinationURL: outside)

        let report = try run([export])

        #expect(report.created == 1)
        #expect(try allNotes().count == 1)
    }

    @Test func testNotesComeInNameOrderSoTheReportIsStable() throws {
        _ = try scratch.dir("Export")
        for name in ["c", "a", "b"] { try scratch.write("Export/\(name).md", "# \(name)\n") }
        var order: [String] = []

        try run([scratch.url.appendingPathComponent("Export")], progress: { done, _ in
            if done > 0 { order.append("\(done)") }
        })

        #expect(order == ["1", "2", "3"])
        #expect(try allNotes().map(\.title).sorted() == ["a", "b", "c"])
    }

    // MARK: - Attachments

    @Test func testAnImageNextToTheNoteIsCopiedAndTheLinkPointsAtIt() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Trip.md", "# Trip\n\n![](Attachments/beach.png)\n")
        try scratch.write("Export/Attachments/beach.png", png)

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(report.attachmentsCopied == 1)
        let trip = try note(containing: "# Trip")
        #expect(trip.text.contains("![](beach.png)"))
        #expect(!trip.text.contains("Attachments/"))
        #expect(attachmentNames(trip) == ["beach.png"])
    }

    @Test func testAPdfAndAnotherFileBecomeAttachments() throws {
        let export = try scratch.dir("Export")
        try scratch.write(
            "Export/Taxes.md",
            "# Taxes\n\n[return.pdf](Attachments/return.pdf)\n\n[Sheet](Attachments/figures.xlsx)\n")
        try scratch.write("Export/Attachments/return.pdf", pdf)
        try scratch.write("Export/Attachments/figures.xlsx", Data("xlsx".utf8))

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(report.attachmentsCopied == 2)
        let taxes = try note(containing: "# Taxes")
        #expect(attachmentNames(taxes) == ["figures.xlsx", "return.pdf"])
        #expect(taxes.text.contains("[return.pdf](return.pdf) <!-- {\"preview\":\"true\",\"embed\":\"true\"} -->"))
        #expect(taxes.text.contains("[Sheet](figures.xlsx) <!-- {\"embed\":\"true\"} -->"))
        #expect(NoteParser.metadata(for: taxes.text).attachments.map(\.filename).sorted() == ["figures.xlsx", "return.pdf"])
    }

    @Test func testPercentEncodedAndAngleBracketLinksResolve() throws {
        let export = try scratch.dir("Export")
        try scratch.write(
            "Export/Scans.md",
            "# Scans\n\n![](Attachments/My%20Scan.png)\n\n[Receipt](<Attachments/Shop Receipt.pdf>)\n")
        try scratch.write("Export/Attachments/My Scan.png", png)
        try scratch.write("Export/Attachments/Shop Receipt.pdf", pdf)

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(attachmentNames(try note(containing: "# Scans")) == ["My Scan.png", "Shop Receipt.pdf"])
    }

    @Test func testANoteInASubfolderFindsAttachmentsBesideTheExportRoot() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Work/Plan.md", "# Plan\n\n[spec.pdf](../Attachments/spec.pdf)\n")
        try scratch.write("Export/Attachments/spec.pdf", pdf)

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(attachmentNames(try note(containing: "# Plan")) == ["spec.pdf"])
    }

    /// Notes in a folder with their own `Attachments` folder beside them (the per-note layout some
    /// write-ups describe): each link resolves against the note's own folder.
    @Test func testEachFolderMayHoldItsOwnAttachmentsFolder() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Work/Plan.md", "# Plan\n\n[x.pdf](Attachments/x.pdf)\n\n![](Attachments/chart.png)\n")
        try scratch.write("Export/Work/Attachments/x.pdf", pdf)
        try scratch.write("Export/Work/Attachments/chart.png", png)
        try scratch.write("Export/Home/Chores.md", "# Chores\n\n[x.pdf](Attachments/x.pdf)\n")
        try scratch.write("Export/Home/Attachments/x.pdf", pdf + Data([0x01]))

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(report.warnings.isEmpty)
        #expect(report.attachmentsCopied == 3)
        let plan = try note(containing: "# Plan")
        #expect(attachmentNames(plan) == ["chart.png", "x.pdf"])
        #expect(plan.text.contains("[x.pdf](x.pdf)"))
        #expect(tags(plan) == ["apple-notes/Export/Work"])
        let chores = try note(containing: "# Chores")
        #expect(attachmentNames(chores) == ["x.pdf"])
        let stored = tmp.paths.attachments.appendingPathComponent(chores.id).appendingPathComponent("x.pdf")
        #expect(try Data(contentsOf: stored) == pdf + Data([0x01]), "the Home copy, not the Work one")
    }

    // MARK: - Size limits

    @Test func testAHugeAttachmentIsNotReadAndTheRestOfTheNoteImports() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Big.md", "# Big\n\n[huge](Attachments/huge.pdf)\n\n![](Attachments/ok.png)\n")
        try writeSparse("Export/Attachments/huge.pdf", megabytes: 129)
        try scratch.write("Export/Attachments/ok.png", png)

        let report = try run([export])

        #expect(report.created == 1)
        #expect(report.errors.isEmpty)
        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.contains { $0.contains("huge.pdf") && $0.contains("larger than 128 MB") })
        let big = try note(containing: "# Big")
        #expect(attachmentNames(big) == ["ok.png"])
        #expect(big.text.contains("Attachments/huge.pdf"), "the link stays as written")
    }

    @Test func testAnAttachmentAtTheCapStillComes() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Edge.md", "# Edge\n\n[a](a.bin)\n")
        try scratch.write("Export/a.bin", Data(count: 1 << 20))

        let report = try run([export], limits: .init(each: 1 << 20, perNote: 4 << 20, total: 8 << 20))

        #expect(report.attachmentsCopied == 1)
        #expect(report.warnings.isEmpty)
    }

    @Test func testOneNotesAttachmentsStopAtThePerNoteBudget() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Many.md", "# Many\n\n[1](1.bin)\n\n[2](2.bin)\n\n[3](3.bin)\n")
        for name in ["1", "2", "3"] { try scratch.write("Export/\(name).bin", Data(count: (1 << 20) + Int(name)!)) }

        let report = try run([export], limits: .init(each: 2 << 20, perNote: 2_500_000, total: 100 << 20))

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.contains { $0.contains("3.bin") && $0.contains("size limit") })
    }

    @Test func testTheWholeRunStopsCopyingOnceTheTotalBudgetIsUsed() throws {
        let export = try scratch.dir("Export")
        for name in ["a", "b", "c"] {
            try scratch.write("Export/\(name).md", "# \(name)\n\n[f](\(name).bin)\n")
            try scratch.write("Export/\(name).bin", Data(count: 1 << 20))
        }

        let report = try run([export], limits: .init(each: 2 << 20, perNote: 2 << 20, total: (2 << 20) + 10))

        #expect(report.created == 3, "the notes themselves still import")
        #expect(report.attachmentsCopied == 2)
        #expect(report.warnings.filter { $0.contains("size limit") }.count == 1)
    }

    @Test func testAFileThatWasNotCopiedIsStillReportedAsNotImported() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/N.md", "# N\n\n[h](h.bin)\n")
        try writeSparse("Export/h.bin", megabytes: 129)

        let report = try run([export])

        #expect(report.attachmentsCopied == 0)
        #expect(report.warnings.contains { $0.contains("not linked from any note") }, "a file that was not copied is not hidden")
    }

    @Test func testALinkOutsideTheExportIsLeftAloneAndReported() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Sneaky.md", "# Sneaky\n\n[x](../secret.pdf)\n")
        try scratch.write("secret.pdf", pdf)

        let report = try run([export])

        #expect(report.attachmentsCopied == 0)
        #expect(report.warnings.contains { $0.contains("outside the import folder") })
        #expect(try note(containing: "# Sneaky").text.contains("../secret.pdf"))
    }

    @Test func testAMissingAttachmentIsReportedAndTheNoteStillImports() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Gone.md", "# Gone\n\n![](Attachments/missing.png)\n")

        let report = try run([export])

        #expect(report.created == 1)
        #expect(report.warnings.contains { $0.contains("missing.png") && $0.contains("not found") })
    }

    @Test func testTwoNotesMayUseTheSameAttachmentName() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/One.md", "# One\n\n![](one/image.png)\n")
        try scratch.write("Export/Two.md", "# Two\n\n![](two/image.png)\n")
        try scratch.write("Export/one/image.png", png)
        try scratch.write("Export/two/image.png", png + Data([0x09]))

        let report = try run([export])

        #expect(report.errors.isEmpty)
        #expect(attachmentNames(try note(containing: "# One")) == ["image.png"])
        #expect(attachmentNames(try note(containing: "# Two")) == ["image.png"])
    }

    @Test func testFilesNoNoteLinksAreCountedInOneWarning() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Note.md", "# Note\n\nNo links here.\n")
        try scratch.write("Export/Attachments/orphan.pdf", pdf)
        try scratch.write("Export/Attachments/orphan2.png", png)

        let report = try run([export])

        #expect(report.created == 1)
        #expect(report.attachmentsCopied == 0)
        #expect(report.warnings.filter { $0.contains("not linked from any note") }.count == 1)
        #expect(report.warnings.contains { $0.contains("2 file(s)") })
    }

    @Test func testAnAttachmentFolderWithOnlyLinkedFilesRaisesNoOrphanWarning() throws {
        let export = try scratch.dir("Export")
        try scratch.write("Export/Note.md", "# Note\n\n![](Attachments/a.png)\n")
        try scratch.write("Export/Attachments/a.png", png)

        let report = try run([export])

        #expect(!report.warnings.contains { $0.contains("not linked") })
    }

    @Test func testAChosenNoteFindsItsSiblingAttachments() throws {
        let file = try scratch.write("Single.md", "# Single\n\n![](Attachments/pic.png)\n")
        try scratch.write("Attachments/pic.png", png)

        let report = try run([file])

        #expect(report.attachmentsCopied == 1)
        #expect(!report.warnings.contains { $0.contains("not linked") }, "a chosen file does not audit its folder")
    }

    // MARK: - Dates

    @Test func testDatesFollowTheFilesUnlessTurnedOff() throws {
        let file = try scratch.write("Export/Dated.md", "# Dated\n")
        let modified = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        try run([scratch.url.appendingPathComponent("Export")])
        let kept = try note(containing: "# Dated")
        #expect(abs(kept.modifiedAt.timeIntervalSince(modified)) < 1)

        try run([scratch.url.appendingPathComponent("Export")], FileImportOptions(keepDates: false))
        let stamped = try #require(try allNotes().last)
        #expect(abs(stamped.modifiedAt.timeIntervalSince(now)) < 1)
    }

    @Test func testTheFileNameBecomesTheTitleOnRequest() throws {
        try scratch.write("Export/Untitled thought.md", "Just words.\n")

        try run([scratch.url.appendingPathComponent("Export")], FileImportOptions(titleFromFilename: true))

        #expect(try note(containing: "Just words").text.hasPrefix("# Untitled thought\n\nJust words."))
    }

    // MARK: - Zip

    @Test func testAZipWithOneTopFolderUsesThatFolderAsRoot() throws {
        let tree = try scratch.dir("src")
        try scratch.write("src/Recipes/Cake.md", "# Cake\n\n![](Attachments/cake.png)\n")
        try scratch.write("src/Recipes/Attachments/cake.png", png)
        try scratch.write("src/Recipes/Pies/Apple.md", "# Apple\n")
        let archive = scratch.url.appendingPathComponent("anything.zip")
        try zip(tree, ["Recipes"], to: archive)

        let report = try run([archive])

        #expect(report.errors.isEmpty)
        #expect(report.created == 2)
        #expect(report.attachmentsCopied == 1)
        #expect(tags(try note(containing: "# Cake")) == ["apple-notes/Recipes"])
        #expect(tags(try note(containing: "# Apple")) == ["apple-notes/Recipes/Pies"])
    }

    @Test func testAZipWithLooseFilesUsesItsOwnNameAsTheFolder() throws {
        let tree = try scratch.dir("src")
        try scratch.write("src/A.md", "# A\n")
        try scratch.write("src/B.md", "# B\n")
        let archive = scratch.url.appendingPathComponent("Garden Notes.zip")
        try zip(tree, ["A.md", "B.md"], to: archive)

        try run([archive])

        #expect(tags(try note(containing: "# A")) == ["apple-notes/Garden Notes"])
    }

    @Test func testABrokenZipIsAnErrorAndLaterItemsStillRun() throws {
        let bad = try scratch.write("Bad.zip", "this is not a zip file")
        let export = try scratch.dir("Good")
        try scratch.write("Good/Fine.md", "# Fine\n")

        let report = try run([bad, export])

        #expect(report.created == 1)
        #expect(report.errors.contains { $0.hasPrefix("Bad.zip") })
    }

    @Test func testTheTemporaryFolderIsRemovedAfterwards() throws {
        let tree = try scratch.dir("src")
        try scratch.write("src/A.md", "# A\n")
        let archive = scratch.url.appendingPathComponent("a.zip")
        try zip(tree, ["A.md"], to: archive)

        try run([archive])

        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.temp.path)) ?? []
        #expect(left.isEmpty)
    }

    // MARK: - Failures, skips, cancel

    @Test func testOneUnreadableNoteDoesNotStopTheRun() throws {
        let export = try scratch.dir("Export")
        let locked = try scratch.write("Export/A locked.md", "# Locked\n")
        try scratch.write("Export/B fine.md", "# Fine\n")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let report = try run([export])

        #expect(report.created == 1)
        #expect(report.errors.count == 1)
        #expect(report.errors[0].hasPrefix("Export/A locked.md"))
        #expect(!report.errors[0].contains("Locked"), "reports never carry note text")
    }

    @Test func testAnEmptyNoteIsSkippedWithAWarning() throws {
        try scratch.write("Export/Empty.md", "  \n\n")
        try scratch.write("Export/Full.md", "# Full\n")

        let report = try run([scratch.url.appendingPathComponent("Export")])

        #expect(report.created == 1)
        #expect(report.skipped == 1)
        #expect(report.warnings.contains { $0.hasSuffix("empty, skipped") })
    }

    @Test func testUnsupportedAndMissingItemsAreReported() throws {
        let other = try scratch.write("photo.jpg", png)
        let missing = scratch.url.appendingPathComponent("nope.md")

        let report = try run([other, missing])

        #expect(report.created == 0)
        #expect(report.skipped == 1)
        #expect(report.warnings.contains { $0.hasPrefix("photo.jpg") })
        #expect(report.errors == ["nope.md: not found"])
    }

    @Test func testCancelStopsBetweenTwoNotes() throws {
        _ = try scratch.dir("Export")
        for name in ["a", "b", "c"] { try scratch.write("Export/\(name).md", "# \(name)\n") }
        var calls = 0

        let report = try run([scratch.url.appendingPathComponent("Export")], isCancelled: {
            calls += 1
            return calls > 3
        })

        #expect(report.wasCancelled)
        #expect(report.created < 3)
        #expect(try allNotes().count == report.created)
    }

    @Test func testProgressReportsTheTotalBeforeTheFirstNote() throws {
        _ = try scratch.dir("Export")
        for name in ["a", "b"] { try scratch.write("Export/\(name).md", "# \(name)\n") }
        var seen: [[Int]] = []

        try run([scratch.url.appendingPathComponent("Export")], progress: { seen.append([$0, $1]) })

        #expect(seen.first == [0, 2])
        #expect(seen.last == [2, 2])
    }

    @Test func testTextWithTheWindowsCodePageIsReadWithAWarning() throws {
        try scratch.write("Export/Old.md", Data([0x23, 0x20, 0x43, 0x61, 0x66, 0xE9, 0x0A]))

        let report = try run([scratch.url.appendingPathComponent("Export")])

        #expect(report.created == 1)
        #expect(report.warnings.contains { $0.contains("Windows-1252") })
        #expect(try allNotes().first?.text.contains("Café") == true)
    }
}
