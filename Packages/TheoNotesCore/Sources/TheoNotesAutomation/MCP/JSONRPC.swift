// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// JSON-RPC 2.0 framing for the MCP server: one JSON object per line in, one per line out.
enum JSONRPC {
    enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    /// What one input line turned out to be.
    enum Incoming {
        /// Has an `id`: answer it.
        case request(id: JSONValue, method: String, params: JSONValue?)
        /// No `id`: never answered, not even when the method is unknown.
        case notification(method: String)
        /// A client's answer (`result` or `error`, no `method`); ignored, the server sends no requests.
        case response
        /// Valid JSON that is not a request; answered with `-32600`. `id` is null unless the message had a usable one.
        case invalid(id: JSONValue)
        /// Not JSON; answered with `-32700` and `id: null`.
        case unparsable(detail: String)
    }

    static func parse(line: Data) -> Incoming {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: line)
        } catch {
            return .unparsable(detail: (error as? JSONValue.ParseError)?.description ?? "\(error)")
        }
        guard case .object = value else { return .invalid(id: .null) }
        let id: JSONValue?
        switch value["id"] {
        case nil: id = nil
        case .string?, .int?, .number?, .null?: id = value["id"]
        default: return .invalid(id: .null)
        }
        guard let method = value["method"]?.string else {
            if value["method"] == nil, value["result"] != nil || value["error"] != nil { return .response }
            return .invalid(id: id ?? .null)
        }
        guard let id else { return .notification(method: method) }
        return .request(id: id, method: method, params: value["params"])
    }

    static func result(id: JSONValue, _ result: JSONValue) -> Data {
        line(.object([("id", id), ("jsonrpc", "2.0"), ("result", result)]))
    }

    static func error(id: JSONValue, code: Int, message: String) -> Data {
        let body = JSONValue.object([("code", .int(code)), ("message", .string(message))])
        return line(.object([("error", body), ("id", id), ("jsonrpc", "2.0")]))
    }

    /// Keys sorted at every level (observed), `/` unescaped, newline-terminated.
    private static func line(_ message: JSONValue) -> Data {
        Data((message.serialized(sortedKeys: true) + "\n").utf8)
    }
}
