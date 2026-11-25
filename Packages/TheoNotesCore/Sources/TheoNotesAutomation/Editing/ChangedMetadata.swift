// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// The `changedMetadata` of an MCP write result.
enum ChangedMetadata {
    /// The MCP metadata fields whose values differ between the two records, keys sorted. Never
    /// `content`: the caller already holds the text it wrote.
    static func diff(_ before: NoteRecord, _ after: NoteRecord) -> JSONValue {
        let old = before.mcpMetadata()
        let fields = after.mcpMetadata().removingKeys("content")
        guard case .object(let pairs) = fields else { return .object([]) }
        return .object(pairs.filter { old[$0.0] != $0.1 }.sorted { $0.0 < $1.0 })
    }
}
