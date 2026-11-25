// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
import GRDB
@testable import TheoNotesCore

@Suite struct TemplatesTests {
    let tmp: TempPaths
    let db: AppDatabase
    let store: NoteStore
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }()
    /// Thursday 2026-10-22 12:05 Helsinki (UTC+3).
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12, minute: 5))! }

    init() throws {
        tmp = try TempPaths()
        db = try AppDatabase.inMemory()
        store = NoteStore(db: db, notifier: nil, paths: tmp.paths)
    }

    private func context(
        locale: String = "en_US", clipboard: String? = nil, title: String? = nil, now: Date? = nil
    ) -> TemplateContext {
        TemplateContext(
            now: now ?? self.now, calendar: calendar, locale: Locale(identifier: locale),
            clipboard: clipboard, title: title)
    }

    private func run(_ text: String, _ context: TemplateContext? = nil) -> TemplateResult {
        Templates.instantiate(templateText: text, context: context ?? self.context())
    }

    // MARK: placeholders

    @Test func testDate() {
        #expect(run("{{date}}").text == "2026-10-22")
    }

    @Test func testDateUsesCalendarTimeZoneNotUTC() {
        // 2026-10-22 22:30 UTC is already 23 Oct 01:30 in Helsinki (UTC+3).
        let late = ISO8601DateFormatter().date(from: "2026-10-22T22:30:00Z")!
        #expect(run("{{date}} {{time}}", context(now: late)).text == "2026-10-23 01:30")
    }

    @Test func testTime() {
        #expect(run("{{time}}").text == "12:05")
    }

    @Test func testTimeZeroPadded() {
        let nineOhFive = calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9, minute: 5))!
        #expect(run("{{datetime}}", context(now: nineOhFive)).text == "2026-03-04 09:05")
    }

    @Test func testDatetime() {
        #expect(run("{{datetime}}").text == "2026-10-22 12:05")
    }

    @Test func testWeekdayLocalized() {
        #expect(run("{{weekday}}").text == "Thursday")
        #expect(run("{{weekday}}", context(locale: "de_DE")).text == "Donnerstag")
    }

    @Test func testTitle() {
        let result = run("# {{title}}", context(title: "Standup"))
        #expect(result.text == "# Standup")
        #expect(!result.needsTitle)
    }

    @Test func testTitleMissingSetsNeedsTitleAndExpandsEmpty() {
        let result = run("# {{title}}\nbody")
        #expect(result.text == "# \nbody")
        #expect(result.needsTitle)
    }

    @Test func testNeedsTitleFalseWithoutPlaceholder() {
        #expect(!run("# Plain").needsTitle)
    }

    @Test func testNeedsTitleIgnoresTitleInsideCode() {
        #expect(!run("`{{title}}`").needsTitle)
    }

    @Test func testClipboard() {
        #expect(run("> {{clipboard}}", context(clipboard: "copied")).text == "> copied")
    }

    @Test func testClipboardLineEndingsNormalizedBeforeCaret() {
        let result = run("{{clipboard}}{{cursor}}", context(clipboard: "a\r\nb"))
        #expect(result.text == "a\nb")
        #expect(result.caretOffset == 3)
        #expect(run("{{clipboard}}", context(clipboard: "a\rb\r\n")).text == "a\nb\n")
    }

    @Test func testTitleNewlinesCollapsedToSpaces() {
        let result = run("# {{title}}{{cursor}}", context(title: "Line one\r\nline two\nthree"))
        #expect(result.text == "# Line one line two three")
        #expect(result.caretOffset == result.text.utf16.count)
    }

    @Test func testDateTimeAreGregorianForOtherCalendarSystems() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = buddhist.timeZone
        for calendar in [buddhist, japanese] {
            let context = TemplateContext(now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
            #expect(run("{{datetime}}", context).text == "2026-10-22 12:05")
        }
    }

    @Test func testClipboardNilIsEmpty() {
        #expect(run("[{{clipboard}}]").text == "[]")
    }

    @Test func testClipboardContentIsNotExpandedAgain() {
        #expect(run("{{clipboard}}", context(clipboard: "{{date}} {{cursor}}")).text == "{{date}} {{cursor}}")
        #expect(run("{{clipboard}}", context(clipboard: "{{date}}")).caretOffset == nil)
    }

    @Test func testUnknownPlaceholdersStay() {
        #expect(run("{{nope}} {{ date }} {{DATE}} {{date").text == "{{nope}} {{ date }} {{DATE}} {{date")
    }

    @Test func testBraceRunAroundPlaceholder() {
        #expect(run("{{{date}}}").text == "{2026-10-22}")
    }

    @Test func testRepeatedPlaceholders() {
        #expect(run("{{date}} and {{date}}").text == "2026-10-22 and 2026-10-22")
    }

    @Test func testMultiplePlaceholdersOnOneLine() {
        #expect(run("{{weekday}}, {{date}} {{time}}").text == "Thursday, 2026-10-22 12:05")
    }

    // MARK: cursor

    @Test func testCursorRemovedAndOffsetReported() {
        let result = run("Hello {{cursor}}world")
        #expect(result.text == "Hello world")
        #expect(result.caretOffset == 6)
    }

    @Test func testNoCursorMeansNilOffset() {
        #expect(run("Hello").caretOffset == nil)
    }

    @Test func testCursorOffsetCountsUTF16AfterEmoji() {
        let result = run("👋 Hi {{cursor}}!")
        #expect(result.text == "👋 Hi !")
        #expect(result.caretOffset == 6)  // "👋" is two UTF-16 units
    }

    @Test func testCursorOffsetUsesExpandedTextBefore() {
        let result = run("{{title}} {{date}} {{cursor}}", context(title: "Ünï😀"))
        #expect(result.text == "Ünï😀 2026-10-22 ")
        #expect(result.caretOffset == "Ünï😀 2026-10-22 ".utf16.count)
    }

    @Test func testCursorOffsetUnaffectedByPlaceholdersAfterIt() {
        let result = run("{{cursor}} {{date}}")
        #expect(result.text == " 2026-10-22")
        #expect(result.caretOffset == 0)
    }

    @Test func testCursorOnLaterLine() {
        let result = run("# T\n\n- {{cursor}}")
        #expect(result.text == "# T\n\n- ")
        #expect(result.caretOffset == 7)
    }

    @Test func testOnlyFirstCursorCountsLaterOnesRemoved() {
        let result = run("a{{cursor}}b{{cursor}}c")
        #expect(result.text == "abc")
        #expect(result.caretOffset == 1)
    }

    @Test func testCursorOffsetAccountsForRemovedTemplateTagLine() {
        let result = run("#template\n# Note\n{{cursor}}")
        #expect(result.text == "# Note\n")
        #expect(result.caretOffset == 7)
    }

    // MARK: code protection

    @Test func testInlineCodeIsUntouched() {
        let result = run("use `{{date}}` for {{date}}")
        #expect(result.text == "use `{{date}}` for 2026-10-22")
    }

    @Test func testDoubleBacktickCodeSpanIsUntouched() {
        #expect(run("``{{time}}`` {{time}}").text == "``{{time}}`` 12:05")
    }

    @Test func testCursorInsideCodeIsNotACaret() {
        let result = run("`{{cursor}}`")
        #expect(result.text == "`{{cursor}}`")
        #expect(result.caretOffset == nil)
    }

    @Test func testFencedBlockIsUntouched() {
        let text = "{{date}}\n```\n{{date}}\n{{cursor}}\n```\n{{time}}"
        let result = run(text)
        #expect(result.text == "2026-10-22\n```\n{{date}}\n{{cursor}}\n```\n12:05")
        #expect(result.caretOffset == nil)
    }

    @Test func testTildeFenceAndInfoStringUntouched() {
        let text = "~~~md\n{{date}}\n~~~\n{{date}}"
        #expect(run(text).text == "~~~md\n{{date}}\n~~~\n2026-10-22")
    }

    @Test func testUnclosedFenceProtectsRest() {
        #expect(run("```\n{{date}}").text == "```\n{{date}}")
    }

    @Test func testTemplateTagInsideCodeStays() {
        #expect(run("`#template` {{date}}").text == "`#template` 2026-10-22")
    }

    // MARK: template tag removal

    @Test func testTemplateTagLineRemoved() {
        #expect(run("#template\n# Meeting {{date}}\nbody").text == "# Meeting 2026-10-22\nbody")
    }

    @Test func testTemplateTagOnTitleLineRemoved() {
        #expect(run("# Meeting #template\nbody").text == "# Meeting\nbody")
    }

    @Test func testNestedTemplateTagRemoved() {
        #expect(run("# Meeting\n#template/meeting\nbody").text == "# Meeting\nbody")
    }

    @Test func testDeepNestedTemplateTagRemoved() {
        #expect(run("# M\n#template/work/standup\nbody").text == "# M\nbody")
    }

    @Test func testClosedMultiWordTemplateTagRemoved() {
        #expect(run("# M\n#template/my thing#\nbody").text == "# M\nbody")
    }

    @Test func testClosedRootTemplateTagRemoved() {
        #expect(run("# M\n#template#\nbody").text == "# M\nbody")
    }

    @Test func testTemplateTagCaseInsensitive() {
        #expect(run("# M\n#Template/Weekly\nbody").text == "# M\nbody")
    }

    @Test func testOtherTagsStay() {
        #expect(run("# Notes #template/standup #work\n#team/alpha").text == "# Notes #work\n#team/alpha")
    }

    @Test func testSimilarTagsStay() {
        let text = "# M #templates #work/template #template-x"
        #expect(run(text).text == text)
    }

    @Test func testMultipleTemplateTagsAllRemoved() {
        #expect(run("# M\n#template #template/a\nbody").text == "# M\nbody")
    }

    @Test func testNoTemplateTagLeavesTextAlone() {
        #expect(run("# M\n\nbody\n").text == "# M\n\nbody\n")
    }

    // MARK: line endings

    @Test func testLineEndingsNormalized() {
        let result = run("a\r\n{{cursor}}b\rc")
        #expect(result.text == "a\nb\nc")
        #expect(result.caretOffset == 2)
    }

    // MARK: list

    private func templates() throws -> [TemplateInfo] {
        try db.pool.read { try Templates.list(db: $0) }
    }

    private func date(_ minutes: Int) -> Date { now.addingTimeInterval(Double(minutes) * 60) }

    @Test func testListFindsTemplateAndDescendantTagsRecentFirst() throws {
        let a = try store.create(text: "# Old\n#template", now: date(0))
        let b = try store.create(text: "# Meeting\n#template/meeting", now: date(10))
        let c = try store.create(text: "# Deep\n#template/work/standup", now: date(5))
        let list = try templates()
        #expect(list.map(\.id) == [b.id, c.id, a.id])
        #expect(list.map(\.title) == ["Meeting", "Deep", "Old"])
        #expect(list.map(\.tagPath) == ["template/meeting", "template/work/standup", "template"])
        #expect(list[0].modifiedAt == b.modifiedAt)
    }

    @Test func testListIgnoresOtherNotesAndLookalikeTags() throws {
        _ = try store.create(text: "# Plain", now: date(0))
        _ = try store.create(text: "# Plural #templates", now: date(1))
        _ = try store.create(text: "# Nested elsewhere #work/template", now: date(2))
        _ = try store.create(text: "# Mentions template in prose", now: date(3))
        let t = try store.create(text: "# Real #template", now: date(4))
        #expect(try templates().map(\.id) == [t.id])
    }

    @Test func testListExcludesTrashAndArchive() throws {
        let keep = try store.create(text: "# Keep #template", now: date(0))
        let trashed = try store.create(text: "# Trashed #template", now: date(1))
        let archived = try store.create(text: "# Archived #template", now: date(2))
        try store.trash([trashed.id])
        try store.archive([archived.id])
        #expect(try templates().map(\.id) == [keep.id])
    }

    @Test func testListPrefersMostSpecificDirectTag() throws {
        _ = try store.create(text: "# Both\n#template #template/meeting", now: date(0))
        #expect(try templates().map(\.tagPath) == ["template/meeting"])
    }

    @Test func testListFollowsEdits() throws {
        let note = try store.create(text: "# N #template", now: date(0))
        #expect(try templates().count == 1)
        _ = try store.updateText(id: note.id, text: "# N", expectedRevision: note.revision, now: date(1))
        #expect(try templates().isEmpty)
    }

    // MARK: createFromTemplate

    @Test func testCreateFromTemplate() throws {
        let template = try store.create(
            text: "# {{title}} #template/meeting #work\n{{date}} ({{weekday}})\n\n- {{cursor}}", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(title: "Standup"))
        #expect(note.id != template.id)
        #expect(note.text == "# Standup #work\n2026-10-22 (Thursday)\n\n- ")
        #expect(caret == note.text.utf16.count)
        #expect(note.title == "Standup #work")
        #expect(note.location == .notes)
        #expect(try store.note(id: template.id)?.text == template.text)
        #expect(try templates().map(\.id) == [template.id])  // the new note is not a template
    }

    @Test func testCreateFromTemplateWithoutCursor() throws {
        let template = try store.create(text: "# Plain\n#template", now: date(0))
        let (note, caret) = try store.createFromTemplate(templateId: template.id, context: context())
        #expect(note.text == "# Plain")
        #expect(caret == nil)
    }

    @Test func testCreateFromTemplateRejectsLockedTemplate() throws {
        let locked = try store.create(text: "# Secret #template", now: date(0))
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        #expect(throws: StoreError.noteLocked(id: locked.id)) {
            try store.createFromTemplate(templateId: locked.id, context: context())
        }
        #expect(try templates().isEmpty)
    }

    @Test func testCreateFromTemplateUnknownId() throws {
        #expect(throws: StoreError.noteNotFound(id: "missing")) {
            try store.createFromTemplate(templateId: "missing", context: context())
        }
    }
    // MARK: createFromTemplate in a workspace

    @Test func testWorkspaceTagIsAppendedAtTheBottom() throws {
        let template = try store.create(text: "# Meeting #template\n\n- {{cursor}}", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(note.text == "# Meeting\n\n- \n#work")
        #expect(caret == "# Meeting\n\n- ".utf16.count)
        #expect(Workspace(path: "work").includes(tagPath: try #require(NoteParser.metadata(for: note.text).tags.first)))
    }

    @Test func testWorkspaceTagGoesAfterTheTitleLineAtTheTopAndTheCaretFollows() throws {
        let template = try store.create(text: "# Meeting #template\n\n- {{cursor}}", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(note.text == "# Meeting\n#work\n\n- ")
        #expect(caret == note.text.utf16.count)
        // A caret before the insertion point stays.
        let early = try store.create(text: "{{cursor}}# Early #template", now: date(1))
        let (earlyNote, earlyCaret) = try store.createFromTemplate(
            templateId: early.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(earlyNote.text == "# Early\n#work")
        #expect(earlyCaret == 0)
        // A caret at the end of the title line stays before the tag line.
        let atEnd = try store.create(text: "# End #template{{cursor}}", now: date(2))
        let (endNote, endCaret) = try store.createFromTemplate(
            templateId: atEnd.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(endNote.text == "# End\n#work")
        #expect(endCaret == "# End".utf16.count)
    }

    @Test func testTopTagGoesBelowFrontMatter() throws {
        let template = try store.create(text: "---\nkind: log\n---\nBody {{cursor}}\n#template", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(note.text == "---\nkind: log\n---\nBody \n#work")
        #expect(caret == "---\nkind: log\n---\nBody ".utf16.count)
        #expect(note.title == "Body")
    }

    @Test func testATemplateTagInsideTheWorkspaceIsEnough() throws {
        let inside = try store.create(text: "# A #template #work/projects", now: date(0))
        let (note, _) = try store.createFromTemplate(
            templateId: inside.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(note.text == "# A #work/projects")
        // The workspace tag itself, in any spelling.
        let same = try store.create(text: "# B #template #Work", now: date(1))
        let (other, _) = try store.createFromTemplate(
            templateId: same.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(other.text == "# B #Work")
        // A tag outside it does not count.
        let outside = try store.create(text: "# C #template #home", now: date(2))
        let (third, _) = try store.createFromTemplate(
            templateId: outside.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(third.text == "# C #home\n#work")
        // `#template` is not a tag inside any workspace but its own.
        let tagged = try store.create(text: "# D #template", now: date(3))
        let (fourth, _) = try store.createFromTemplate(
            templateId: tagged.id, context: context(), workspace: Workspace(path: "template"), tagPosition: .bottom)
        #expect(fourth.text == "# D\n#template")
    }

    @Test func testNoWorkspaceChangesNothing() throws {
        let template = try store.create(text: "# Plain #template\n{{date}}", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: nil, tagPosition: .top)
        let (reference, referenceCaret) = try store.createFromTemplate(templateId: template.id, context: context())
        #expect(note.text == reference.text)
        #expect(caret == referenceCaret)
    }

    @Test func testWorkspaceTagUsesTheClosedFormWhenNeeded() throws {
        let template = try store.create(text: "# Plain #template", now: date(0))
        let (note, _) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "my work"), tagPosition: .bottom)
        #expect(note.text == "# Plain\n#my work#")
    }

    @Test func testAnEmptyTemplateGetsTheNewNoteLayout() throws {
        let template = try store.create(text: "#template", now: date(0))
        let (bottom, bottomCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(bottom.text == "\n\n#work")
        #expect(bottomCaret == 0)
        let (top, topCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(top.text == "#work\n\n")
        #expect(topCaret == top.text.utf16.count)
    }

    @Test func testWorkspaceOverloadKeepsTheErrors() throws {
        let locked = try store.create(text: "# Secret #template", now: date(0))
        try db.pool.write { try $0.execute(sql: "UPDATE note SET isLocked = 1 WHERE id = ?", arguments: [locked.id]) }
        #expect(throws: StoreError.noteLocked(id: locked.id)) {
            try store.createFromTemplate(
                templateId: locked.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        }
        #expect(throws: StoreError.noteNotFound(id: "missing")) {
            try store.createFromTemplate(
                templateId: "missing", context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        }
    }

    // MARK: extra tags (a new note in a tag scope or a tag search)

    @Test func testExtraTagsAreAddedOnceInOneWrite() throws {
        let template = try store.create(text: "# Meeting #template #projects\n\n- {{cursor}}", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: nil, tagPosition: .bottom,
            extraTags: ["Projects", "home"])
        #expect(note.text == "# Meeting #projects\n\n- \n#home")
        #expect(caret == "# Meeting #projects\n\n- ".utf16.count)
        let (top, topCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: nil, tagPosition: .top, extraTags: ["a", "b c"])
        #expect(top.text == "# Meeting #projects\n#a #b c#\n\n- ")
        #expect(topCaret == top.text.utf16.count)
    }

    @Test func testAnExtraTagInsideTheWorkspaceReplacesTheWorkspaceTag() throws {
        let template = try store.create(text: "# T #template", now: date(0))
        let (inside, _) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom,
            extraTags: ["work/projects"])
        #expect(inside.text == "# T\n#work/projects")
        let (outside, _) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom,
            extraTags: ["home"])
        #expect(outside.text == "# T\n#home #work")
    }

    @Test func testAnInvalidExtraTagThrowsAndCreatesNothing() throws {
        let template = try store.create(text: "# T #template", now: date(0))
        #expect(throws: StoreError.invalidTag(path: "")) {
            try store.createFromTemplate(
                templateId: template.id, context: context(), workspace: nil, tagPosition: .bottom, extraTags: [""])
        }
        #expect(try store.allNotes().count == 1)
    }

    @Test func testAnEmptyTemplateWithExtraTagsGetsTheNewNoteLayout() throws {
        let template = try store.create(text: "#template", now: date(0))
        let (note, caret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: nil, tagPosition: .bottom, extraTags: ["a", "b"])
        #expect(note.text == "\n\n#a #b")
        #expect(caret == 0)
    }

    // MARK: line endings and BOM in the workspace overload

    @Test func testCRLFTemplateKeepsItsCaretWithAWorkspaceTag() throws {
        let template = try store.create(text: "# T #template\r\n\r\nBody {{cursor}}x\r\n", now: date(0))
        let (bottom, bottomCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(bottom.text == "# T\n\nBody x\n\n#work")
        #expect(bottomCaret == "# T\n\nBody ".utf16.count)
        let (top, topCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(top.text == "# T\n#work\n\nBody x\n")
        #expect(topCaret == "# T\n#work\n\nBody ".utf16.count)
    }

    @Test func testBOMTemplateKeepsTheBOMFirstWithAWorkspaceTag() throws {
        let template = try store.create(text: "\u{FEFF}# T #template\nBody {{cursor}}x", now: date(0))
        let (top, topCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .top)
        #expect(top.text == "\u{FEFF}# T\n#work\nBody x")
        #expect(topCaret == "\u{FEFF}# T\n#work\nBody ".utf16.count)
        let (bottom, bottomCaret) = try store.createFromTemplate(
            templateId: template.id, context: context(), workspace: Workspace(path: "work"), tagPosition: .bottom)
        #expect(bottom.text == "\u{FEFF}# T\nBody x\n#work")
        #expect(bottomCaret == "\u{FEFF}# T\nBody ".utf16.count)
    }

    // MARK: #template coming in through a placeholder

    @Test func testTemplateTagInClipboardOrTitleDoesNotMakeATemplate() {
        let result = run("{{clipboard}}\n{{title}}\nBody {{cursor}}x\n#template",
                         context(clipboard: "see #template and #template/meeting today", title: "#Template"))
        #expect(!NoteParser.metadata(for: result.text).tags.contains { Templates.isTemplateTag($0) })
        #expect(result.text.contains("see") && result.text.contains("today") && result.text.contains("Body x"))
        let body = (result.text as NSString).range(of: "Body ")
        #expect(result.caretOffset == body.location + body.length)
        // Other tags from the clipboard stay.
        #expect(run("{{clipboard}}", context(clipboard: "#work #template")).text == "#work")
    }

    @Test func testCaretBeforeAStrippedClipboardTagIsKept() {
        let result = run("A {{cursor}}{{clipboard}}", context(clipboard: "#template"))
        #expect(result.text == "A ")
        #expect(result.caretOffset == 2)
    }
}
