// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation

/// `--fields`: a comma-separated list, or `all`.
enum NoteFields {
    /// The columns to print, in the order asked for. Without `--fields` the command's defaults.
    /// `all` stands for the command's `allFields` (never `content`) at its place in
    /// the list, `content` only when it is named; a field named twice appears once.
    static func parse(_ raw: String?, spec: CommandSpec) throws(AutomationError) -> [String] {
        guard let raw else { return spec.defaultFields }
        let tokens = raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return spec.defaultFields }
        var result: [String] = []
        func add(_ field: String) {
            if !result.contains(field) { result.append(field) }
        }
        for token in tokens {
            if token == "all" {
                spec.allFields.forEach(add)
            } else if spec.allFields.contains(token) || spec.extraFields.contains(token) {
                add(token)
            } else {
                let valid = spec.allFields.joined(separator: ", ")
                throw AutomationError(code: .usage, message: "Unknown field: \(token) (valid: \(valid))")
            }
        }
        return result
    }
}
