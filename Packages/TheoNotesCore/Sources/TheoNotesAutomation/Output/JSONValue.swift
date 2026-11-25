// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// A JSON document that keeps the order of object keys. Our own output only ever uses `.int`;
/// `.number` carries any other valid JSON number exactly as it was written (`10.0`, `1e3`, `0.5`,
/// an integer beyond `Int`, `-0`), so nothing a client sends is rejected at the parse layer.
/// Argument checking decides per tool whether a number is acceptable (`intValue`).
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    /// The literal text of a number that is not a plain `Int` (valid JSON number syntax).
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.0 == key }?.1
    }

    /// The keys of an object in order; empty for every other value.
    public var keys: [String] {
        guard case .object(let fields) = self else { return [] }
        return fields.map(\.0)
    }

    public var array: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    public var string: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    /// The number as an `Int`: `.int`, or a `.number` whose value is integral and within ±2^53
    /// (`10.0`, `1e3`). nil for every other value, including `0.5` and `1e30`.
    public var intValue: Int? {
        switch self {
        case .int(let n):
            return n
        case .number(let text):
            guard let d = Double(text), d.isFinite, d == d.rounded(), abs(d) <= 9_007_199_254_740_992 else { return nil }
            return Int(d)
        default:
            return nil
        }
    }

    /// A copy without every field called `name`, at any depth.
    public func removingKeys(_ name: String) -> JSONValue {
        switch self {
        case .object(let fields):
            .object(fields.filter { $0.0 != name }.map { ($0.0, $0.1.removingKeys(name)) })
        case .array(let items):
            .array(items.map { $0.removingKeys(name) })
        default:
            self
        }
    }

    // MARK: Serializing

    /// Compact, one line. `"` `\` and control characters are escaped; `/` and non-ASCII text are
    /// written as they are. `sortedKeys` orders every object's keys by Unicode scalar value.
    public func serialized(sortedKeys: Bool) -> String {
        var out = ""
        write(to: &out, sortedKeys: sortedKeys)
        return out
    }

    private func write(to out: inout String, sortedKeys: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let n): out += String(n)
        case .number(let text): out += text
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(to: &out, sortedKeys: sortedKeys)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            let ordered = sortedKeys ? fields.sorted { Self.scalarLess($0.0, $1.0) } : fields
            for (index, field) in ordered.enumerated() {
                if index > 0 { out += "," }
                Self.writeString(field.0, to: &out)
                out += ":"
                field.1.write(to: &out, sortedKeys: sortedKeys)
            }
            out += "}"
        }
    }

    private static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Containers (arrays and objects) may be nested at most this deep.
    public static let maxNestingDepth = 128

    /// Strict JSON (RFC 8259) in UTF-8. Object key order is kept; a repeated key keeps its first
    /// position and its last value. Every valid number parses: a plain `Int` becomes `.int`, any
    /// other becomes `.number` with its text. Nesting deeper than `maxNestingDepth` is rejected.
    public init(parsing data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func fail(_ what: String) -> ParseError { ParseError(description: "Invalid JSON at byte \(position): \(what)") }

        mutating func parseDocument() throws -> JSONValue {
            skipSpace()
            let value = try parseValue(depth: 0)
            skipSpace()
            guard position == bytes.count else { throw fail("unexpected trailing data") }
            return value
        }

        mutating func skipSpace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard position < bytes.count else { throw fail("unexpected end") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw fail("unexpected character")
            }
        }

        mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected
            else { throw fail("invalid literal") }
            position += expected.count
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = position
            if bytes[position] == UInt8(ascii: "-") { position += 1 }
            let digitsStart = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
            let digits = position - digitsStart
            guard digits > 0 else { throw fail("invalid number") }
            if digits > 1, bytes[digitsStart] == UInt8(ascii: "0") { throw fail("leading zero") }
            func skipDigits() -> Int {
                let from = position
                while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) { position += 1 }
                return position - from
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                position += 1
                guard skipDigits() > 0 else { throw fail("digits expected after .") }
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
                position += 1
                if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                    position += 1
                }
                guard skipDigits() > 0 else { throw fail("digits expected in exponent") }
            }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            // `.int` only when the plain Int prints back as written (so `-0` and `1e3` stay literals).
            if let n = Int(text), String(n) == text { return .int(n) }
            return .number(text)
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            guard depth < JSONValue.maxNestingDepth else { throw fail("nesting too deep") }
            position += 1
            var items: [JSONValue] = []
            skipSpace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try parseValue(depth: depth + 1))
                skipSpace()
                guard position < bytes.count else { throw fail("unterminated array") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            guard depth < JSONValue.maxNestingDepth else { throw fail("nesting too deep") }
            position += 1
            var fields: [(String, JSONValue)] = []
            var indexOfKey: [[UInt8]: Int] = [:]
            skipSpace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(fields) }
            while true {
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try parseString()
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail("expected :") }
                position += 1
                skipSpace()
                let value = try parseValue(depth: depth + 1)
                if let existing = indexOfKey[Array(key.utf8)] {
                    fields[existing].1 = value
                } else {
                    indexOfKey[Array(key.utf8)] = fields.count
                    fields.append((key, value))
                }
                skipSpace()
                guard position < bytes.count else { throw fail("unterminated object") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(fields) }
                throw fail("expected , or }")
            }
        }

        mutating func parseString() throws -> String {
            position += 1
            var buffer: [UInt8] = []
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let s = String(validatingUTF8Bytes: buffer) else { throw fail("invalid UTF-8") }
                    return s
                case UInt8(ascii: "\\"):
                    guard position < bytes.count else { throw fail("unterminated string") }
                    let escape = bytes[position]
                    position += 1
                    switch escape {
                    case UInt8(ascii: "\""): buffer.append(0x22)
                    case UInt8(ascii: "\\"): buffer.append(0x5C)
                    case UInt8(ascii: "/"): buffer.append(0x2F)
                    case UInt8(ascii: "b"): buffer.append(0x08)
                    case UInt8(ascii: "f"): buffer.append(0x0C)
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "u"): buffer.append(contentsOf: Array(try parseUnicodeEscape().utf8))
                    default: throw fail("invalid escape")
                    }
                case 0..<0x20:
                    throw fail("unescaped control character")
                default:
                    buffer.append(byte)
                }
            }
            throw fail("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw fail("invalid \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Character(UnicodeScalar(bytes[position])).hexDigitValue else { throw fail("invalid \\u escape") }
                value = value * 16 + UInt32(digit)
                position += 1
            }
            return value
        }

        mutating func parseUnicodeEscape() throws -> String {
            let first = try hex4()
            var code = first
            if (0xD800...0xDBFF).contains(first) {
                guard position + 2 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u")
                else { throw fail("lone surrogate") }
                position += 2
                let second = try hex4()
                guard (0xDC00...0xDFFF).contains(second) else { throw fail("lone surrogate") }
                code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(first) {
                throw fail("lone surrogate")
            }
            guard let scalar = UnicodeScalar(code) else { throw fail("invalid code point") }
            return String(Character(scalar))
        }
    }
}

private extension String {
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        guard let s = String(validating: bytes, as: UTF8.self) else { return nil }
        self = s
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }
}
