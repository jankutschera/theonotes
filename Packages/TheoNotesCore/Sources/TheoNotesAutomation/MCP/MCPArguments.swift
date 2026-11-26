// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// The `arguments` object of a `tools/call`, read with the types the tool's schema promises. A value of
/// the wrong type is `usage` `Invalid value for <key>`; `null` counts as absent; keys the tool does not
/// know are ignored (observed: Bear's server ignores them).
struct MCPArguments {
    private let value: JSONValue
    /// Prefixed to keys in messages, for an object nested in an array (`edits[0].`).
    private let path: String

    init(_ value: JSONValue, path: String = "") {
        if case .object = value { self.value = value } else { self.value = .object([]) }
        self.path = path
    }

    /// The raw value; nil when the key is absent or `null`.
    func raw(_ key: String) -> JSONValue? {
        guard let found = value[key], found != .null else { return nil }
        return found
    }

    func has(_ key: String) -> Bool { raw(key) != nil }

    private func invalid(_ key: String) -> AutomationError {
        AutomationError(code: .usage, message: "Invalid value for \(path)\(key)")
    }

    func string(_ key: String) throws(AutomationError) -> String? {
        guard let found = raw(key) else { return nil }
        guard case .string(let text) = found else { throw invalid(key) }
        return text
    }

    func int(_ key: String) throws(AutomationError) -> Int? {
        guard let found = raw(key) else { return nil }
        guard let number = found.intValue else { throw invalid(key) }
        return number
    }

    /// A whole number that must not be negative (the schemas say `minimum: 0`); `label` is the word
    /// the CLI's message uses for it (`Limit must be non-negative`).
    func nonNegative(_ key: String, _ label: String) throws(AutomationError) -> Int? {
        guard let number = try int(key) else { return nil }
        if number < 0 { throw AutomationError(code: .usage, message: "\(label) must be non-negative") }
        return number
    }

    func bool(_ key: String) throws(AutomationError) -> Bool? {
        guard let found = raw(key) else { return nil }
        guard case .bool(let flag) = found else { throw invalid(key) }
        return flag
    }

    func strings(_ key: String) throws(AutomationError) -> [String]? {
        guard let found = raw(key) else { return nil }
        guard let items = found.array else { throw invalid(key) }
        var result: [String] = []
        for item in items {
            guard case .string(let text) = item else { throw invalid(key) }
            result.append(text)
        }
        return result
    }

    /// An array of objects, each wrapped for reading with its position in messages.
    func objects(_ key: String) throws(AutomationError) -> [MCPArguments]? {
        guard let found = raw(key) else { return nil }
        guard let items = found.array else { throw invalid(key) }
        var result: [MCPArguments] = []
        for (index, item) in items.enumerated() {
            guard case .object = item else { throw invalid(key) }
            result.append(MCPArguments(item, path: "\(path)\(key)[\(index)]."))
        }
        return result
    }

    /// `missing required field: <name>` for the first of `names` that is absent.
    func require(_ names: [String]) throws(AutomationError) {
        for name in names where !has(name) {
            throw AutomationError(code: .usage, message: "missing required field: \(path)\(name)")
        }
    }
}

extension MCPToolCatalog {
    /// The `required` list of each tool's input schema, in schema order.
    static let requiredFields: [String: [String]] = {
        var result: [String: [String]] = [:]
        for tool in tools {
            guard let name = tool["name"]?.string else { continue }
            result[name] = tool["inputSchema"]?["required"]?.array?.compactMap(\.string) ?? []
        }
        return result
    }()
}
