// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

/// How a command names its note: the positional id or `--title`, exactly one of them.
enum NoteSelector: Equatable {
    case id(String)
    case title(String)

    static func parse(id: String?, title: String?) throws(AutomationError) -> NoteSelector {
        switch (id, title) {
        case (let id?, nil): return .id(id)
        case (nil, let title?): return .title(title)
        case (nil, nil): throw AutomationError(code: .usage, message: "Note ID or title is required")
        case (_?, _?): throw AutomationError(code: .usage, message: "Provide note ID or title, not both")
        }
    }
}
