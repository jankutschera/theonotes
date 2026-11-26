// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

/// The tool schemas we own (Fixtures/mcp/tool-schemas.json: names, annotations and schemas, no prose), our
/// descriptions (Fixtures/mcp/descriptions.json) and the observed probe data
/// (Fixtures/cli/cli-observed.json), read from the repository.
enum MCPFixtures {
    static var root: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    static func load(_ path: String) throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: root.appendingPathComponent(path)))
    }

    static func schemaTools() throws -> [JSONValue] {
        try #require(load("Fixtures/mcp/tool-schemas.json")["tools"]?.array)
    }

    static func descriptions() throws -> JSONValue {
        try load("Fixtures/mcp/descriptions.json")
    }

    static func observedFacts() throws -> JSONValue {
        try #require(load("Fixtures/cli/cli-observed.json")["facts"])
    }

    /// The value at a slot path such as `create_note/inputSchema/properties/title`: the first segment is the
    /// tool name, the others are object keys.
    static func value(at path: String, in tools: [JSONValue]) -> JSONValue? {
        let parts = path.split(separator: "/").map(String.init)
        guard let tool = tools.first(where: { $0["name"]?.string == parts.first }) else { return nil }
        var current: JSONValue? = tool
        for part in parts.dropFirst() { current = current?[part] }
        return current
    }
}

@Suite struct MCPCatalogTests {
    /// Names, titles, annotations and schemas (property names, types, required lists, enums) are interface facts
    /// held in the schema fixture; the catalog is that fixture plus our descriptions, nothing else.
    @Test func catalogSchemasAndAnnotationsEqualTheSchemaFixtureIgnoringDescriptions() throws {
        let schemas = try MCPFixtures.schemaTools()
        let names = schemas.compactMap { $0["name"]?.string }
        #expect(schemas.count == 26)
        #expect(Array(MCPToolCatalog.toolNames.prefix(26)) == names)
        #expect(Array(MCPToolCatalog.toolNames.suffix(2)) == ["create_note_from_template", "capture_thought"])
        #expect(MCPToolCatalog.tools.count == 28)
        for (ours, theirs) in zip(MCPToolCatalog.tools.prefix(26), schemas) {
            #expect(ours.removingKeys("description") == theirs, "\(ours["name"]?.string ?? "")")
        }
        // The fixture is structure only: no description of any kind in it.
        let text = try String(contentsOf: MCPFixtures.root.appendingPathComponent("Fixtures/mcp/tool-schemas.json"), encoding: .utf8)
        #expect(!text.contains("\"description\""))
    }

