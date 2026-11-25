// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct TodoLinesTests {
    @Test func findsOpenAndDoneTodosInOrder() {
        let text = "# Plan\n- [ ] one\ntext\n  * [x] two\n+ [X] three\n- [ ] four"
        let found = TodoLines.all(in: text)
        #expect(found == [
            TodoLine(line: 2, isDone: false, text: "- [ ] one"),
            TodoLine(line: 4, isDone: true, text: "  * [x] two"),
            TodoLine(line: 5, isDone: true, text: "+ [X] three"),
            TodoLine(line: 6, isDone: false, text: "- [ ] four"),
        ])
    }

    @Test func fencedTodoIsNotATodo() {
        let backticks = "```\n- [ ] in code\n```\n- [ ] out"
        #expect(TodoLines.all(in: backticks).map(\.line) == [4])
        let tildes = "~~~\n- [ ] in code\n~~~\n- [x] out"
        #expect(TodoLines.all(in: tildes).map(\.line) == [4])
        #expect(TodoLines.toggled(backticks, line: 2) == nil)
    }

    @Test func toggledFlipsOnlyThatLine() {
        #expect(TodoLines.toggled("- [ ] a\n- [ ] a", line: 2) == "- [ ] a\n- [x] a")
        #expect(TodoLines.toggled("- [ ] a\n- [x] a", line: 2) == "- [ ] a\n- [ ] a")
        #expect(TodoLines.toggled("- [X] a", line: 1) == "- [ ] a")
        #expect(TodoLines.toggled("> - [ ] quoted\r\nnext", line: 1) == "> - [x] quoted\r\nnext")
        #expect(TodoLines.toggled("😀 intro\n\t- [ ] 日本 [ ] again", line: 2) == "😀 intro\n\t- [x] 日本 [ ] again")
    }

    @Test func toggledReturnsNilForAPlainLine() {
        let text = "plain\n- bullet\n1. [ ] ordered\n- [ ] real"
        #expect(TodoLines.toggled(text, line: 1) == nil)
        #expect(TodoLines.toggled(text, line: 2) == nil)
        #expect(TodoLines.toggled(text, line: 3) == nil)
        #expect(TodoLines.toggled(text, line: 0) == nil)
        #expect(TodoLines.toggled(text, line: 9) == nil)
        #expect(TodoLines.toggled(text, line: 4) == "plain\n- bullet\n1. [ ] ordered\n- [x] real")
    }

    @Test func agreesWithNoteStatsCounts() throws {
        let dir = NoteParserFixtureTests.fixtureDir
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 10)
        struct Case: Decodable { let name: String; let input: String }
        var checked = 0
        for file in files {
            let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
            for c in cases {
                let meta = NoteParser.metadata(for: c.input)
                let todos = TodoLines.all(in: c.input)
                #expect(todos.filter { !$0.isDone }.count == meta.openTodos, "\(file.lastPathComponent): \(c.name)")
                #expect(todos.filter(\.isDone).count == meta.doneTodos, "\(file.lastPathComponent): \(c.name)")
                #expect(todos.map(\.line) == todos.map(\.line).sorted())
                for todo in todos {
                    #expect(TodoLines.toggled(c.input, line: todo.line) != nil, "\(file.lastPathComponent): \(c.name)")
                }
                checked += 1
            }
        }
        #expect(checked > 150)
    }
}
