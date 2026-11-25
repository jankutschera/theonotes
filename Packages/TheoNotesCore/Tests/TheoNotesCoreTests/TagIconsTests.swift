// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import AppKit
import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct TagIconsTests {
    @Test func testTableHasEnoughEntriesAndEverySymbolExists() throws {
        let table = TagIcons.keywordTable
        #expect(table.count >= 150)
        let missing = Set(table.values).union(TagIcons.pickerSymbols).filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
        #expect(missing.isEmpty, "unknown SF Symbols: \(missing.sorted())")
    }

    @Test func testEveryKeywordHasOneSymbol() throws {
        var seen: [String: String] = [:]
        for group in try TagIcons.loadGroups() {
            for keyword in group.keywords {
                let key = TagIcons.fold(keyword)
                if let other = seen[key] {
                    #expect(other == group.symbol, "\(keyword): \(other) vs \(group.symbol)")
                }
                seen[key] = group.symbol
            }
        }
    }

    @Test(arguments: [
        ("work", "briefcase"), ("Arbeit", "briefcase"), ("home", "house"), ("zuhause", "house"),
        ("journal", "book.closed"), ("Tagebuch", "book.closed"), ("idea", "lightbulb"), ("Idee", "lightbulb"),
        ("todo", "checklist"), ("aufgabe", "checklist"), ("travel", "airplane"), ("reise", "airplane"),
        ("recipe", "fork.knife"), ("Rezept", "fork.knife"), ("health", "heart"), ("GESUNDHEIT", "heart"),
        ("money", "eurosign.circle"), ("finanzen", "eurosign.circle"), ("music", "music.note"),
        ("Musik", "music.note"), ("code", "chevron.left.forwardslash.chevron.right"),
    ])
    func testRequiredKeywords(keyword: String, symbol: String) {
        #expect(TagIcons.defaultSymbol(forTagPath: keyword) == symbol)
    }

    @Test func testMatchesLastComponentCaseAndDiacriticInsensitive() {
        #expect(TagIcons.defaultSymbol(forTagPath: "projects/2024/Reise") == "airplane")
        #expect(TagIcons.defaultSymbol(forTagPath: "Büro") == "briefcase")
        #expect(TagIcons.defaultSymbol(forTagPath: "buro") == "briefcase")
        #expect(TagIcons.defaultSymbol(forTagPath: "work/unknownthing") == "number")
        #expect(TagIcons.defaultSymbol(forTagPath: "my tag") == "number")
        #expect(TagIcons.defaultSymbol(forTagPath: "") == "number")
    }

    @Test func testUserIconWins() {
        #expect(TagIcons.symbol(forTagPath: "work", iconName: "hammer") == "hammer")
        #expect(TagIcons.symbol(forTagPath: "work", iconName: nil) == "briefcase")
        #expect(TagIcons.symbol(forTagPath: "work", iconName: "") == "briefcase")
    }

    @Test func testPickerSearch() {
        #expect(TagIcons.pickerSymbols.count >= TagIcons.keywordTable.values.reduce(into: Set<String>()) { $0.insert($1) }.count)
        #expect(TagIcons.pickerSymbols.contains("number"))
        #expect(TagIcons.searchSymbols("").count == TagIcons.pickerSymbols.count)
        // By keyword (any language) and by symbol name.
        #expect(TagIcons.searchSymbols("rezept").contains("fork.knife"))
        #expect(TagIcons.searchSymbols("knife").contains("fork.knife"))
        #expect(TagIcons.searchSymbols("zzzz-none").isEmpty)
    }
}
