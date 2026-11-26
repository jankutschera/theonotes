// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct EditorBridgeProtocolTests {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/bridge")

    private static let editorToHostTypes: Set<String> = [
        "ready", "changes", "scrollChanged", "selectionChanged", "checksum", "error", "headingMenu", "formatState", "openLink", "editLinkRequest",
        "insertAttachments", "quickLook", "attachmentMenu", "pasteAttachments", "attachmentsRefused", "cutAttachments",
        "copyText",
        "requestCompletions", "tableMenu", "calloutMenu", "foldState", "frozenForClose",
    ]
    private static let noteId = "0192f3a4-5b6c-7d8e-9f01-23456789abcd"

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtureDir.appendingPathComponent("messages-\(name).json"))
    }

    /// Compares as parsed JSON so key order and whitespace do not matter.
    private func expectJSON(_ value: some Encodable, equalsFixture name: String) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: fixture(name)) as? NSDictionary
        #expect(encoded != nil && encoded == expected, "\(name): \(String(describing: encoded)) != \(String(describing: expected))")
    }

    @Test func testMessagesRoundTripFixtures() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtureDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("messages-") }
        var decoded = 0
        for file in files {
            let data = try Data(contentsOf: file)
            guard let type = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String,
                  Self.editorToHostTypes.contains(type) else { continue }
            _ = try JSONDecoder().decode(EditorToHostMessage.self, from: data)
            decoded += 1
        }
        #expect(decoded == Self.editorToHostTypes.count + 6) // formatState-, openLink-, requestCompletions-minimal, copyText-html, frozenForClose-untouched, -failed

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("ready")) == .ready(version: 5))
        #expect(EditorBridge.version == 5, "version is 5 on both sides")
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("changes")) == .changes(
            noteId: Self.noteId, txId: "5f0c1d2e-3a4b-4c5d-8e6f-708192a3b4c5", baseRevision: 7, revision: 8,
            changeSet: ChangeSet(sections: [.retain(6), .replace(deleteLength: 5, insert: "there\nfriend"), .retain(4)])
        ))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("selectionChanged"))
            == .selectionChanged(noteId: Self.noteId, anchor: 3, head: 9))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("scrollChanged")) == .scrollChanged(noteId: Self.noteId, scrollTop: 120.5))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("checksum")) == .checksum(
            requestId: "c1d2e3f4-0000-4000-8000-000000000001", noteId: Self.noteId,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("headingMenu"))
            == .headingMenu(HeadingMenuRequest(
                noteId: Self.noteId, menuId: "menu-k3f9-1", line: 3, level: 2, folded: false,
                rect: CaretRect(x: 12, y: 96.5, width: 28, height: 18))))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("tableMenu"))
            == .tableMenu(TableMenuRequest(
                noteId: Self.noteId, menuId: "menu-k3f9-2", row: 0, column: 1, rows: 3, columns: 3,
                rect: CaretRect(x: 240, y: 130, width: 18, height: 18))))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("calloutMenu"))
            == .calloutMenu(CalloutMenuRequest(
                noteId: Self.noteId, menuId: "menu-k3f9-3", calloutType: .warning,
                rect: CaretRect(x: 40, y: 210, width: 18, height: 18))))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("foldState"))
            == .foldState(noteId: Self.noteId, folds: [FoldEntry(line: 3, hash: "1a2b3c4d")!, FoldEntry(line: 12, hash: "00ff00ff")!]))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("copyText"))
            == .copyText(text: "let greeting = \"Hello, Bärchen\"\n\tprint(greeting) 👋", html: nil))
        let table = "<table><tr><th>Name</th><th>Größe</th></tr><tr><td>Bärchen</td><td>👋</td></tr></table>"
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("copyText-html"))
            == .copyText(text: table, html: table))
        try expectJSON(
            HostToEditorMessage.applyCommand(name: .pasteCode, args: ["text": .string("let a = 1\nlet b = 2")]),
            equalsFixture: "applyCommand-pasteCode"
        )
        guard case .error(let message, let stack) = try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("error")) else {
            Issue.record("error fixture did not decode as .error")
            return
        }
        #expect(message == "Applying change set to a document with the wrong length")
        #expect(stack?.hasPrefix("RangeError") == true)

        try expectJSON(HostToEditorMessage.loadNote(
            noteId: Self.noteId, text: "# Title\nsome **bold** 👩‍👩‍👧 漢字", revision: 7, readOnly: false,
            selection: SelectionRange(anchor: 7, head: 7), scrollTop: 120
        ), equalsFixture: "loadNote")
        try expectJSON(HostToEditorMessage.loadNote(noteId: Self.noteId, text: "", revision: 0, readOnly: true),
                       equalsFixture: "loadNote-minimal")
        try expectJSON(HostToEditorMessage.loadNote(
            noteId: Self.noteId, text: "# Title\nbody\n## Section\nmore", revision: 7, readOnly: false,
            selection: SelectionRange(anchor: 0, head: 0),
            foldState: [FoldEntry(line: 1, hash: "9c1e5a07")!, FoldEntry(line: 3, hash: "4d2f8b10")!]
        ), equalsFixture: "loadNote-foldState")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(typewriterMode: true)), equalsFixture: "setSettings-typewriterMode")
        try expectJSON(HostToEditorMessage.selectRange(noteId: Self.noteId, anchor: 5, head: 12), equalsFixture: "selectRange")
        try expectJSON(HostToEditorMessage.applyCommand(
            name: .tableMoveRow, args: ["direction": .string("down"), "menuId": .string("menu-k3f9-2")]
        ), equalsFixture: "applyCommand-menuId")
        try expectJSON(HostToEditorMessage.applyCommand(name: .insertMath, args: ["display": .bool(true)]),
                       equalsFixture: "applyCommand-insertMath")
        try expectJSON(HostToEditorMessage.applyExternalChange(
            noteId: Self.noteId, revision: 8,
            changeSet: ChangeSet(sections: [.retain(31), .replace(deleteLength: 0, insert: "!"), .retain(2)])
        ), equalsFixture: "applyExternalChange")
        try expectJSON(HostToEditorMessage.setRevision(noteId: Self.noteId, revision: 9), equalsFixture: "setRevision")
        try expectJSON(HostToEditorMessage.focus, equalsFixture: "focus")
        try expectJSON(HostToEditorMessage.requestChecksum(requestId: "c1d2e3f4-0000-4000-8000-000000000001"),
                       equalsFixture: "requestChecksum")
        try expectJSON(HostToEditorMessage.searchHighlight(
            noteId: Self.noteId, query: "Müller \"bear faq\" #work -old", terms: ["Müller", "bear faq", "#work"]
        ), equalsFixture: "searchHighlight")
        try expectJSON(HostToEditorMessage.searchHighlight(noteId: Self.noteId, query: "", terms: []),
                       equalsFixture: "searchHighlight-clear")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(
            hideMarkdown: false, autoSortTodos: true, showHeadingLevels: false, autocomplete: false, typewriterMode: true,
            typography: EditorTypography(
                fontSize: 18, lineHeight: 1.5, lineWidth: 640, paragraphSpacing: 0.5, paragraphIndent: 1.5,
                fontText: "Iowan Old Style", fontHeading: "Avenir Next", fontCode: "Menlo"),
            theme: ["--bc-color-text": "#eeeeee", "--bc-color-bg": "#1e1e1e"],
            appearance: .dark, reduceMotion: true
        )), equalsFixture: "setSettings-all")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(
            theme: [
                "--bc-color-text": "#d8dee9", "--bc-color-bg": "#2e3440", "--bc-color-selection": "#434c5eb3",
                "--bc-color-popup-bg": "#3b4252",
            ],
            appearance: .dark, reduceMotion: false
        )), equalsFixture: "setSettings-appearance")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(
            typography: EditorTypography(paragraphIndent: 2, fontText: "Iowan Old Style", fontCode: "SF Mono")
        )), equalsFixture: "setSettings-fonts")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(showHeadingLevels: false)),
                       equalsFixture: "setSettings-showHeadingLevels")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(hideMarkdown: true)), equalsFixture: "setSettings-hideMarkdown")

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("formatState")) == .formatState(
            noteId: Self.noteId,
            state: FormatState(active: [.bold, .highlight, .heading], headingLevel: 2, inTodo: false, inCode: false, canIndent: false)
        ))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("formatState-minimal")) == .formatState(
            noteId: Self.noteId, state: FormatState(active: [], headingLevel: nil, inTodo: true, inCode: false, canIndent: true)
        ))
        try expectJSON(HostToEditorMessage.applyCommand(name: .heading, args: ["level": .int(2)]), equalsFixture: "applyCommand")
        try expectJSON(HostToEditorMessage.applyCommand(name: .bold), equalsFixture: "applyCommand-minimal")
        try expectJSON(HostToEditorMessage.scrollToHeading(noteId: Self.noteId, index: 2), equalsFixture: "scrollToHeading")

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("openLink")) == .openLink(OpenLinkRequest(
            noteId: Self.noteId, kind: .wiki, target: "Project Plan", heading: "Next Steps", newWindow: false
        )))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("openLink-minimal")) == .openLink(OpenLinkRequest(
            noteId: Self.noteId, kind: .url, target: "https://example.com", heading: nil, newWindow: true
        )))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("editLinkRequest")) == .editLinkRequest(EditLinkRequest(
            noteId: Self.noteId, requestId: "link-7k2-3", from: 4, to: 9, title: "hello", url: "https://example.com",
            editing: true, caretRect: CaretRect(x: 120.5, y: 48, width: 1, height: 18)
        )))
        try expectJSON(HostToEditorMessage.applyCommand(name: .replaceRange, args: [
            "from": .int(5), "to": .int(19), "expect": .string("![](a%20b.png)"), "text": .string("![](c.png)"),
        ]), equalsFixture: "applyCommand-replaceRange")

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("insertAttachments")) == .insertAttachments(
            noteId: Self.noteId, insertId: "ins-1", items: [
                AttachmentUpload(filename: "image.png", dataBase64: "iVBORw0KGgo="),
                AttachmentUpload(filename: "Report 2.pdf", dataBase64: "JVBERi0="),
            ]))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("quickLook"))
            == .quickLook(noteId: Self.noteId, filename: "photo 2.jpg"))
        let tap = Data(#"{"type":"attachmentTap","noteId":"n","filename":"a.png","from":2,"to":12,"source":"![](a.png)"}"#.utf8)
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: tap) == .attachmentTap(noteId: "n", filename: "a.png", from: 2, to: 12, source: "![](a.png)"))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditorToHostMessage.self, from: Data(#"{"type":"attachmentTap","noteId":"n","filename":"a.png","from":12,"to":2,"source":"x"}"#.utf8))
        }
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("attachmentMenu")) == .attachmentMenu(
            noteId: Self.noteId, filename: "Report 2.pdf", from: 5, to: 77,
            source: #"[Report 2.pdf](Report%202.pdf)<!-- {"preview":"true","embed":"true"} -->"#))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("pasteAttachments")) == .pasteAttachments(
            noteId: Self.noteId, insertId: "ins-2", sourceNoteId: "0192f3a4-5b6c-7d8e-9f01-000000000000",
            text: "see ![](photo%202.jpg)", items: [PastedAttachment(from: 4, to: 22, filename: "photo 2.jpg")]))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("cutAttachments"))
            == .cutAttachments(noteId: Self.noteId, filenames: ["photo 2.jpg", "Report.pdf"]))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EditorToHostMessage.self, from: Data(#"{"type":"cutAttachments","noteId":"n","filenames":[]}"#.utf8))
        }
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("attachmentsRefused"))
            == .attachmentsRefused(noteId: Self.noteId, filenames: ["Holiday.mov"]))
        for bad in [#"{"type":"insertAttachments","noteId":"n","insertId":"i","items":[]}"#,
                    #"{"type":"insertAttachments","noteId":"n","insertId":"","items":[{"filename":"a","dataBase64":""}]}"#,
                    #"{"type":"insertAttachments","noteId":"n","insertId":"i","items":[{"filename":"","dataBase64":""}]}"#,
                    #"{"type":"pasteAttachments","noteId":"n","insertId":"i","sourceNoteId":"s","text":"","items":[{"from":3,"to":2,"filename":"a"}]}"#,
                    #"{"type":"attachmentsRefused","noteId":"n","reason":"other","filenames":["a"]}"#,
                    #"{"type":"quickLook","noteId":"n","filename":""}"#,
                    #"{"type":"attachmentMenu","noteId":"n","filename":"","from":0,"to":1,"source":"x"}"#,
                    #"{"type":"attachmentMenu","noteId":"n","filename":"a","from":5,"to":4,"source":""}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(bad.utf8)) }
        }
        // Over the per-file cap (one base64 character too many).
        let tooLong = String(repeating: "A", count: EditorBridge.base64Length(EditorBridge.maxAttachmentBytes) + 4)
        let big = #"{"type":"insertAttachments","noteId":"n","insertId":"i","items":[{"filename":"a","dataBase64":""# + tooLong + #""}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(big.utf8)) }

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("requestCompletions")) == .requestCompletions(
            CompletionRequest(noteId: Self.noteId, requestId: "complete-k3x9-7", kind: .heading, query: "Ne", noteTitle: "Project Plan")
        ))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("requestCompletions-minimal")) == .requestCompletions(
            CompletionRequest(noteId: Self.noteId, requestId: "complete-k3x9-8", kind: .tag, query: "wo", noteTitle: nil)
        ))
        try expectJSON(HostToEditorMessage.completionResults(requestId: "complete-k3x9-8", items: [
            CompletionItem(label: "work", insert: "#work ", detail: "12", icon: "briefcase"),
            CompletionItem(label: "🐈 cat", insert: "🐈"),
        ]), equalsFixture: "completionResults")
        try expectJSON(HostToEditorMessage.tagIcons(["work": "briefcase", "work/projects": "folder.fill", "reisen": "airplane"]),
                       equalsFixture: "tagIcons")
        try expectJSON(HostToEditorMessage.setSettings(EditorSettings(autocomplete: false)), equalsFixture: "setSettings")

        try expectJSON(ChangesReply.acked(revision: 8), equalsFixture: "changesReply-acked")
        try expectJSON(ChangesReply.duplicate(revision: 8), equalsFixture: "changesReply-duplicate")
        try expectJSON(ChangesReply.needsFullText(currentRevision: 12), equalsFixture: "changesReply-needsFullText")
    }

    /// The JS registry (`COMMAND_NAMES`) checks the same fixture.
    @Test func testCommandNamesMatchFixture() throws {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("command-names.json"))
        let names = try JSONDecoder().decode([String].self, from: data)
        #expect(EditorCommandName.allCases.map(\.rawValue) == names)
    }

    @Test func testCommandArgumentsEncodeAsPlainJSONValues() throws {
        let message = HostToEditorMessage.applyCommand(
            name: .setLink, args: ["from": .int(0), "to": .int(4), "title": .string("Bear"), "url": .string("https://example.com")]
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? NSDictionary
        #expect(json == ["type": "applyCommand", "name": "setLink", "args": ["from": 0, "to": 4, "title": "Bear", "url": "https://example.com"]])
    }

    @Test func testCommandArgumentsKeepTheirJSONType() throws {
        let decoded = try JSONDecoder().decode(
            [String: CommandArgument].self, from: Data(#"{"a":1,"b":true,"c":"x","d":false,"e":0}"#.utf8))
        #expect(decoded == ["a": .int(1), "b": .bool(true), "c": .string("x"), "d": .bool(false), "e": .int(0)])
    }

    @Test func testCalloutTypesAreBearsFive() {
        #expect(CalloutType.allCases.map(\.rawValue) == ["note", "tip", "important", "warning", "caution"])
    }

    @Test func testMenuMessagesRejectMalformedFields() {
        let rect = #""rect":{"x":0,"y":0,"width":1,"height":15}"#
        let good = [
            #"{"type":"headingMenu","noteId":"n","menuId":"m","line":1,"level":2,"folded":false,"# + rect + "}",
            #"{"type":"tableMenu","noteId":"n","menuId":"m","row":0,"column":2,"rows":3,"columns":3,"# + rect + "}",
            #"{"type":"calloutMenu","noteId":"n","menuId":"m","calloutType":"tip","# + rect + "}",
            #"{"type":"foldState","noteId":"n","folds":[]}"#,
        ]
        for json in good { #expect(throws: Never.self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(json.utf8)) } }
        let bad = [
            #"{"type":"headingMenu","noteId":"n","line":1,"level":2}"#, // the v2 shape: no menuId, folded, rect
            #"{"type":"headingMenu","noteId":"n","menuId":"m","line":1,"level":2,"folded":false}"#, // without rect
            #"{"type":"headingMenu","noteId":"n","menuId":"","line":1,"level":2,"folded":false,"# + rect + "}",
            #"{"type":"headingMenu","noteId":"n","menuId":"m","line":0,"level":2,"folded":false,"# + rect + "}",
            #"{"type":"headingMenu","noteId":"n","menuId":"m","line":1,"level":7,"folded":false,"# + rect + "}",
            #"{"type":"tableMenu","noteId":"n","menuId":"m","row":3,"column":0,"rows":3,"columns":3,"# + rect + "}",
            #"{"type":"tableMenu","noteId":"n","menuId":"m","row":0,"column":3,"rows":3,"columns":3,"# + rect + "}",
            #"{"type":"tableMenu","noteId":"n","menuId":"m","row":-1,"column":0,"rows":3,"columns":3,"# + rect + "}",
            #"{"type":"calloutMenu","noteId":"n","menuId":"m","calloutType":"info","# + rect + "}",
            #"{"type":"foldState","noteId":"n","folds":"no"}"#,
            #"{"type":"foldState","noteId":"n"}"#,
        ]
        for json in bad {
            #expect(throws: DecodingError.self, "\(json)") { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(json.utf8)) }
        }
    }

    @Test func testFoldEntriesAreValidatedWhereTheyAreMade() {
        #expect(FoldEntry(line: 1, hash: "0a1b2c3d") != nil)
        #expect(FoldEntry(line: 0, hash: "0a1b2c3d") == nil)
        #expect(FoldEntry(line: -3, hash: "0a1b2c3d") == nil)
        #expect(FoldEntry(line: 1, hash: "0A1B2C3D") == nil)
        #expect(FoldEntry(line: 1, hash: "0a1b2c3") == nil)
        #expect(FoldEntry(line: 1, hash: "0a1b2c3d4") == nil)
        #expect(FoldEntry(line: 1, hash: "0a1b2c3g") == nil)
        #expect(FoldEntry(line: 1, hash: "") == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FoldEntry.self, from: Data(#"{"line":0,"hash":"0a1b2c3d"}"#.utf8))
        }
    }

    /// A damaged fold list never stops a note from opening: invalid entries are dropped one by
    /// one, the list is capped.
    @Test func testFoldStateDropsInvalidEntriesAndCaps() throws {
        let json = #"{"type":"foldState","noteId":"n","folds":[{"line":3,"hash":"0a1b2c3d"},{"line":0,"hash":"0a1b2c3d"},"#
            + #"{"line":1,"hash":"XYZ"},7,null,"x",{"line":2},{"line":9,"hash":"ffffffff"}]}"#
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: Data(json.utf8)) == .foldState(
            noteId: "n", folds: [FoldEntry(line: 3, hash: "0a1b2c3d")!, FoldEntry(line: 9, hash: "ffffffff")!]))

        let entries = (1...(EditorBridge.maxFolds + 50)).map { #"{"line":\#($0),"hash":"0a1b2c3d"}"# }.joined(separator: ",")
        let big = #"{"type":"foldState","noteId":"n","folds":["# + entries + "]}"
        guard case .foldState(_, let folds) = try JSONDecoder().decode(EditorToHostMessage.self, from: Data(big.utf8)) else {
            Issue.record("not a foldState")
            return
        }
        #expect(EditorBridge.maxFolds == 10_000)
        #expect(folds.count == EditorBridge.maxFolds && folds.last?.line == EditorBridge.maxFolds)

        // Outgoing lists are cut as well.
        let many = (1...(EditorBridge.maxFolds + 5)).map { FoldEntry(line: $0, hash: "0a1b2c3d")! }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            HostToEditorMessage.loadNote(noteId: "n", text: "", revision: 0, readOnly: false, foldState: many))) as? [String: Any]
        #expect((encoded?["foldState"] as? [Any])?.count == EditorBridge.maxFolds)
    }

    @Test func testFormatStateRejectsUnknownCommandsAndLevels() {
        let unknown = #"{"type":"formatState","noteId":"n","active":["nope"],"inTodo":false,"inCode":false,"canIndent":false}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(unknown.utf8)) }
        let level = #"{"type":"formatState","noteId":"n","active":[],"headingLevel":9,"inTodo":false,"inCode":false,"canIndent":false}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(level.utf8)) }
    }

    @Test func testLinkMessagesRejectBadKindsAndRanges() {
        let kind = #"{"type":"openLink","noteId":"n","kind":"file","target":"x","newWindow":false}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(kind.utf8)) }
        let rect = #""caretRect":{"x":0,"y":0,"width":1,"height":15}"#
        let reversed = #"{"type":"editLinkRequest","noteId":"n","requestId":"r","from":5,"to":2,"title":"","url":"","editing":false,"# + rect + "}"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(reversed.utf8)) }
        let negative = #"{"type":"editLinkRequest","noteId":"n","requestId":"r","from":-1,"to":2,"title":"","url":"","editing":false,"# + rect + "}"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(negative.utf8)) }
    }

    @Test func testCompletionRequestsRejectUnknownKinds() {
        let kind = #"{"type":"requestCompletions","noteId":"n","requestId":"r","kind":"file","query":""}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(kind.utf8)) }
        #expect(CompletionKind.allCases.map(\.rawValue) == ["tag", "note", "heading", "emoji"])
    }

    /// Swift never sends an unsanitized theme map. The encoding is the one place every
    /// `setSettings` passes through, so it holds for any caller.
    @Test func testSetSettingsNeverSendsAnUnsanitizedThemeMap() throws {
        let dirty = [
            "--bc-color-text": "#eeeeee",
            "--bc-color-bg": "#1e1e1eff",
            "--bc-nonsense": "#ffffff",
            "--bc-size": "#ffffff",
            "color-text": "#ffffff",
            "--bc-color-accent": "red",
            "--bc-color-link": "#fff;} body{x:y",
            "--bc-color-tag": "rgb(1, 2, 3)",
        ]
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HostToEditorMessage.setSettings(EditorSettings(theme: dirty)))) as? [String: Any]
        let sent = try #require(json?["theme"] as? [String: String])
        #expect(sent == ["--bc-color-text": "#eeeeee", "--bc-color-bg": "#1e1e1eff"])
        #expect(sent == ThemeSchema.sanitize(variables: dirty))

        // A whole theme of the catalog goes through unchanged: its variables are already schema tokens.
        let theme = try #require(ThemeCatalog.all().first)
        let all = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HostToEditorMessage.setSettings(EditorSettings(theme: theme.editorVariables)))) as? [String: Any]
        #expect(all?["theme"] as? [String: String] == theme.editorVariables)
        #expect(theme.editorVariables.count == ThemeSchema.editorTokens.count)

        // No theme in the settings: no theme key.
        let none = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HostToEditorMessage.setSettings(EditorSettings()))) as? [String: Any]
        #expect(none?["theme"] == nil)
    }

    /// The editor rejects a whole `setSettings` for a font it cannot put in a declaration; Swift drops the font instead.
    @Test func testSetSettingsDropsFontsTheEditorWouldReject() throws {
        for bad in ["A\"B", "A;color:red", "A}", "A{", "A<b>", "A\\B", "A\nB", "A\rB", String(repeating: "x", count: 101), ""] {
            #expect(!EditorTypography.isValidFontFamily(bad), "\(bad.debugDescription)")
        }
        // CRLF is one Character in Swift but two line-break scalars; the editor's regex rejects it.
        #expect(!EditorTypography.isValidFontFamily("A\r\nB"))
        #expect(!EditorTypography.isValidFontFamily("\r\n"))
        // The editor counts UTF-16 units: 50 emoji are 100 units (valid), 51 are 102 (invalid) though only 51 characters.
        #expect(EditorTypography.isValidFontFamily(String(repeating: "😀", count: 50)))
        #expect(!EditorTypography.isValidFontFamily(String(repeating: "😀", count: 51)))
        #expect(EditorTypography.isValidFontFamily("Iowan Old Style"))
        #expect(EditorTypography(fontText: "A\"B", fontHeading: "Avenir Next", fontCode: String(repeating: "😀", count: 51)).invalidFonts.map(\.field)
                == ["fontText", "fontCode"])
        #expect(EditorTypography(fontCode: String(repeating: "😀", count: 51)).invalidFonts.first?.length == 102)
        #expect(EditorTypography.isValidFontFamily(String(repeating: "x", count: 100)))
        let typography = EditorTypography(paragraphIndent: 1, fontText: "A\"B", fontHeading: "Avenir Next", fontCode: "")
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(HostToEditorMessage.setSettings(EditorSettings(typography: typography)))) as? [String: Any]
        let sent = try #require(json?["typography"] as? [String: Any])
        #expect(Set(sent.keys) == ["paragraphIndent", "fontHeading"])
    }

    /// W1, capture close: the freeze, its unfreeze and the three kinds of reply.
    @Test func testCaptureCloseMessagesMatchTheFixtures() throws {
        let request = "f7a1c2d3-0000-4000-8000-000000000002"
        try expectJSON(HostToEditorMessage.freezeForClose(requestId: request, noteId: Self.noteId), equalsFixture: "freezeForClose")
        try expectJSON(HostToEditorMessage.unfreeze(requestId: request, noteId: Self.noteId), equalsFixture: "unfreeze")

        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("frozenForClose")) == .frozenForClose(
            FrozenForClose(
                requestId: request, noteId: Self.noteId, ok: true, editedSinceLoad: true,
                sha256: "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4",
                lastAckedTxId: "5f0c1d2e-3a4b-4c5d-8e6f-708192a3b4c5", reason: nil)))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("frozenForClose-untouched")) == .frozenForClose(
            FrozenForClose(
                requestId: request, noteId: Self.noteId, ok: true, editedSinceLoad: false,
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", lastAckedTxId: nil, reason: nil)))
        #expect(try JSONDecoder().decode(EditorToHostMessage.self, from: fixture("frozenForClose-failed")) == .frozenForClose(
            FrozenForClose(
                requestId: request, noteId: Self.noteId, ok: false, editedSinceLoad: true, sha256: nil, lastAckedTxId: nil,
                reason: .timeout)))
    }

    @Test func testFrozenForCloseRejectsReplyThatContradictsItself() {
        let sha = String(repeating: "a", count: 64)
        let head = #"{"type":"frozenForClose","requestId":"r","noteId":"n","editedSinceLoad":false,"#
        for bad in [
            head + #""ok":true}"#,  // ok without a hash
            head + #""ok":true,"sha256":"\#(sha)","reason":"timeout"}"#,  // ok with a reason
            head + #""ok":true,"sha256":"ABC"}"#,  // not a hash
            head + #""ok":false}"#,  // failed without a reason
            head + #""ok":false,"reason":"timeout","sha256":"\#(sha)"}"#,  // failed with a hash
            head + #""ok":false,"reason":"because"}"#,  // unknown reason
            #"{"type":"frozenForClose","requestId":"","noteId":"n","editedSinceLoad":false,"ok":false,"reason":"timeout"}"#,
            head + #""ok":true,"sha256":"\#(sha)","lastAckedTxId":""}"#,
        ] {
            #expect(throws: DecodingError.self, "\(bad)") { try JSONDecoder().decode(EditorToHostMessage.self, from: Data(bad.utf8)) }
        }
    }

    @Test func testChangesReplyMirrorsApplyResult() {
        #expect(ChangesReply(.acked(revision: 3)) == .acked(revision: 3))
        #expect(ChangesReply(.duplicate(revision: 3)) == .duplicate(revision: 3))
        #expect(ChangesReply(.needsFullText(currentRevision: 2)) == .needsFullText(currentRevision: 2))
    }

    @Test func testDecodeRejectsUnknownTypeAndHostMessages() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditorToHostMessage.self, from: Data(#"{"type":"bogus"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditorToHostMessage.self, from: try fixture("loadNote"))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditorToHostMessage.self, from: Data(#"{"type":"ready"}"#.utf8))
        }
    }
}