    @Test func catalogMatchesTheToolNamesObservedFromTheReferenceServer() throws {
        let facts = try MCPFixtures.observedFacts()
        let observed = try #require(facts["mcpToolNames"]?.array).compactMap(\.string)
        #expect(Array(MCPToolCatalog.toolNames.prefix(26)) == observed)
        #expect(facts["mcpToolCount"] == .int(26))
        let entryKeys = try #require(facts["mcpToolEntryKeys"]?.array).compactMap(\.string)
        for tool in MCPToolCatalog.tools { #expect(tool.keys.sorted() == entryKeys.sorted(), "\(tool["name"]?.string ?? "")") }
        let readOnly = try #require(facts["mcpReadOnlyHintTools"]?.array).compactMap(\.string)
        let ours = MCPToolCatalog.tools.filter { $0["annotations"]?["readOnlyHint"] == .bool(true) }.compactMap { $0["name"]?.string }
        #expect(ours == readOnly)
    }

    /// Every slot of the descriptions fixture lands at its path, tool-level descriptions are filled, and
    /// nothing in the catalog mentions another product.
    @Test func descriptionsComeFromOurFixtureAndNameNoOtherProduct() throws {
        let slots = try #require(try MCPFixtures.descriptions()["descriptions"])
        let catalog = MCPToolCatalog.tools
        #expect(slots.keys.count == 262)
        for path in slots.keys {
            let text = try #require(slots[path]?.string, "\(path)")
            #expect(!text.isEmpty, "\(path)")
            let node = try #require(MCPFixtures.value(at: path, in: catalog), "\(path)")
            #expect(node["description"]?.string == text, "\(path)")
        }
        for tool in catalog {
            let name = tool["name"]?.string ?? ""
            #expect(tool["description"]?.string?.isEmpty == false, "\(name)")
            let text = tool.serialized(sortedKeys: false)
            #expect(!text.contains("bearcli") && !text.contains("bear.app") && !text.contains("/Applications/"), "\(name)")
            #expect(text.range(of: #"\bBear\b"#, options: .regularExpression) == nil, "\(name)")
        }
        let search = try #require(catalog.first { $0["name"] == "search_notes" })
        #expect(search["inputSchema"]?["properties"]?["query"]?["description"]?.string?.contains("@todo") == true)
        #expect(search["description"]?.string?.hasPrefix("Search notes with the full query language") == true)
        let create = try #require(catalog.first { $0["name"] == "create_note" })
        #expect(create["description"]?.string?.hasPrefix("Create a note from an optional title") == true)
    }

    /// The two extension tools are owned in Fixtures/mcp/extension-tools.json (structure only): the
    /// catalog is that fixture, `outputSchemaFrom` resolved to the named tool's output schema, plus our
    /// descriptions. All 28 tools are checked, the first 26 against the schema fixture.
    @Test func catalogEqualsTheOwnedFixturesForAll28Tools() throws {
        let schemas = try MCPFixtures.schemaTools()
        let extensions = try #require(try MCPFixtures.load("Fixtures/mcp/extension-tools.json")["tools"]?.array)
        let catalog = MCPToolCatalog.tools
        #expect(catalog.count == 28 && schemas.count == 26 && extensions.count == 2)
        for (ours, theirs) in zip(catalog.prefix(26), schemas) {
            #expect(ours.removingKeys("description") == theirs, "\(ours["name"]?.string ?? "")")
        }
        for (ours, owned) in zip(catalog.suffix(2), extensions) {
            let name = owned["name"]?.string ?? ""
            #expect(ours["name"] == owned["name"], "\(name)")
            let source = try #require(owned["outputSchemaFrom"]?.string, "\(name)")
            let from = try #require(catalog.first { $0["name"]?.string == source }, "\(name)")
            #expect(ours["outputSchema"] == from["outputSchema"] && ours["outputSchema"] != nil, "\(name)")
            for key in ["title", "annotations", "inputSchema"] {
                #expect(ours.removingKeys("description")[key] == owned[key], "\(name) \(key)")
            }
            #expect(ours.keys.sorted() == ["annotations", "description", "inputSchema", "name", "outputSchema", "title"], "\(name)")
            #expect(owned.keys.sorted() == ["annotations", "inputSchema", "name", "outputSchemaFrom", "title"], "\(name)")
        }
        let text = try String(
            contentsOf: MCPFixtures.root.appendingPathComponent("Fixtures/mcp/extension-tools.json"), encoding: .utf8)
        #expect(!text.contains("\"description\""))
    }

    /// Moving the template tool's structure into the fixture changes nothing a client sees: the generated tool
    /// equals the one generated before the move, key order included.
    @Test func templateToolIsUnchangedByTheFixtureMove() throws {
        let before = try JSONValue(parsing: Data(Self.templateToolBeforeTheMove.utf8))
        let now = try #require(MCPToolCatalog.tools.first { $0["name"] == "create_note_from_template" })
        #expect(now == before)
    }

    private static let templateToolBeforeTheMove = ###"{"annotations":{"destructiveHint":false,"idempotentHint":false,"readOnlyHint":false},"description":"Create a new note from a template: a note tagged #template (or a nested #template/…), given by its title or id. `title` fills {{title}}; `tags` are added like create_note's tags. Returns the same fields as create_note.","inputSchema":{"additionalProperties":false,"type":"object","required":["template"],"properties":{"template":{"type":"string","description":"Title or id of a note tagged #template (or a nested #template/…)."},"title":{"type":"string","description":"Fills {{title}}."},"tags":{"type":"array","items":{"type":"string"},"description":"Extra tags, added like create_note's tags."}}},"name":"create_note_from_template","outputSchema":{"properties":{"attachments":{"items":{"type":"string"},"type":"array"},"content":{"type":"string"},"created":{"description":"Creation time, UTC, ISO 8601.","type":"string"},"done":{"description":"Number of checked tasks.","type":"integer"},"id":{"type":"string"},"length":{"description":"Size of the note text in UTF-8 bytes.","type":"integer"},"location":{"type":"string"},"locked":{"type":"boolean"},"modified":{"description":"Last modification time, UTC, ISO 8601.","type":"string"},"pins":{"items":{"type":"string"},"type":"array"},"tags":{"items":{"type":"string"},"type":"array"},"title":{"type":"string"},"todos":{"description":"Number of unchecked tasks. Total tasks = todos + done.","type":"integer"}},"type":"object"},"title":"Create Note From Template"}"###

    @Test func captureThoughtIsDescribedInOurOwnWords() throws {
        let tool = try #require(MCPToolCatalog.tools.last)
        #expect(tool["name"] == "capture_thought" && tool["title"] == "Capture Thought")
        #expect(tool["annotations"] == .object([
            ("destructiveHint", .bool(false)), ("idempotentHint", .bool(false)), ("readOnlyHint", .bool(false)),
        ]))
        #expect(tool["description"]?.string == "Save a thought as a new note, exactly as given. Nothing is titled or rewritten; the first line becomes the title. When the server is limited to one tag, that tag is added, as with create_note. Returns the same fields as create_note.")
        #expect(tool["inputSchema"]?["required"] == .array(["text"]))
        #expect(tool["inputSchema"]?["additionalProperties"] == .bool(false))
        #expect(tool["inputSchema"]?["properties"]?.keys == ["text"])
        #expect(tool["inputSchema"]?["properties"]?["text"]?["description"] == "The thought to save.")
        #expect(MCPToolCatalog.requiredFields["capture_thought"] == ["text"])
    }

    @Test func instructionsAreOursAndPointAtTheTheoNotesCli() throws {
        let text = MCPToolCatalog.instructions
        #expect(text == (try #require(MCPFixtures.descriptions()["instructions"]?.string)))
        #expect(!text.contains("bearcli") && !text.contains("/Applications/") && !text.contains("bear.app"))
        #expect(text.range(of: #"\bBear\b"#, options: .regularExpression) == nil)
        #expect(text.contains("theonotes attachments save <note-id> --filename <name> > <file>"))
        #expect(text.contains("cat <file> | theonotes attachments add <note-id> --filename <name>"))
        #expect(text.contains("Section addresses."))
        // Theo Notes's addition (final review M6): the one outbound channel is named.
        #expect(text.contains(
            "`add_attachment_from_url` fetches a URL the agent chooses, so it is an outbound channel: "
                + "everything in the URL, its query string included, reaches that server. URLs longer than "
                + "2,048 bytes (in their encoded form) are refused. Review its calls before approving them."))
    }

    @Test func templateToolExtendsTheCatalogAsSpecified() throws {
        let tool = try #require(MCPToolCatalog.tools.first { $0["name"] == "create_note_from_template" })
        let expected = try JSONValue(
            parsing: Data(
                #"""
                {"name":"create_note_from_template","title":"Create Note From Template",
                "annotations":{"destructiveHint":false,"idempotentHint":false,"readOnlyHint":false},
                "inputSchema":{"additionalProperties":false,"type":"object","required":["template"],
                "properties":{"template":{"type":"string","description":"Title or id of a note tagged #template (or a nested #template/…)."},
                "title":{"type":"string","description":"Fills {{title}}."},
                "tags":{"type":"array","items":{"type":"string"},"description":"Extra tags, added like create_note's tags."}}}}
                """#.utf8))
        for key in ["name", "title", "annotations", "inputSchema"] { #expect(tool[key] == expected[key], "\(key)") }
        let create = try #require(MCPToolCatalog.tools.first { $0["name"] == "create_note" })
        #expect(tool["outputSchema"] == create["outputSchema"] && tool["outputSchema"] != nil)
        #expect(tool["description"]?.string?.isEmpty == false)
        #expect(tool.keys.sorted() == ["annotations", "description", "inputSchema", "name", "outputSchema", "title"])
    }

    @Test func everyToolIsWellFormed() {
        #expect(Set(MCPToolCatalog.toolNames).count == MCPToolCatalog.toolNames.count)
        for tool in MCPToolCatalog.tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["outputSchema"]?["type"] == "object")
            #expect(tool["title"]?.string?.isEmpty == false)
        }
    }

    @Test func generatedCatalogSourceIsUpToDate() throws {
        let (status, stderr) = try HelpTests.run(
            "/usr/bin/env",
            ["python3", "-I", MCPFixtures.root.appendingPathComponent("scripts/gen-automation-sources.py").path, "--check"])
        #expect(status == 0, "regenerate with scripts/gen-automation-sources.py: \(stderr)")
    }
}
