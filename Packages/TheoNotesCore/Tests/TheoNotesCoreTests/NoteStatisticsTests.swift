// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct NoteStatisticsTests {
    private func stats(_ text: String) -> NoteStatistics { NoteStatistics.of(text) }

    @Test func testEmptyText() {
        #expect(stats("") == NoteStatistics(words: 0, characters: 0, paragraphs: 0))
        #expect(stats("\n\n  \n").paragraphs == 0)
        #expect(stats("").readingSeconds == 0)
    }

    @Test func testPlainText() {
        let s = stats("Hello world")
        #expect(s.words == 2)
        #expect(s.characters == 11)
        #expect(s.paragraphs == 1)
    }

    @Test func testCountsTheMarkupStrippedText() {
        // Heading marks, emphasis, link URLs and code ticks are not counted.
        let s = stats("# Title\n\n**Bold** text with [a link](https://example.com/x) and `code`.")
        #expect(s.words == 8)
        #expect(s.characters == "Title".count + "Bold text with a link and code.".count)
        #expect(s.paragraphs == 2)
    }

    @Test func testTagsAndWikiLinksCountAsTheirVisibleWords() {
        #expect(stats("Note #work #my tag#").words == 4)
        #expect(stats("See [[Other Note|the alias]] now").words == 4)
        #expect(stats("See [[Other Note]]").words == 3)
    }

    @Test func testWhitespaceRunsCountAsOneCharacter() {
        let s = stats("  a    b  ")
        #expect(s.characters == 3)
        #expect(s.words == 2)
    }

    @Test func testParagraphsAreNonBlankLines() {
        #expect(stats("a\n\nb\nc").paragraphs == 3)
        // A line with only an image has no visible text.
        #expect(stats("Title\n![](image.png)\n").paragraphs == 1)
        #expect(stats("- [ ] one\n- [x] two").paragraphs == 2)
    }

    @Test func testCodeBlockContentIsCountedButNotItsFences() {
        let s = stats("```swift\nlet x = 1\n```")
        #expect(s.words == 3)
        #expect(s.paragraphs == 1)
    }

    @Test func testPunctuationAloneIsNotAWord() {
        #expect(stats("a - b — c …").words == 3)
        #expect(stats("don't well-known 3.14 e-mail").words == 4)
        #expect(stats("(hello), [world]!").words == 2)
    }

    @Test func testCJKCharactersCountAsWords() {
        // Han, Hiragana and Katakana have no spaces between words: each character is a word.
        #expect(stats("日本語のテキスト").words == 8)
        #expect(stats("中文，测试。").words == 4)
        #expect(stats("Hello世界").words == 3)
        #expect(stats("ｶﾀｶﾅ").words == 4)
        // Korean separates words with spaces.
        #expect(stats("안녕하세요 세계").words == 2)
        #expect(stats("日本語のテキスト").characters == 8)
    }

    @Test func testCharactersAreGraphemes() {
        #expect(stats("👩‍👩‍👧 é").characters == 3)
        #expect(stats("e\u{301}").characters == 1)
    }

    @Test func testReadTimeAt230WordsPerMinute() {
        #expect(NoteStatistics.wordsPerMinute == 230)
        #expect(NoteStatistics(words: 230, characters: 0, paragraphs: 0).readingSeconds == 60)
        #expect(NoteStatistics(words: 460, characters: 0, paragraphs: 0).readingSeconds == 120)
        #expect(NoteStatistics(words: 115, characters: 0, paragraphs: 0).readingSeconds == 30)
        #expect(NoteStatistics(words: 1, characters: 0, paragraphs: 0).readingSeconds == 0)
    }

    @Test func testSelectionTextIsCountedLikeANote() {
        // A selection that starts in the middle of a line is still stripped.
        #expect(stats("bold** and *more*").words == 3)
    }
}
