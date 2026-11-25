// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesCore

@Suite struct ChangeSetTests {
    private func decode(_ json: String) throws -> ChangeSet {
        try JSONDecoder().decode(ChangeSet.self, from: Data(json.utf8))
    }

    private func encode(_ cs: ChangeSet) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try enc.encode(cs), as: UTF8.self)
    }

    @Test func testDecodeCodeMirrorJSON() throws {
        let cs = try decode(#"[5,[0,"X"],3]"#)
        #expect(cs.sections == [.retain(5), .replace(deleteLength: 0, insert: "X"), .retain(3)])
        #expect(try encode(cs) == #"[5,[0,"X"],3]"#)
        #expect(cs.oldLength == 8)
        #expect(cs.newLength == 9)
    }

    @Test func testEncodeShapes() throws {
        let multi = ChangeSet(sections: [.replace(deleteLength: 0, insert: "a\nb")])
        #expect(try encode(multi) == #"[[0,"a","b"]]"#)
        let del = ChangeSet(sections: [.retain(1), .replace(deleteLength: 3, insert: "")])
        #expect(try encode(del) == "[1,[3]]")
        #expect(try decode("[1,[3]]") == del)
        #expect(try decode(#"[[2,"a","","b"]]"#).sections == [.replace(deleteLength: 2, insert: "a\n\nb")])
        #expect(try encode(decode(#"[[2,"a","","b"]]"#)) == #"[[2,"a","","b"]]"#)
    }

    @Test func testEncodeSplitsInsertOnLineFeedScalarsOnly() throws {
        // Swift treats "\r\n" as one Character; the encoder must still split at the "\n" scalar.
        let crlf = ChangeSet(sections: [.replace(deleteLength: 0, insert: "a\r\nb")])
        #expect(try encode(crlf) == #"[[0,"a\r","b"]]"#)
        // After normalisation the insert encodes as plain CodeMirror lines.
        let normalized = ChangeSet(sections: [
            .replace(deleteLength: 0, insert: TextNormalization.normalizeLineEndings("x\r\ny\rz")),
        ])
        #expect(try encode(normalized) == #"[[0,"x","y","z"]]"#)
        #expect(try decode(encode(normalized)) == normalized)
    }

    @Test func testDecodeRejectsMalformed() {
        #expect(throws: (any Error).self) { try decode(#"["x"]"#) }
        #expect(throws: (any Error).self) { try decode("[[]]") }
        #expect(throws: (any Error).self) { try decode("[[1,2]]") }
    }

    @Test func testOverflowingLengthsAreRejected() {
        #expect(throws: (any Error).self) { try decode("[9223372036854775807,1]") }
        #expect(throws: (any Error).self) { try decode("[9223372036854775807,[1]]") }
        let cs = ChangeSet(sections: [.retain(Int.max), .retain(1)])
        #expect(cs.oldLength == Int.max)
        #expect(throws: ChangeSetError.lengthOverflow) { try cs.apply(to: "") }
    }

    @Test func testApplyInsertDeleteReplace() throws {
        let cs = try decode(#"[6,[5,"there"]]"#)
        #expect(try cs.apply(to: "hello world") == "hello there")
    }

    @Test func testApplyMultiLineInsert() throws {
        let cs = try decode(#"[0,[0,"a","b"],2]"#)
        #expect(try cs.apply(to: "xy") == "a\nbxy")
    }

    @Test func testApplyChangeSetWithEmojiAndCJK() throws {
        let text = "👩‍👩‍👧 漢字"
        #expect(text.utf16.count == 11)
        let cs = ChangeSet(sections: [.retain(9), .replace(deleteLength: 0, insert: "!"), .retain(2)])
        #expect(try cs.apply(to: text) == "👩‍👩‍👧 !漢字")
    }

    @Test func testLengthMismatchThrows() throws {
        let cs = try decode("[5]")
        #expect(throws: ChangeSetError.lengthMismatch(expected: 5, actual: 2)) {
            try cs.apply(to: "ab")
        }
    }

    @Test func testSplittingSurrogateThrows() throws {
        let cs = ChangeSet(sections: [.retain(1), .replace(deleteLength: 0, insert: "x"), .retain(1)])
        #expect(throws: ChangeSetError.splitsSurrogatePair(offset: 1)) {
            try cs.apply(to: "😀")
        }
        let del = ChangeSet(sections: [.replace(deleteLength: 1, insert: ""), .retain(1)])
        #expect(throws: ChangeSetError.splitsSurrogatePair(offset: 1)) {
            try del.apply(to: "😀")
        }
    }

    @Test func testEmptyChangeSetOnEmptyText() throws {
        #expect(try ChangeSet(sections: []).apply(to: "") == "")
    }

    @Test func testFixtures() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("changeset-") && $0.hasSuffix(".json") }
        #expect(files.count >= 3)
        struct Fixture: Decodable { let before: String; let changeset: ChangeSet; let after: String }
        for name in files {
            let data = try Data(contentsOf: dir.appendingPathComponent(name))
            let fx = try JSONDecoder().decode(Fixture.self, from: data)
            #expect(try fx.changeset.apply(to: fx.before) == fx.after, "fixture \(name)")
        }
    }
}
