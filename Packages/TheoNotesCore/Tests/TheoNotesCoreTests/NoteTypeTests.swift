// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Testing
@testable import TheoNotesCore

@Suite struct NoteTypeTests {
    @Test func reservedMatchIsCaseInsensitiveAndExact() {
        #expect(NoteType.reserved(tagPath: "Idea") == .idea)
        #expect(NoteType.reserved(tagPath: "REF") == .reference)
        #expect(NoteType.reserved(tagPath: "ref/recipes") == nil)
        #expect(NoteType.reserved(tagPath: "logs") == nil)
    }

    @Test func firstReservedWins() {
        #expect(NoteType.of(directTags: ["work", "log", "idea"]) == .log)
    }

    @Test func settingAppendsOnOwnLine() {
        #expect(NoteTypeText.setting(.idea, in: "# T\nbody") == "# T\nbody\n\n#idea")
        #expect(NoteTypeText.setting(.idea, in: "# T\nbody\n\n") == "# T\nbody\n\n#idea")
    }

    @Test func changeReplacesInPlace() {
        #expect(NoteTypeText.setting(.log, in: "# T\n#idea and text") == "# T\n#log and text")
    }

    @Test func changeRemovesOtherReservedTags() {
        #expect(NoteTypeText.setting(.reference, in: "# T\n#log x #idea") == "# T\n#ref x")
    }

    @Test func clearRemovesTagAndEmptyLine() {
        #expect(NoteTypeText.setting(nil, in: "# T\nbody\n\n#idea") == "# T\nbody")
        #expect(NoteTypeText.setting(nil, in: "# T\n#idea and text") == "# T\nand text")
    }

    @Test func settingIgnoresCode() {
        #expect(NoteTypeText.setting(.idea, in: "# T\n`#log`") == "# T\n`#log`\n\n#idea")
    }

    @Test func settingSameTypeIsNoOp() {
        let text = "# T\nbody\n\n#idea"
        #expect(NoteTypeText.setting(.idea, in: text) == text)
    }

    @Test func clearMidNoteCollapsesBlankLine() {
        #expect(NoteTypeText.setting(nil, in: "# T\nbody\n\n#idea\n\nmore") == "# T\nbody\n\nmore")
    }

    @Test func clearKeepsTrailingNewline() {
        #expect(NoteTypeText.setting(nil, in: "# T\nbody\n\n#idea\n") == "# T\nbody\n")
    }

    @Test func clearHandlesCRLF() {
        #expect(NoteTypeText.setting(nil, in: "# T\r\nbody\r\n\r\n#idea") == "# T\r\nbody")
    }

    @Test func changeRemovesOtherReservedTagsAcrossLines() {
        #expect(NoteTypeText.setting(.reference, in: "#log\nx\n#idea") == "#ref\nx")
    }

    @Test func duplicateReservedNormalizesToOne() {
        #expect(NoteTypeText.setting(.idea, in: "# T\n#idea a #idea") == "# T\n#idea a")
    }

    @Test func clearKeepsParagraphBreakBeforeFollowingText() {
        #expect(NoteTypeText.setting(nil, in: "a\n\n#idea\nb") == "a\n\nb")
    }

    @Test func tagInsideUnclosedFenceDoesNotTakeEffect() {
        let text = "# T\n```\ncode"
        #expect(NoteTypeText.settingIfEffective(.idea, in: text) == nil)
        #expect(NoteTypeText.settingIfEffective(.idea, in: "# T\nbody") == "# T\nbody\n\n#idea")
        #expect(NoteTypeText.settingIfEffective(nil, in: "# T\nbody") == "# T\nbody")
    }
}
