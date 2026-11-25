// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// `--sort`: comma-separated `field[:asc|:desc]`. A bare field takes its default direction:
/// `pinned`, `modified`, `created` and `title` all descending (rulings M5-R10, M5-R28). Ties are
/// ordered by id.
struct SortSpec: Equatable {
    enum Field: String, CaseIterable {
        case pinned, modified, created, title

        /// Fixed fragments only: nothing the user typed reaches the SQL.
        var column: String {
            switch self {
            case .pinned: "n.isPinnedGlobal"
            case .modified: "n.modifiedAt"
            case .created: "n.createdAt"
            case .title: "n.titleKey"
            }
        }
    }

    struct Key: Equatable {
        var field: Field
        var descending: Bool
    }

    var keys: [Key]

    static let defaultSpec = "pinned,modified"

    static func parse(_ raw: String?) throws(AutomationError) -> SortSpec {
        let pieces = (raw ?? defaultSpec).split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var keys: [Key] = []
        for piece in pieces.isEmpty ? defaultSpec.split(separator: ",").map(String.init) : pieces {
            let parts = piece.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let field = Field(rawValue: parts[0].lowercased()) else {
                let valid = Field.allCases.map(\.rawValue).joined(separator: ", ")
                throw AutomationError(code: .usage, message: "invalid sort field: \(parts[0]) (valid: \(valid))")
            }
            var descending = true
            if parts.count == 2 {
                switch parts[1].lowercased() {
                case "asc": descending = false
                case "desc": descending = true
                default:
                    throw AutomationError(
                        code: .usage, message: "invalid sort order: \(parts[1]) (valid: asc, desc)")
                }
            }
            keys.append(Key(field: field, descending: descending))
        }
        return SortSpec(keys: keys)
    }

    /// The `ORDER BY` terms over `note n`, ending in the id tiebreak.
    func orderBy() -> String {
        (keys.map { "\($0.field.column) \($0.descending ? "DESC" : "ASC")" } + ["n.id ASC"]).joined(separator: ", ")
    }
}
