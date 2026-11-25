// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

@Suite struct CommandTableContractTests {
    @Test func tableMatchesContractFixture() throws {
        let contract = try ContractFixture.load()
        #expect(CommandTable.all.count == contract.commands.count)
        for c in contract.commands {
            let spec = try #require(CommandTable.spec(c.path))
            #expect(Set(spec.options.map(\.long)).subtracting(["--data-dir", "--template"]) == Set(c.options.map(\.long) + c.flags))
            #expect(spec.defaultFields == c.defaultFields && spec.allFields == c.allFields)
        }
    }

    @Test func optionsKeepShortFormsAliasesDefaultsAndEscapes() throws {
        for c in try ContractFixture.load().commands {
            let spec = try #require(CommandTable.spec(c.path))
            for expected in c.options {
                let option = try #require(spec.option(named: expected.long), "\(c.path) \(expected.long)")
                #expect(option.short.map(String.init) == expected.short?.replacingOccurrences(of: "-", with: ""))
                #expect(option.aliases == expected.aliases)
                #expect(option.valueName == expected.value)
                #expect(option.defaultValue == expected.defaultValue)
                #expect(option.escapes == expected.escapes, "\(c.path) \(expected.long)")
            }
            for flag in c.flags {
                #expect(try #require(spec.option(named: flag)).isFlag, "\(c.path) \(flag)")
            }
        }
    }

    @Test func argumentsFormatAndExtraFieldsMatchContract() throws {
        for c in try ContractFixture.load().commands {
            let spec = try #require(CommandTable.spec(c.path))
            #expect(spec.arguments.map(\.name) == c.arguments.map(\.name))
            #expect(spec.arguments.map(\.variadic) == c.arguments.map(\.variadic))
            #expect(spec.acceptsFormat == c.acceptsFormat)
            #expect(spec.extraFields == c.extraFields)
            #expect(!spec.allFields.contains("content"))
            #expect((spec.option(named: "--format") != nil) == c.acceptsFormat)
        }
    }

    @Test func groupDefaultsMatchContract() throws {
        let contract = try ContractFixture.load()
        for (group, fallback) in contract.groups {
            #expect(CommandTable.groupDefaults[group] == fallback, "\(group)")
        }
        #expect(CommandTable.groupDefaults.count == contract.groups.values.compactMap { $0 }.count)
        for c in contract.commands where c.defaultSubcommand {
            #expect(CommandTable.groupDefaults[c.path[0]] == c.path[1])
        }
    }

    @Test func extensionsBeyondBearcli() throws {
        for spec in CommandTable.all {
            let dataDir = try #require(spec.option(named: "--data-dir"))
            #expect(dataDir.valueName == "path" && !dataDir.escapes)
            #expect((spec.option(named: "--template") != nil) == (spec.path == ["create"]))
        }
        let template = try #require(CommandTable.spec(["create"])?.option(named: "--template"))
        #expect(template.valueName == "template" && !template.escapes)
    }

    @Test func textFlagsOfBatchedEditsRepeat() throws {
        let edit = try #require(CommandTable.spec(["edit"]))
        for name in ["--find", "--replace", "--insert-after", "--insert-before", "--delete"] {
            #expect(try #require(edit.option(named: name)).repeatable, "\(name)")
        }
        #expect(!(try #require(edit.option(named: "--title"))).repeatable)
    }

    @Test func integerOptionsAreMarked() throws {
        let integers = Set(CommandTable.all.flatMap { $0.options.filter(\.integer).map(\.long) })
        #expect(integers == ["--limit", "--offset", "--context", "--selection-offset", "--selection-length"])
    }

    @Test func contentFromStdinIsDeclaredForTheCommandsThatReadIt() {
        let reading = CommandTable.all.filter(\.readsContentFromStdin).map { $0.path.joined(separator: " ") }
        #expect(Set(reading) == ["create", "append", "overwrite", "attachments add"])
    }

    @Test func topLevelNamesAndGroupsFollowTheReference() {
        #expect(CommandTable.topLevelNames == [
            "list", "search", "cat", "show", "outline", "search-in", "create", "append", "edit", "overwrite", "tags",
            "attachments", "pin", "trash", "archive", "restore", "app", "mcp-server",
        ])
        #expect(CommandTable.groups["tags"] == ["list", "add", "remove", "rename", "delete"])
        #expect(CommandTable.groups["app"] == ["open", "get-selection"])
    }
}
