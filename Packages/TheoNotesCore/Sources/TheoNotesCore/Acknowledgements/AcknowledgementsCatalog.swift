// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The third-party software, data and licences the app ships, as listed in the Acknowledgements
/// window. The data is `Acknowledgements.json`, written by `scripts/gen-acknowledgements.py` from
/// what is really bundled (the editor's module graph, `Package.resolved`, the bundled palettes and
/// word lists); it is never edited by hand. Licence texts are stored once per distinct text; a text
/// may carry a `{{copyright}}` placeholder that each entry fills with its own copyright block.
public struct AcknowledgementsCatalog: Sendable {
    public static let supportedSchemaVersion = 1
    public static let resourceName = "Acknowledgements"
    static let placeholder = "{{copyright}}"

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)

        public var description: String {
            switch self {
            case .unsupportedSchema(let version): "The Acknowledgements list has format \(version), which this version cannot read."
            }
        }
    }

    public struct Entry: Sendable, Decodable, Identifiable, Hashable {
        public enum Kind: String, Sendable, Decodable { case npm, swiftpm, asset }

        public let name: String
        public let version: String
        public let kind: Kind
        /// The SPDX identifier of the licence the software is used under.
        public let licence: String
        /// The licence as the package declares it, when it offered a choice ("(MPL-2.0 OR Apache-2.0)").
        public let licenceExpression: String?
        public let copyright: String
        public let copyrightBlock: String?
        public let textId: String
        public let noticeId: String?
        public let source: String
        /// Where the source code of this exact version can be had (weak-copyleft components).
        public let sourceCode: String?
        public let usedIn: String
        public let note: String?

        public var id: String { "\(kind.rawValue):\(name)@\(version)" }

        /// "name version" for the list.
        public var title: String { version.isEmpty ? name : "\(name) \(version)" }
    }

    private struct Document: Decodable {
        let schemaVersion: Int
        let texts: [String: String]
        let entries: [Entry]
    }

    public let entries: [Entry]
    private let texts: [String: String]

    public init(jsonData: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: jsonData)
        guard document.schemaVersion <= Self.supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(document.schemaVersion)
        }
        entries = document.entries
        texts = document.texts
    }

    /// Reads `Acknowledgements.json` from a bundle's resources.
    public init(bundle: Bundle) throws {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Acknowledgements.json is missing from the app."])
        }
        try self.init(jsonData: Data(contentsOf: url))
    }

    /// The full licence text of an entry, with its copyright block in place; nil when the file has
    /// no text for it (which the generator never writes, and the tests rule out).
    public func licenceText(for entry: Entry) -> String? {
        guard let body = texts[entry.textId] else { return nil }
        return body.replacingOccurrences(of: Self.placeholder, with: entry.copyrightBlock ?? entry.copyright)
    }

    /// The package's own NOTICE text, when it ships one.
    public func noticeText(for entry: Entry) -> String? {
        entry.noticeId.flatMap { texts[$0] }
    }

    public var entriesWithoutLicenceText: [Entry] {
        entries.filter { licenceText(for: $0) == nil }
    }

    /// Entries whose name, version, licence, copyright or use contain every word of `query`
    /// (ignoring case and accents). An empty query lists everything.
    public func search(_ query: String) -> [Entry] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = Self.fold(
                [entry.name, entry.version, entry.licence, entry.licenceExpression ?? "", entry.copyright, entry.usedIn]
                    .joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
